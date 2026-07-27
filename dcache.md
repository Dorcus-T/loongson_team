# DCache 设计文档

## 1. 架构概览

| 参数 | 值 | 说明 |
|------|-----|------|
| 组相联 | 2-way | `WAY_NUM = 2` |
| 索引位宽 | 8 bit | `INDEX_WIDTH = 8`，共 256 组 |
| Tag 位宽 | 20 bit | `TAG_WIDTH = 20` |
| 偏移位宽 | 4 bit | `OFFSET_WIDTH = 4`，16 字节 cache line |
| 每行 Bank 数 | 4 | 每 Bank 32-bit，4 Bank = 128-bit |
| 替换策略 | 树状 PLRU | WAY_NUM-1 = 1 bit/组 |
| RAM 类型 | 单端口同步 | `sp_ram`（tagv + bank），寄存器阵列（d_ram） |
| 读写 | 读分配 + 写回 + 写分配 | load miss 填 cache，store miss 先填再写 |
| Victim Cache | 4 项 FIFO | 仅存储干净行，可配置开关 `VC_EN` |

**地址划分（32-bit 虚地址）：**

```
|  TAG [31:12]  |  INDEX [11:4]  |  OFFSET [3:0]  |
|    20 bit      |     8 bit      |     4 bit       |
```

**Cache 行结构（每 way × 每 index）：**

```
|  V (1b)  |  TAG (20b)  |  D (1b)  |  Data Bank0 (32b)  |  Bank1 (32b)  |  Bank2 (32b)  |  Bank3 (32b)  |
```

**MMU 并行化**：MMU（虚实地址转换）与 cache 并行工作。CPU 请求 accept 时 cache 只拿到 `cpu_index`、`cpu_offset`、`cpu_wstrb`、`cpu_wdata`；**下一拍** MMU 输出 `mmu_tag` / `mmu_cache` / `mmu_cancel` 到达，此时 cache 正好进入 LOOKUP 状态进行 tag 比较。

---

## 2. Buffer 设计

### 2.1 Request Buffer

`accept_new_req` 时更新，LOOKUP 期间保持稳定。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `req_d` | 1 | 0=load, 1=store |
| `req_index` | 8 | 请求 index |
| `req_offset` | 4 | 请求 offset（选中哪个 Bank） |
| `req_wstrb_mask` | 32 | 展开的字节写使能（每字节 8-bit 全 0/全 1） |
| `req_wdata` | 32 | 请求写数据 |
| `cacop_en_r` | 1 | CACOP 使能（锁存） |
| `cacop_code_r` | 5 | CACOP 操作码 |
| `cacop_way_r` | 1 | CACOP 目标路号 |
| `cacop_index_r` | 8 | CACOP 目标 index |
| `cacop_is_index_r` | 1 | CACOP 是否 index 操作 |
| `cacop_is_hit_r` | 1 | CACOP 是否 hit 操作 |

### 2.2 Refill Buffer

**LOOKUP miss 拍一次性锁存，含写回握手管理和 VC 服务信息。** 整个 REFILL 期间不变（含 WAITRD）。替代了独立的 Writeback Buffer 和 VC 服务上下文。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_index` | 8 | 写回 index |
| `refill_tag` | 20 | 新行 tag（来源：`use_mmu_buf ? mmu_buf_tag : mmu_tag`） |
| `refill_offset` | 4 | 原始请求的 offset（用于 `read_miss_done` 判断） |
| `refill_cached` | 1 | 是否 cached（来源：`use_mmu_buf ? mmu_buf_cached : mmu_cache`） |
| `refill_d` | 1 | 原始请求的 op（同时作为 D 位） |
| `refill_replace_way` | 1 | 替换目标路号（`replace_way` 锁存） |
| `refill_cnt` | 2 | 已接收数据拍数（0..3） |
| `refill_line[0:3]` | 4×32 | 新行拼装缓冲区 |
| `refill_victim_line[0:3]` | 4×32 | victim 行 128-bit（含 `live_fwd` WB 前推） |
| `refill_victim_tag` | 20 | victim 行 tag |
| `refill_victim_valid` | 1 | victim 行 V 位 |
| `refill_victim_dirty` | 1 | victim 行 D 位（含 `wb_line_dirty` 前推） |
| `refill_wdata` | 32 | 锁存的 store wdata（供 REFILL/VC 合并用） |
| `refill_wstrb_mask` | 32 | 锁存的 store wstrb_mask |
| `refill_needs_write` | 1 | 有待发出的 AXI 写请求 |
| `refill_wr_handshaked` | 1 | AXI 写握手已完成 |
| `refill_vc_hit_idx` | VC_IDX_W | VC 命中条目号（仅 VC hit 时有效） |
| `refill_cacop` | 1 | 该 REFILL 是否为 CACOP 发起 |

**加载时机**：`main_lookup && !cache_hit`（含 `vc_serve`、uncached、CACOP）。

此时 `bank_rdata` 还是 accept 拍读的数据（对应正确的 index），`live_fwd` / `victim_dirty` / `miss_needs_write` 组合逻辑有效。一次性锁存在 Refill Buffer 后，全部后续判断和 AXI 输出均从 Refill Buffer 推导（AXI 写输出在 LOOKUP 拍使用组合 live 数据，后续状态使用 Refill Buffer 快照）。

### 2.3 顶层标志

| 标志 | 说明 |
|------|------|
| `refill_already_accept_new_req` | REFILL 期间已提前接受一个 CPU 请求，退出 REFILL 后进 LOOKUP 而非 IDLE |

### 2.4 MMU Buffer

**动机**：MMU 并行化设计中，tag/cache/cancel 在 accept 后 1 拍到达。正常 LOOKUP 流程可以直接使用 `mmu_tag` / `mmu_cache` / `mmu_cancel` 端口信号。但当 REFILL 期间提前 accept 新请求（`refill_early_accept`）时，accept 的下一个周期 MMU 输出有效，此时 cache 仍在 REFILL 状态——没有 LOOKUP 来消费这些数据。MMU Buffer 负责在这个窗口捕获 MMU 输出，供后续 LOOKUP 使用。

**捕获条件**：
```verilog
mmu_buf_capture = main_refill && refill_already_accept_new_req && !mmu_buf_valid;
```

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `mmu_buf_tag` | 20 | REFILL 期间提前取的请求对应的物理 tag |
| `mmu_buf_cached` | 1 | 是否 cached 访问 |
| `mmu_buf_cancel` | 1 | MMU 取消标志 |
| `mmu_buf_valid` | 1 | Buffer 有效（进入 LOOKUP/IDLE 时清零） |

**使用**：
```verilog
use_mmu_buf    = main_lookup && mmu_buf_valid;
effective_cancel = use_mmu_buf ? mmu_buf_cancel : mmu_cancel;
lookup_tag     = cacop_en_r ? mmu_cacop_tag : (use_mmu_buf ? mmu_buf_tag    : mmu_tag);
lookup_cached  = cacop_en_r ? 1'b1         : (use_mmu_buf ? mmu_buf_cached : mmu_cache);
```

`effective_cancel` 用于：`cache_hit` 强制为 0、LOOKUP 状态机直接回 IDLE、`miss_needs_write` 强制为 0。

**时序示意**：
```
Cycle       | REFILL(N-1)         | REFILL(N)           | REFILL(last)        | LOOKUP
------------|---------------------|---------------------|---------------------|--------
事件         | refill_early_accept | mmu_buf_capture     | refill_last         | use_mmu_buf=1
            | accept_new_req=1    | mmu_buf_valid=1     | FSM → LOOKUP        | lookup_tag=mmu_buf_tag
            | ram_read_en=1       |                     |                     | 正常命中/缺失判定
```

### 2.5 Write Buffer（WB）

独立两状态 FSM（`WB_IDLE` / `WB_WRITE`），处理命中 store 的延迟写。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `wb_valid` | 1 | WB 中有待写数据 |
| `wb_way_hit` | WAY_NUM | store 命中的路位图 |
| `wb_index` | 8 | store 目标 index |
| `wb_bank` | 2 | store 目标 bank |
| `wb_wstrb_mask` | 32 | 展开的写使能 |
| `wb_wdata` | 32 | 写数据 |

WB 写入 bank RAM 时按 `wb_way_hit` 逐路写。store 只写一个 bank（`wb_bank`），但命中多路时所有命中路的同 bank 都更新。

### 2.6 AXI 写请求（从 Refill Buffer 推导）

不再有独立的 Writeback Buffer。`wr_req/type/addr/wstrb/data` 全部从 Refill Buffer 组合推导。

**双路径设计**：LOADUP 拍使用组合 live 数据（`lookup_wr_bank` / `tagv_lookup` / `req_*`），确保 LOOKUP 当拍即可发起写握手；LOADUP 之后各状态使用 Refill Buffer 快照（`refill_victim_line` / `refill_victim_tag` / `refill_*`），数据稳定。

| 输出 | LOOKUP 拍（live） | 后续状态（Refill Buffer 快照） |
|------|-------------------|------------------------------|
| `wr_req` | `main_lookup && miss_needs_write` | `refill_needs_write && !refill_wr_handshaked` |
| `wr_type` | `(mmu_cache \| mmu_buf_cached \| cacop_en_r) ? 3'b100 : uncached_rd_type` | `!refill_is_uncached_store ? 3'b100 : ...` |
| `wr_addr` | burst:`{victim_tag, req_index, 4'd0}` / unc:`{mmu_tag \| mmu_buf_tag, req_index, req_offset}` | burst:`{refill_victim_tag, refill_index, 4'd0}` / unc:`{refill_tag, refill_index, refill_offset}` |
| `wr_wstrb` | burst:`4'b1111` / unc:`req_wstrb_4b` | burst:`4'b1111` / unc:`refill_wstrb_4b` |
| `wr_data` | burst:`{lookup_wr_bank[3:0]}` / unc:`{96'd0, req_wdata}` | burst:`{refill_victim_line[3:0]}` / unc:`{96'd0, refill_wdata}` |

`wr_req` 从 LOOKUP 拍起即拉高，贯穿 WAITRD → REFILL → WAITWR → WAITWB，后台独立推进。握手逻辑也在 LOOKUP 拍即可触发（`main_lookup && miss_needs_write && wr_rdy`），无需额外延迟。

### 2.7 VC 服务信息（由 Refill Buffer 统一管理）

不再有独立的 VC 服务上下文。VC hit + L1 miss 的信息统一存入 Refill Buffer（`refill_vc_hit_idx` / `refill_victim_valid` / `refill_victim_dirty`）。VC→L1 数据从 `vc_data[refill_vc_hit_idx]` 直接读（WAITWB 路径），或从 `vc_data[vc_hit_idx]` 组合读（LOADUP 当拍交换路径）。

---

## 3. 状态机

### 3.1 双状态机

dcache 有两个独立状态机：

| 状态机 | 状态数 | 说明 |
|--------|--------|------|
| Main FSM | 6 | IDLE / LOOKUP / WAITRD / REFILL / WAITWR / WAITWB |
| WB FSM | 2 | WB_IDLE / WB_WRITE |

### 3.2 Main FSM 状态编码

```
IDLE (000001) → LOOKUP (000010) → WAITRD (000100) → REFILL (001000)
                 ↘ WAITWR (010000)
                 ↘ WAITWB (100000)
```

### 3.3 状态跳转图

```
                        ┌──────────────────────────────────────────────┐
                        │                                              │
                        ▼                                              │
        ┌──────┐  accept  ┌─────────┐  hit (ld/st)  ┌──────┐          │
        │ IDLE │ ───────> │ LOOKUP  │ ────────────> │ IDLE │          │
        └──────┘          └─────────┘               └──────┘          │
            ▲           │  │  │  │  │                                │
            │  miss+    │  │  │  │  │ vc_serve+wb_busy               │
            │  rd_rdy   │  │  │  │  ▼                                │
            │           │  │  │  ├─ WAITWB ──(!wb_write)──▶ IDLE/    │
            │           │  │  │  │                        WAITWR     │
            │  miss+    │  │  │  │                                    │
            │  !rd_rdy  │  │  │  │                                    │
            │           ▼  │  │  │                                    │
            │      ┌──────┐ │  │  │                                    │
            │      │WAITRD│ │  │  │                                    │
            │      └──────┘ │  │  │                                    │
            │         │     │  │  │  vc_serve+dirty /                 │
            │      rd_rdy   │  │  │  uncached_store                   │
            │         │     │  │  ▼                                    │
            │         ▼     │  ├─ WAITWR ◄──────────────────────┐     │
            │      ┌──────┐ │  │                                 │     │
            │      │REFILL│─┘  │  │                              │     │
            │      └──────┘    │  │                              │     │
            │         │        │  │  vc_serve+clean              │     │
            │    refill_last   │  │  / vc_serve+dirty+wr_rdy     │     │
            │    wr未握手      │  │                              │     │
            │         ▼        │  ▼                              │     │
            │      ┌──────┐    ├─ IDLE ──────────────────────────┘     │
            └──────│WAITWR│◄───┘                                      │
                   └──────┘                                            │
```

### 3.4 各状态详述

#### IDLE

- **进入**: 复位，或 LOOKUP/REFILL/WAITWR/WAITWB 无后续请求时
- **退出**: `accept_new_req`（`idle_accept` → LOOKUP）
- **RAM 动作**: `ram_read_en = 1`，读 tagv + bank + d_ram
- **PLRU**: accept 时更新 `plru_victim_r`
- **WB**: `wb_stall = wb_write && ram_read_en`，WB 被抢端口时暂缓

#### LOOKUP

- **进入**: 从 IDLE accept，或从 LOOKUP 自循环（连续 accept/hit），或从 REFILL early-accept
- **tagv_rdata 有效**: 上一拍的 `ram_read_en` 在该拍产生 rdata
- **分支**（按优先级）:
  1. `effective_cancel` → IDLE（MMU 取消，丢弃当前请求）
  2. `vc_serve_wb_busy` → WAITWB（VC hit + WB 忙，等 WB 写完）
  3. `vc_serve && !victim_dirty` → IDLE（VC→L1 + victim→VC 交换完成）
  4. `vc_serve && victim_dirty && wr_rdy` → IDLE（VC→L1 + wr 当拍握手完成）
  5. `vc_serve && victim_dirty && !wr_rdy` → WAITWR（VC→L1 + victim 写回内存，等握手）
  6. `is_uncached_store` → WAITWR
  7. `cacop_en_r` → REFILL
  8. `!cache_hit && rd_rdy` → REFILL（miss + 总线就绪）
  9. `!cache_hit && !rd_rdy` → WAITRD（miss + 等总线）
  10. `accept_new_req` → LOOKUP 自循环
  11. 否则 → IDLE
- **data_ok**: `read_hit_done`（load 命中）、`vc_read_done`（VC 命中 load）、`write_done`（store）
- **PLRU**: `plru_upd_en = main_lookup && cache_hit || refill_tagv_we`

#### WAITRD

- **进入**: LOOKUP miss 但 `rd_rdy = 0`
- **退出**: `rd_rdy` → REFILL
- **RAM 动作**: 无
- **rd_req**: 保持为 1
- **wr_req**: 如 `refill_needs_write` 已置位，持续拉高

#### REFILL

- **进入**: `enter_refill = (LOOKUP miss + rd_rdy) || (LOOKUP cacop) || (WAITRD + rd_rdy)`
- **第 0–3 拍（return_valid）**: `refill_line[refill_cnt] <= refill_merged_word`，`refill_cnt++`
- **`read_miss_done`**: `main_refill && return_valid && !refill_d && (refill_cnt == refill_offset[3:2] || !refill_cached)`
- **`refill_last` 拍**:
  - TagV + Bank RAM + d_ram 写回
  - PLRU 更新（`refill_replace_way` 标 MRU）
- **退出**:
  - uncached / CACOP → IDLE
  - `refill_needs_write && !refill_wr_handshaked` → WAITWR
  - `refill_already_accept_new_req` → LOOKUP
  - 否则 → IDLE
- **refill_early_accept**: REFILL 中间拍可提前接受一个 CPU 请求（条件见 §4）

#### WAITWR

双重用途——cached 写回等 `wr_rdy`，uncached store 等 `wr_done`。

- **进入**: LOOKUP miss dirty / VC serve dirty / uncached store / REFILL 后 wr 未握手
- **退出**:
  - `!refill_wr_handshaked` → 继续等握手
  - `refill_is_uncached_store && !wr_done` → 等 `wr_done`
  - 握手完成且（cached || `wr_done`）→ accept→LOOKUP 或 IDLE
- **wr_req**: 持续拉高直到握手
- **握手拍立即 accept**: 可以在同拍 `accept_new_req` → LOOKUP

#### WAITWB

VC hit + WB 忙时等待 WB 写完。

- **进入**: `vc_serve_wb_busy = vc_serve && wb_write`
- **停留**: `wb_write` → 等 WB 完成
- **退出**（`!wb_write`）:
  - `refill_victim_dirty && !refill_wr_handshaked` → WAITWR
  - `accept_new_req` → LOOKUP
  - 否则 → IDLE
- **vc_exchange**: `main_waitwb && !wb_write` 拍触发 VC↔L1 交换

### 3.5 WB FSM

```
WB_IDLE ──lookup_store_hit──▶ WB_WRITE
WB_WRITE ──!wb_stall && !wb_new_store_hit──▶ WB_IDLE
WB_WRITE ──wb_stall──▶ WB_WRITE（暂缓）
WB_WRITE ──wb_new_store_hit──▶ WB_WRITE（新 store 命中，数据更新）
```

- **进入 WB_WRITE**: LOOKUP 命中 store → `wb_valid=1`，`wb_way_hit` / `wb_bank` / `wb_data` 锁存
- **写入**: `wb_write && !ram_read_en` 时 `bank_wr_hit` 写 bank RAM + `d_ram <= 1`
- **暂缓**: `wb_stall = wb_write && ram_read_en`，RAM 被新请求读抢走
- **退出**: 非 stall 且无新 store 命中 → `wb_valid=0`

---

## 4. 特殊机制一：REFILL 提前取下一条

### 4.1 动机

普通 REFILL 期间（2-way × 4 bank，约 4 拍），CPU 空闲等待。如果当前 miss 行就是 CPU 下一拍要取的行，可以提前接受新请求、预读 RAM，REFILL 结束后直接进 LOOKUP 判定，省掉 1 拍。

### 4.2 触发条件

```
refill_early_accept = main_refill && !refill_last
                    && !refill_already_accept_new_req
                    && !cacop_en_r && !cacop_en
                    && cpu_req
                    && refill_cached
                    && !refill_needs_write;
```

- 写回未完成时不允许提前 accept（避免 Refill Buffer 写回数据冲突）
- 每个 REFILL 只 accept 一次

### 4.3 Tag/Data/D Bypass

进入 LOOKUP 时 REFILL 的写回数据尚未在 RAM 中可见。bypass 用 Refill Buffer 数据替代：

```
bypass_active = main_lookup && refill_already_accept_new_req
              && (req_index == refill_index);

// Tag bypass
tagv_lookup[way] = bypass_active && way == refill_replace_way
                 ? {refill_tag, 1'b1}
                 : tagv_rdata[way];

// D bypass
d_lookup[way] = bypass_active && way == refill_replace_way
              ? refill_d
              : d_rdata[way];

// Data bypass
hit_word = bypass_active && hit_way_idx == refill_replace_way
         ? refill_line[req_offset[3:2]]
         : bank_rdata[hit_way_idx][req_offset[3:2]];
```

---

## 5. 特殊机制二：Hit Write 冲突

### 5.1 三种机制

| 机制 | 信号 | 说明 |
|------|------|------|
| WB 暂缓 | `wb_stall = wb_write && ram_read_en` | WB 被新请求抢 RAM 端口，写入推迟 |
| WB 前推 | `wb_fwd_active` / `wb_fwd_data` | LOOKUP 是 load 且 WB 有未写入的同 index/way/bank → 合成最新数据 |
| 阻塞 accept | `hit_write_block` | LOOKUP st 命中 + WB 忙 + 新请求 → 阻塞，防止双 st 竞争 WB |

### 5.2 WB 暂缓（`wb_stall`）

RAM 是单端口，读（新请求 accept）优先。`ram_read_en` 当拍 `bank_wr_hit` 被门控（`&& !ram_read_en`），`d_ram` 写入同步暂缓（`&& !wb_stall`）。WB 状态机滞留 WB_WRITE，数据保持。

### 5.3 WB 前推（`wb_fwd_active`）

当前 LOOKUP 请求是 load，且 WB 有未写入的同 index、同 way、同 bank 数据。此时 `bank_rdata` 是旧的，`lookup_rdata` 用 `wb_wdata & wb_wstrb_mask` 与 `bank_rdata` 做字节合并。

**同 cycle 的 store 前推**：LOOKUP store 命中 + 新 load 被 accept → 下拍新 ld 在 LOOKUP 时 `wb_fwd_active` 自然检测到 WB 有数据（因为上拍 `lookup_store_hit` 已锁存 WB）。

### 5.4 脏位前推（`wb_line_dirty`）

miss 时判断 `victim_dirty` 需要综合 WB 状态。如果 WB 正写同 index 同 way，`d_rdata` 可能还是 0（WB 被 stall 或尚未读回）。

```
victim_dirty = (d_lookup[way] || wb_line_dirty[way]) && tagv_lookup[way][0]
```

`wb_line_dirty[way] = wb_write && (wb_index == req_index) && wb_way_hit[way]`

---

## 6. 特殊机制三：Victim Cache

### 6.1 设计原则

- VC 仅存储**干净行**（D=0）
- 4 项深度，FIFO 替换
- LOOKUP 直接命中：VC 不参与
- LOOKUP miss + VC miss：标准 miss 流程，refill_last 拍干净 victim 写入 VC

### 6.2 VC hit + L1 miss（`vc_serve`）

此场景下 LOOKUP 拍需要：
- VC 行数据通过 `vc_word` 返回 CPU（`vc_read_done`）
- **VC→L1**：VC 行写入 L1（tagv + bank + d=req_d）
- **L1→VC**（victim 干净）：victim 行写入 VC 同槽位
- **L1→内存**（victim 脏）：victim 行数据已在 Refill Buffer 中（`refill_victim_line`）→ wr_req

### 6.3 WB 忙时的 WAITWB 状态

`vc_serve && wb_write` → 进入 WAITWB：
- 等待 WB 写完 RAM
- 期间 Refill Buffer / VC 上下文全部锁存，数据安全
- WB 完成后 `vc_exchange` 拍执行 VC↔L1 交换
- clean victim → IDLE；dirty victim → WAITWR

### 6.4 VC 数据交换

**VC→L1（总是执行）**：
- LOOKUP 当拍：数据源 `vc_data[vc_hit_idx]` + 组合 `req_*`（live 数据）
- WAITWB 末尾：数据源 `vc_data[refill_vc_hit_idx]` + Refill Buffer `refill_*`（快照）
- tagv ← VC 行 tag + V=1
- bank ← 128-bit VC data（store 时合并 `refill_wdata` / `req_wdata`）
- d_ram ← `refill_d` / `req_d`（store=1 / load=0）

**L1→VC（仅干净 victim）**：
- LOOKUP 当拍：数据源 `lookup_wr_bank` + 组合 `req_*`（live 数据），写 `vc_data[vc_hit_idx]`
- WAITWB 末尾：数据源 `refill_victim_line`（Refill Buffer 快照），写 `vc_data[refill_vc_hit_idx]`
- `vc_addr[...]` ← `{refill_victim_tag, refill_index}` / `{tagv_lookup[replace_way][...], req_index}`

### 6.5 VC insert（refill_last 拍）

干净 victim 在 refill_last 拍写入 VC（全部从 Refill Buffer 取，不读 RAM 端口）：
```
vc_insert = refill_d_we && VC_EN
         && refill_victim_valid
         && !refill_victim_dirty;
```
数据从 `refill_victim_line` 取，tag 从 `refill_victim_tag` 取（LOOKUP miss 拍锁存，含 live_fwd WB 前推）。

---

## 7. 发送访存请求的时机

### 7.1 读请求

| 状态 | 条件 |
|------|------|
| LOOKUP | `!cache_hit && need_bus_rd && !vc_hit` |
| WAITRD | 持续拉高 |

`rd_req = rd_req_lookup || main_waitrd`。cached miss 需要总线读，VC 命中不需要（数据从 VC 取）。

### 7.2 写请求

| 时机 | 说明 |
|------|------|
| LOOKUP miss + dirty | Refill Buffer 加载，`wr_req` 当拍拉高 |
| LOOKUP uncached store | Refill Buffer 加载，`wr_req` 当拍拉高 |
| REFILL 期间 | `wr_req` 后台持续拉高 |
| WAITWR | `wr_req` 持续拉高直到握手 |

`wr_req = (main_lookup && miss_needs_write) || (refill_needs_write && !refill_wr_handshaked)`。LOADUP 拍组合拉高，后续状态从 Refill Buffer 推导。cached 写回握手即完成，uncached store 需要等 `wr_done`。

### 7.3 wr_req 窗口

```
LOOKUP miss+dirty:
  ┌─ LOOKUP ──┬─ WAITRD ──┬──── REFILL ────┬─ WAITWR ─┐
  │ wr_req=1  │ wr_req=1  │   wr_req=1     │ wr_req=1 │
  │           │           │                 │          │
  └─ 握手? ───┴─ 握手? ───┴─── 握手? ───────┴── 握手 ──┘
```

整个窗口持续尝试握手。REFILL 期间握手 → refill_last 直回 IDLE。全程未握手 → WAITWR。

---

## 8. uncached 访问

- `mmu_cache = 0`（来自 MMU 端口或 MMU Buffer）时：
  - `way_hit` 强制为 0（`lookup_cached || cacop_en_r` 为 0）
  - `cache_hit = 0`（必然 miss）
  - LOOKUP 分支：
    - uncached load → WAITRD → REFILL（等 `return_valid`）
    - uncached store → WAITWR（等 `wr_rdy` + `wr_done`）
  - REFILL 中不写 tagv/bank（`refill_cached = 0`）
  - `read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
  - AXI `rd_addr` 使用 offset 精确地址
  - REFILL 退化为 IDLE

---

## 9. CACOP 处理

### 9.1 操作码

| code[4:3] | 类型 | 说明 |
|-----------|------|------|
| 00 | Index Invalidate | 指定 index 的指定路 V←0 |
| 01 | Index Store Tag | 指定 index 的指定路写入 tag |
| 10 | Hit Invalidate | 命中路 V←0 |
| 11 | — | 预留 |

### 9.2 流程

```
accept_new_req (cacop_en=1)
  → Request Buffer 锁存 cacop 上下文
  → LOOKUP（读 tagv，cache_hit=0）
  → 直接进 REFILL（无总线读请求）
  → REFILL 中 cacop_en_r 触发 tagv 写
  → 若有脏行需写回 → Refill Buffer 加载写回信息，wr 后台
  → cacop_en_r ← 0，FSM → IDLE
```

- CACOP 不产生 `cpu_data_ok`（`cache_hit = 0`）
- CACOP REFILL 不接受提前 accept（`!cacop_en_r` 条件）
- CACOP 的替换路：code=10(hit) 用 `hit_way_idx`，否则用 `cacop_way_r`

---

## 10. 数据通路

### 10.1 数据来源

```
live_rdata =
  1. read_hit_done  → lookup_rdata   (L1 命中: bank_rdata/bypass + wb_fwd)
  2. vc_read_done   → vc_word        (VC 命中: VC 数据)
  3. read_miss_done → return_data    (miss: AXI 返回数据)
  4. 其他           → 0
```

所有数据源统一通过 `live_data_ready → FIFO → cpu_data_ok + cpu_rdata`。

### 10.2 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- `accept_ok`：store 无条件接受；load 需 FIFO 有空位（`< 3` 或 `==3 && req_d` 即当前是 store 产生 write_done 不占 FIFO）
- FIFO 空且数据就绪时，数据直通（bypass FIFO）

---

## 11. PLRU 替换算法

与 icache 一致。2-way 时 1 bit/组 × 256 组。

**两阶段**：
- Accept 拍：组合遍历 → `plru_victim_pre` → `plru_victim_r`（锁存）
- LOOKUP 拍：`replace_way = cacop_en_r ? cacop_way/hit_way : (has_invalid ? invalid_way : plru_victim_r)`

**更新**：命中或 `refill_tagv_we` 时标 MRU。

---

## 12. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数 |
| `perf_access_cnt` | cached 访问进入 LOOKUP 的次数（不含 cacop） |
| `perf_miss_cnt` | cached miss 次数 |
| `perf_real_miss_cnt` | 实际 miss（不含 VC 命中） |
| `perf_vc_hit_cnt` | VC 命中次数 |
| `perf_vc_insert_cnt` | VC 插入次数（refill_last 干净 victim） |
| `perf_vc_fill_cnt` | VC 交换次数（vc_serve 干净 victim） |

---

## 13. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer |
| `refill_*` | Refill Buffer |
| `mmu_buf_*` | MMU Buffer（锁存的 MMU 输出） |
| `cpu_*` | CPU 接口 |
| `mmu_*` | MMU 输入端口（`mmu_tag` / `mmu_cache` / `mmu_cancel` / `mmu_cacop_tag`） |
| `cacop_*` | CACOP 接口/上下文 |
| `wb_*` | Write Buffer |
| `wr_*` | AXI 写接口（数据从 Refill Buffer 组合推导） |
| `vc_*` | Victim Cache |
| `plru_*` | PLRU 替换算法 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `(idle_accept \| hit_accept \| refill_early_accept \| (WAITWR+done+req)) && accept_ok` |
| `ram_read_en` | `accept_new_req` |
| `enter_refill` | `(LOOKUP miss+rd_rdy) \| (LOOKUP cacop) \| (WAITRD+rd_rdy)` |
| `refill_last` | `main_refill && return_valid && return_last` |
| `use_mmu_buf` | `main_lookup && mmu_buf_valid` |
| `effective_cancel` | `use_mmu_buf ? mmu_buf_cancel : mmu_cancel` |
| `cache_hit` | `(\|way_hit) && !cacop_en_r && !effective_cancel` |
| `vc_serve` | `main_lookup && !cache_hit && vc_hit && !effective_cancel` |
| `vc_exchange_lookup` | `main_lookup && vc_serve && !wb_write` |
| `vc_exchange_waitwb` | `main_waitwb && !wb_write` |
| `wr_req` | `(main_lookup && miss_needs_write) \| (refill_needs_write && !refill_wr_handshaked)` |
| `miss_needs_write` | `!effective_cancel && (cacop ? (cacop_wb && cacop_dirty) : (((mmu_cache \| mmu_buf_cached) && victim_dirty) \| is_uncached_store))` |
| `hit_write_block` | `wb_write && cpu_req && main_lookup && cache_hit && req_d` |
| `wb_stall` | `wb_write && ram_read_en` |
| `wb_fwd_active` | `main_lookup && wb_write && !req_d && 同 index/way/bank` |
| `read_result_ready` | `read_hit_done \| vc_read_done \| read_miss_done` |
| `cpu_addr_ok` | `accept_new_req && !cacop_en` |
| `cpu_data_ok` | `read_result_ready \| !cpu_fifo_empty \| write_done` |
| `mmu_buf_capture` | `main_refill && refill_already_accept_new_req && !mmu_buf_valid` |
