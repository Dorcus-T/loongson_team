# Cache 模块设计文档 — 激进版（时序 / 周期级）

> 2026-07-19，基于当前激进优化后的 cache 设计。
> 本文档记录**周期级时序**（各场景状态流转、每请求消耗拍数）。
> 组合逻辑路径分析见 `CLAUDE_TIMING.md`（激进版）。
> 缓和版见 `CLAUDE_CACHE_CONSERVATIVE.md`（周期时序）、`CLAUDE_TIMING_CONSERVATIVE.md`（组合路径）。
> I-cache 和 D-cache 行为差异已明确标注。

---

## 1. 顶层参数

```verilog
`define WAY_NUM      2          // 组相联路数
`define INDEX_WIDTH  8          // 组索引位宽 → 256 组
`define TAG_WIDTH    20         // tag 位宽
`define OFFSET_WIDTH 4          // 行内偏移位宽 → 16B / 4 word per line
```

导出量：
- 容量 = WAY_NUM × 2^INDEX_WIDTH × 2^OFFSET_WIDTH = **2 × 256 × 16 = 8KB**
- tagv RAM = WAY_NUM × 256 × (TAG_WIDTH+1) bit
- bank RAM = WAY_NUM × 4 bank × 256 × 32 bit
- PLRU = 256 × (WAY_NUM-1) bit（2 路 = 256 bit，即 1-bit LRU）

例化参数：

| 参数 | u_icache | u_dcache |
|------|----------|----------|
| IS_ICACHE | 1 | 0 |
| VC_EN | 0 | 1 |
| VC_DEPTH | — | 4 |

**I-cache 特有的功能**：顺序预取（`IS_ICACHE=1` 使能）。
**D-cache 特有的功能**：Victim Cache（`VC_EN=1` 使能）、Write Buffer。
**共用**：其余全部逻辑。

---

## 2. 状态机

### 2.1 独热码编码（5 状态）

```verilog
localparam MAIN_IDLE    = 5'b00001;   // bit 0
localparam MAIN_LOOKUP  = 5'b00010;   // bit 1
localparam MAIN_SWAP    = 5'b00100;   // bit 2 — WB 写窗口冲突修复
localparam MAIN_REPLACE = 5'b01000;   // bit 3 — 等 bridge 握手
localparam MAIN_REFILL  = 5'b10000;   // bit 4 — 收 burst 数据
```

MAIN_VCFILL 已删除：干净 VC 交换在 LOOKUP 当拍完成。

### 2.2 状态转移图

```
                    ┌──────────────────────────────────────────────┐
                    │  hit + 衔接 / launch_prefetch_lookup         │
                    │                                              │
                    ▼                                              │
  ┌──────┐  accept   ┌─────────┐  goto_swap   ┌──────┐           │
  │ IDLE │ ────────► │ LOOKUP  │ ───────────► │ SWAP │──┐        │
  └──────┘           └────┬─────┘              └──────┘  │        │
       ▲                  │                               │        │
       │     ┌────────────┼───────────────┐               │        │
       │     │            │               │               ▼        │
       │     │ miss       │ miss          │ hit     ┌─────────┐    │
       │     │ +rd_rdy    │ +双发成功      │ vc_clean│ LOOKUP  │    │
       │     │ +!wr_needed│ +rd_rdy+wr_rdy│         │ (重判)  │    │
       │     ▼            ▼               │         └─────────┘    │
       │  ┌─────────┐ ┌─────────┐         │               │        │
       │  │ REFILL  │ │ REFILL  │         │               │        │
       │  └────┬────┘ └────┬────┘         │               │        │
       │       │            │              │               │        │
       │       │ last       │ last         │               │        │
       │       ▼            ▼              │               │        │
       │  ┌──────────────────┘              │               │        │
       │  │  ┌──────────────────────────────┘               │        │
       │  │  │  miss + bridge 忙                           │        │
       │  │  │  (进 REPLACE 等)                             │        │
       │  ▼  ▼  ▼                                           │        │
       │ ┌─────────┐                                         │        │
       │ │ REPLACE │◄────────────────────────────────────────┘        │
       │ └────┬────┘                                                  │
       │      │ wr_rdy / rd_rdy 就绪                                   │
       │      ▼                                                        │
       │  回 IDLE / REFILL ───────────────────────────────────────────┘
```

### 2.3 REPLACE 的新职责

REPLACE 不再主动发起总线请求。所有 rd_req 和 wr_req 均在 LOOKUP 状态发出。
REPLACE 的唯一职责是**等待 bridge 空闲**——等 rd_rdy 或 wr_rdy 握手完成。

---

## 3. 核心优化项（激进版新增）

| 优化 | 说明 | 效果 |
|------|------|------|
| **独热码状态** | 5 状态独热编码，`main_idle/lookup/...` 从多 bit 比较退化为单 bit 检查 | 几十处引用省 1~2 级门 |
| **PLRU 预计算** | 接受拍算好 `plru_victim_r` 锁存，LOOKUP 拍从 FF 出发 | 砍掉 LOOKUP 拍 256:1 mux |
| **VCFILL 删除** | 干净 VC 交换在 LOOKUP 当拍完成，BRAM 写使能从组合逻辑出发 | 省 1 拍/VC hit clean |
| **双发** | rd_req + wr_req 均在 LOOKUP 发出，双握手成功直通 REFILL | 脏 miss 省 1~2 拍 |
| **窗口二消除** | WB 写同组同路时，victim 行数据合并 `wb_wdata` 修正，不触发 SWAP | SWAP 仅在窗口一 + vc_fill_conflict 触发 |
| **hit_word 二进制选择** | `hit_way_idx` 直接索引 `bank_rdata` 替代一热 OR 归约 | 减少组合级数 |
| **vc_line 功耗门控** | 非 VC 活跃拍输出全 0 | 减少翻转 |
| **早重启** | miss 关键字拍即返 CPU，不等 `return_last` | 减小有效延迟 |
| **空路优先替换** | tagv valid=0 的路优先做 victim，避免 PLRU 踢有效行 | 减少 conflict miss |

---

## 4. RAM 架构

```
每路包含：
  ┌─ sp_ram: TagV    (TAG_WIDTH+1 bit × 256)   ← 同步 BRAM，tag + valid
  ├─ sp_ram: Bank 0  (32 bit × 256)            ← 同步 BRAM，word 0
  ├─ sp_ram: Bank 1  (32 bit × 256)            ← 同步 BRAM，word 1
  ├─ sp_ram: Bank 2  (32 bit × 256)            ← 同步 BRAM，word 2
  ├─ sp_ram: Bank 3  (32 bit × 256)            ← 同步 BRAM，word 3
  └─ reg:    D bit   (1 bit × 256)             ← 分布式寄存器，脏标志
```

- 全单端口同步 BRAM，读/写自己保证不同拍
- D bit 用分布式寄存器：读在 LOOKUP，写在 WB_WRITE / REFILL / VCFILL 交换拍

---

## 5. I-cache 与 D-cache 差异一览

| 功能 | I-cache | D-cache |
|------|---------|---------|
| 状态机 | ✓ 共用 | ✓ 共用 |
| 替换算法 | ✓ PLRU 预计算 | ✓ PLRU 预计算 |
| 双发 (rd+wr) | rd 直发 | rd+wr 双发 |
| Write Buffer | ✗ 无 store | ✓ store 命中锁存 |
| 预取 | ✓ IS_ICACHE=1 | ✗ |
| Victim Cache | ✗ VC_EN=0 | ✓ VC_EN=1 |
| VC 交换 | ✗ | ✓ clean/dirty swap |
| SWAP 碰撞修复 | ✓（取指 miss 可能撞 WB） | ✓ |
| CACOP | ✗ 无 | ✓ |

---

## 6. 各场景周期级时序

> 记法：T0 = IDLE 接受拍或 LOOKUP 衔接拍，T1 = 请求的 LOOKUP 拍。
> 延迟 = CPU 从发请求到收到 `cpu_data_ok` 的拍数。

---

### 6.1 Cacheable Load — L1 命中（I-cache / D-cache 通用）

```
T0  IDLE：accept_new_req=1，锁存 req_*, PLRU 预计算（ram_raddr_req 作 index）
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：ram_read_en=1，读 tagv + bank
    tag 命中 → cache_hit=1 → hit_word → lookup_rdata → cpu_rdata
    cpu_data_ok=1，CPU 取走数据
    ── 拍末 main_state ← IDLE（无衔接）或 LOOKUP（衔接新请求/预取）
```

**延迟：1 拍**（从 accept 到 data_ok）。

---

### 6.2 Cacheable Store — L1 命中（仅 D-cache）

```
T0  IDLE：accept_new_req=1，锁存 req_*, PLRU 预计算
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：ram_read_en=1，读 tagv + bank
    tag 命中 → lookup_store_hit → 锁存进 Write Buffer（wb_way_hit, wb_index, wb_bank, wb_wstrb_mask, wb_wdata）
    write_done=1 → cpu_data_ok（store posted）
    ── 拍末 main_state ← IDLE，wb_state ← WB_WRITE
T2  WB_WRITE：bank RAM 写（wen = wstrb_mask），d_ram 写 1（脏）
    ── 拍末 wb_state ← WB_IDLE（无连续 store hit）
```

**延迟：1 拍**（posted write，CPU 在 LOOKUP 拍即被告知完成）。

---

### 6.3 Cacheable Load — Clean Miss + Bridge 读空闲（D-cache 双发版本例）

```
T0  IDLE：accept_new_req=1，锁存 req_*, PLRU 预计算
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：ram_read_en=1，读 tagv + bank
    tag 未命中，victim 干净 → miss_needs_write=0
    rd_req_lookup=1, rd_rdy=1 → rd_req 握手，miss_refill_cnt←0
    ── 拍末 main_state ← REFILL（直通）
T2  REFILL[0]：return_valid，miss_refill_cnt=0
    关键字就是本拍 → 早重启！read_miss_done=1 → cpu_data_ok
    refill_buffer[0] ← return_data
    ── 拍末 miss_refill_cnt←1
T3  REFILL[1]：return_valid → refill_buffer[1]
    ── 拍末 miss_refill_cnt←2
T4  REFILL[2]：return_valid → refill_buffer[2]
    ── 拍末 miss_refill_cnt←3
T5  REFILL[3]：return_valid + return_last
    → 4 bank 同时写（refill_buffer[0..2] + 实时 data）
    → tagv RAM 写 {req_tag, V=1}、d_ram 写 0（干净）、PLRU 更新
    → 干净 victim 插入 VC（D-cache）
    ── 拍末 main_state ← IDLE
```

**延迟：2 拍**（T0 accept → T2 早重启送 data_ok。如果关键字在 offset 0，T2 即到；如果关键字在 offset 3，T5 才到）。

I-cache 版本：无 VC 插入，其余相同。

---

### 6.4 Cacheable Load — Dirty Miss + Bridge 双空闲（双发直通）

```
T0  IDLE：accept_new_req=1，锁存 req_*, PLRU 预计算
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：ram_read_en=1，读 tagv + bank
    tag 未命中，victim 脏 → miss_needs_write=1
    rd_req_lookup=1, rd_rdy=1 → rd_req 握手！
    wr_req_lookup=1, wr_rdy=1 → wr_req 握手！双发成功！
    miss_refill_cnt←0, wr_req_accepted←1
    ── 拍末 main_state ← REFILL（直通，跳过 REPLACE！）
T2  REFILL[0]：return_valid（读数据开始到达）
    关键字拍 → 早重启 → cpu_data_ok
    ...
T5  REFILL[3]：return_last → 4 bank + tagv + d_ram 写
    ── 拍末 main_state ← IDLE
```

**延迟：2 拍**（同 clean miss 最优路径！脏 miss 不再多等）。

---

### 6.5 Cacheable Load — Dirty Miss + Bridge 只有读空闲

```
T0  IDLE：accept_new_req=1
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：cache_hit=0，victim 脏
    rd_req_lookup=1, rd_rdy=1 → rd_req 握手 ✓
    wr_req_lookup=1, wr_rdy=0 → wr_req 未握手 ✗
    miss_refill_cnt←0
    ── 拍末 main_state ← REPLACE（只等 wr）
T2  REPLACE：wr_req 持续拉高，等 wr_rdy
    wr_rdy=1 → wr_req_accepted←1 → main_next ← REFILL
    ── 拍末 main_state ← REFILL
T3  REFILL[0]：return_valid...
```

**比双发多等 1 拍 REPLACE**（仅当写通道忙时）。读在 LOOKUP 已发出，不重复等。

---

### 6.6 Cacheable Load — Dirty Miss + Bridge 双忙（进 REPLACE 等两个握手）

```
T0  IDLE：accept_new_req=1
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：cache_hit=0，victim 脏
    rd_req_lookup=1, rd_rdy=0 → 未握手
    wr_req_lookup=1, wr_rdy=0 → 未握手
    ── 拍末 main_state ← REPLACE
T2  REPLACE：rd_req + wr_req 均拉高，等 bridge
    wr_rdy=1 → wr_req_accepted←1
    rd_rdy=1 → main_next = REFILL
    ── 拍末 main_state ← REFILL
T3  REFILL[0]...
```

**REPLACE 只等握手，不发起新请求**（请求在 T1 LOOKUP 已发出，持续拉高直到握手）。

---

### 6.7 Cacheable Store — L1 Miss（仅 D-cache）

```
T0  IDLE：accept_new_req=1（req_op=1, req_cached=1）
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：cache_hit=0，victim 脏/干净
    若 victim 脏：rd_req_lookup + wr_req_lookup 双发（同 6.4 路径）
    若 victim 干净：rd_req_lookup 单发（同 6.3 路径）
    ── miss_needs_write 决定路径
    ...（后续同 load miss 路径，区别在 REFILL）
T_last  REFILL 末拍：4 bank 写，d_ram 写 1（脏！因为 store）
    refill_merged_word：store 目标 word = (wdata & wstrb) | (ret_data & ~wstrb)
```

**Store miss 不需要单独等 wr_req**——store 数据在 req_wdata 里锁存着，REFILL 时合并进去即可。只有 victim 是脏时才需要发 wr_req 写回旧行。

---

### 6.8 Uncached Load（I-cache / D-cache）

```
T0  IDLE：accept_new_req=1（req_cached=0）
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：读 tagv + bank。req_cached=0 → cache_hit=0 恒成立
    rd_req_lookup=1（need_bus_rd=1, !vc_hit=1）
    若 rd_rdy=1 → 直通 REFILL；否则 → REPLACE 等
T2-T_last  REFILL：return_valid（AXI 单拍 burst，return_last=1）
    数据直接 return_data → cpu_rdata
    不写 bank/tagv/d_ram
    ── 拍末 main_state ← IDLE
```

---

### 6.9 Uncached Store（仅 D-cache）

```
T0  IDLE：accept_new_req=1（req_cached=0, req_op=1）
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：cache_hit=0。miss_needs_write=1（is_uncached_store）
    wr_req_lookup=1（!wb_collide, !vc_fill_conflict）
    若 wr_rdy=1 → wr_req_accepted←1 → main_next = REPLACE（等 wr_done）
    若 wr_rdy=0 → main_next = REPLACE（等 wr_rdy + wr_done）
T2  REPLACE：wr_req_accepted=1 后等 wr_done
    wr_done=1 → main_next = IDLE
```

**延迟：取决于 AXI 写通道延迟**。不写任何 cache RAM。

---

### 6.10 VC Hit + Clean Victim — 当拍交换（仅 D-cache）

```
T0  IDLE：accept_new_req=1
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：ram_read_en=1
    cache_hit=0, vc_hit=1（L1 miss, VC 命中）
    victim_dirty=0 → vc_fill_lookup=1
    当拍动作：
      ● load → vc_word → cpu_rdata → cpu_data_ok
      ● store → write_done, wdata 组合合并进 vc_fill_word
      ● VC entry ← victim 行 {tag, index} + 128bit 数据（干净 victim 回填）
      ● victim way 4 bank ← vc_fill_word（换入行含 store 合并）
      ● victim way tagv ← {req_tag, V=1}
      ● victim way d_ram ← req_op
      ● PLRU 更新（标 victim way 为 MRU）
    ── 拍末 main_state ← IDLE
T2  IDLE：可受理新请求（读到的已是交换后状态）
```

**延迟：1 拍**（同 L1 hit！）。CPU 可见延迟 1 拍，cache 占用 1 拍。
**v1 不衔接**：VC 交换拍写口被占用，不接受新请求。代价仅此一拍。

---

### 6.11 VC Hit + Dirty Victim — 写通道踢出（仅 D-cache）

```
T0  IDLE：accept_new_req=1
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：L1 miss, VC hit, victim 脏
    数据交付：load → vc_word → cpu_data_ok / store → write_done
    vc_swap_wb_r ← 1（锁存脏交换模式）
    miss_replace_way ← victim_way
    wr_req_lookup=1, wr_data=lookup_wr_data（含 WB 实时前推）
    若 wr_rdy=1：
      wr_req_accepted←1, 握手拍 vc_fill_replace 完成交换写（VC entry 清空）
      ── 拍末 main_state ← IDLE
    若 wr_rdy=0：
      ── 拍末 main_state ← REPLACE
T2  REPLACE：等 wr_rdy → 握手拍 vc_fill_replace 完成 → IDLE
```

**延迟：1 拍**（CPU 数据 LOOKUP 拍即交付）。cache 占用 1~2 拍（取决于 wr_rdy）。
**全程零总线读**：rd_req 被 vc_swap_wb_r 门控，只发 wr_req 踢出脏行。

---

### 6.12 WB 碰撞 → SWAP 修复

SWAP 仅在两个条件下触发：

**条件 A — 窗口一**（accept 拍 WB 写抢占 BRAM 读口）：
单端口 BRAM 读写同时发生 → 读数据来自错误的地址，无法前推修复。

**条件 B — vc_fill_conflict**（VC 交换写和 WB 写抢同一 way 写口）：
硬件资源冲突，必须等 WB 先完成。

> 窗口二（同拍 WB 写同组同路导致 victim 数据陈旧）已由 WB 前推到 replace_line_data 和 lookup_wr_data 覆盖，不再触发 SWAP。

```
情况 A：窗口一
─────────────────
T0  某 store 在 LOOKUP 命中 → 锁存进 WB（wb_way_hit, wb_index, wb_bank）
    ── 拍末 wb_state ← WB_WRITE
T1  IDLE：CPU 发来 load/store
    accept_new_req=1 → ram_read_en=1
    同时 wb_write=1 → WB 正在写 BRAM！
    → 单端口冲突：读数据被污染
    → collide_valid_r=1, collide_wayhit_r=wb_way_hit
    ── 拍末 main_state ← LOOKUP, wb_state ← WB_IDLE（WB 排空）
T2  LOOKUP：BRAM 输出含被污染的 bank
    cache_hit=0, victim way 恰好命中 collided_way
    → wb_collide=1（仅窗口一条件）→ goto_swap=1
    但 load 的数据交付仍正常进行（若 VC 命中则 VC 提供；若 load 自己的 bank 没被污染则 data_ok）
    data_sent_r=1（抑制重入拍重复）
    ── 拍末 main_state ← SWAP
T3  SWAP：ram_read_en=1 重读（WB 已排空 → 数据新鲜）
    ── 拍末 main_state ← LOOKUP
T4  LOOKUP 重入：全新鲜数据，重判 hit/miss/VC
    data_sent_r 抑制重复 data_ok/write_done/perf 计数
    ── 正常流程继续
```

**SWAP 代价：+2 拍**（T3 SWAP + T4 LOOKUP 重入）。

```
情况 B：vc_fill_conflict
──────────────────────
T1  LOOKUP：VC hit + victim 干净，想做当拍交换写
    同时 wb_write=1, wb_way_hit[victim_way]（同 way，可能跨 set）
    → VC 交换写和 WB 写抢同一 way 的 BRAM 写口
    → vc_fill_conflict=1 → goto_swap=1
    ── 拍末 main_state ← SWAP
T2  SWAP：WB 排空完成
    ── 拍末 main_state ← LOOKUP
T3  LOOKUP 重入：写口空闲，vc_fill_lookup 重新触发 → 当拍交换
    → main_next = IDLE
```

---

### 6.13 预取 — I-cache 专属

#### 6.13.1 预取触发

```
CPU 取指完成（hit 或 refill）+ main_next=IDLE + is_ifetch（取指、cached、非 CACOP）
→ set_prefetch_pending=1
→ prefetch_addr = 当前行地址 + 16（下一行）

发起时机：
  ├─ IDLE：launch_prefetch_idle — 空闲时发起挂起的预取
  └─ LOOKUP hit：launch_prefetch_lookup — 取指命中后同拍发起（不经过 IDLE）
```

#### 6.13.2 预取 LOOKUP 四种结果

| 结果 | 条件 | 动作 |
|------|------|------|
| 预取命中 | `cache_hit=1` | prefetch_active 清除，无后续（行已在 L1） |
| 预取 miss + CPU 匹配 | `prefetch_cpu_match` | prefetch_active 清除，数据直接给 CPU |
| 预取 miss + CPU 不匹配 | `prefetch_mismatch` | abort（LOOKUP/REPLACE 阶段不发总线请求） |
| 预取 miss 正常 | 无 abort | 正常 miss 流程 → rd_req → REFILL，数据写 cache |

#### 6.13.3 预取 abort 与直通受理

```
预取 LOOKUP miss + CPU 失配=CACOP 到达：
  → prefetch_abort_req=1
  → 尚未上总线 → 不发 rd_req
  → 能受理新请求 → accept_new_req → 新请求直通 LOOKUP（不到 IDLE 中转）
```

#### 6.13.4 REFILL 期间预取数据照写

```
预取在 REFILL 阶段被冲刷：不中断 burst，数据照常写入 cache
（不浪费已发生的总线传输，未来可能命中）
CFU 失配的最后一拍：可同时受理新请求（压写路径）
```

---

### 6.14 CACOP（仅 D-cache）

```
T0  IDLE：accept_new_req=1（cacop_en=1），锁存 cacop_*
    ── 拍末 main_state ← LOOKUP
T1  LOOKUP：cacop_en_r=1 → cache_hit=0（强制），但 way_hit 正常判断
    LOOKUP 拍并行清 VC：
      code 10（命中清）：按全地址 {tag, index} 精确失效
      code 00/01（索引清）：按 index 字段匹配失效
      code 11（无操作）：不动
    miss_needs_write 判断（脏行需写回）
    ── 拍末 main_state ← REPLACE
T2  REPLACE：
    若 miss_needs_write=1 且 wr 未握手 → 等 wr_rdy
    否则 → main_next = REFILL
T3  REFILL（CACOP 用 REFILL 状态写 tagv）：
    → tagv_do_write：写 TagV
      code 00：wen=全字节，写全 0 → 清 tag + valid
      code 01：wen=仅 byte0，写 0 → 清 valid
      code 10：命中时 wen=仅 byte0，写 0 → 清 valid
    ── 拍末 main_state ← IDLE
```

---

## 7. Write Buffer（仅 D-cache）

store 命中时不直接写 bank RAM（bank RAM 正在为当前 LOOKUP 读），而是锁存进 WB：

```
T LOOKUP：store hit → wb_valid=1, wb_way_hit/idx/bank/wstrb/wdata 锁存
T+1：wb_state=WB_WRITE → bank RAM 按 wstrb_mask 写，d_ram 写 1
T+2：wb_state=WB_IDLE（无连续 store hit 则排空）
```

连续 store 到同 bank+way+index：wb_state 保持 WB_WRITE，后面的 store 覆盖 wb 寄存器。

**Hit-write conflict 处理**：
- 同一拍 load 且和上一拍的 store 写同一 bank+index → `hit_write_lookup_r` 检测
- 读数据 = `(wb_wdata & wb_wstrb_mask) | (hit_word & ~wb_wstrb_mask)` → 合并给 CPU

---

## 8. Victim Cache（仅 D-cache，VC_EN=1）

### 8.1 存储

- 全相联，VC_DEPTH 项（默认 4），clean-only（只存干净行）
- 每项 = {valid, 全地址 {tag, index}, 128b 行数据}
- 纯寄存器实现，组合读
- 替换：插入用 FIFO 指针轮转，交换为原地回填

### 8.2 不变量

**L1 ∩ VC = ∅**：同一行绝不同时在两边。仿真断言（SYNTHESIS 隔离）。

### 8.3 LOOKUP 判定表

| 判定 | 当拍动作 | 下一拍 |
|------|---------|--------|
| L1 hit | 照旧，VC 旁观 | 照旧（可衔接） |
| L1 miss + VC hit + victim 干净/空 | data_ok/write_done；交换写当拍完成；victim 回填 VC / 空 victim 清 entry | IDLE（可正常受理） |
| L1 miss + VC hit + victim 脏 | data_ok/write_done；置 vc_swap_wb_r；wr 在 LOOKUP 发出 | IDLE（wr 握手成功）或 REPLACE（等 wr） |
| L1 miss + VC hit + WB 碰撞 | data_ok/write_done；goto_swap → SWAP | SWAP 重读后 LOOKUP 重判 |
| L1 miss + VC miss | 照旧（rd_req_lookup 已 gate !vc_hit） | REPLACE/REFILL |

### 8.4 插入时机

REFILL 末拍（`return_last`）：若 victim 行有效且干净 → `vc_insert=1` → 写入 FIFO 指针指向的 entry。

---

## 9. 替换算法 — 树状 PLRU（预计算版）

### 9.1 预计算流程

```
接受拍（accept_new_req || launch_prefetch）：
  pre_plru_index ← 新请求的 index
  从 plru[pre_plru_index] 读 PLRU 位 → 树状遍历 → plru_victim_pre
  ── 拍末 plru_victim_r ← plru_victim_pre

LOOKUP 拍：
  victim_way = has_invalid ? invalid_way : plru_victim_r  （全从 FF 出发）
```

### 9.2 RAW 冒险

背靠背同 index 访问：前一次 PLRU 更新（T1 hit → 拍末写入）比后一次的预读（T1 衔接拍 → 组合读 plru[pre_plru_index]）晚一拍生效 → plru_victim_r 比最新 PLRU 状态旧一拍。
**后果**：牺牲路可能不是绝对 LRU，但不破坏正确性。命中率损失 < 0.1%。

### 9.3 更新时机

- L1 命中（非预取）→ 标访问路为 MRU
- REFILL 填充 → 标新填路为 MRU
- VC 交换 → 标换入路为 MRU
- 预取命中 → **不更新** PLRU（预取不干扰替换决策）

---

## 10. 输出 FIFO

4 深 FIFO，缓冲 miss 读结果。hit 结果走 `live_rdata` 旁路直达 CPU。

```
cpu_fifo_empty=1 且 read_result_ready=1 → live_rdata → cpu_rdata（不占 FIFO 槽位）
其他情况 → live_rdata → cpu_fifo_mem[wptr] → 等 CPU 取走
```

**accept_ok**：
- store 请求 → 永远接受（不占 FIFO）
- 读请求 → FIFO 空闲槽位 ≥ 2（当前请求 + 新请求各占一个）

---

## 11. AXI 总线接口

### 11.1 读请求（rd_req）

**LOOKUP 发射**：所有 cacheable miss（干净/脏）均在 LOOKUP 当拍发出 rd_req。
门控：`!vc_hit`（VC 命中的不需总线读）、`!prefetch_abort_req`（预取中止不发）。

**REPLACE 保持**：若 LOOKUP 拍 bridge 未握手（rd_rdy=0），REPLACE 持续拉高 rd_req 直到握手。

| 请求类型 | rd_type | rd_addr | burst |
|----------|---------|---------|-------|
| cached | 3'b100 | {tag, index, 4'b0} | 4 beat × 32bit |
| uncached load | 3'b010 | {tag, index, offset} | 1 beat |
| uncached store | 字/半字/字节 | {tag, index, offset} | 1 beat |

### 11.2 写请求（wr_req）

**LOOKUP 发射**：脏 victim miss / uncached store / CACOP 写回均在 LOOKUP 当拍尝试发 wr_req。
门控：`!wb_collide`（窗口一 → victim 数据错误）、`!vc_fill_conflict`（写口冲突）。

**wr_data**：LOOKUP 拍用 `lookup_wr_bank`（含 WB 实时前推），REPLACE 拍用 `replace_line_data`（含 `wb_collide_lookup_r` 前推）。

| 请求类型 | wr_type | wr_addr | wr_data | wr_wstrb |
|----------|---------|---------|---------|----------|
| 脏行写回 | 3'b100 | {victim_tag, victim_index, 0} | 128bit 整行 | 4'b1111 |
| uncached store | 字/半字/字节 | {tag, index, offset} | {96'd0, wdata} | wstrb |

### 11.3 双发

bridge AR/AW 通道独立 → 同一拍可同时接受 rd_req 和 wr_req。
双发成功（`rd_rdy=1 && wr_rdy=1`）→ LOOKUP 直通 REFILL，完全跳过 REPLACE。

---

## 12. 性能计数器

| 计数器 | 含义 | 计数时机 |
|--------|------|----------|
| `perf_total_req` | 总请求数 | accept_new_req |
| `perf_access_cnt` | 可缓存查找数 | main_lookup + req_cached + !cacop_en_r + !prefetch_active + !data_sent_r |
| `perf_miss_cnt` | L1 miss 次数（含 VC hit） | 同上 + !cache_hit |
| `perf_real_miss_cnt` | 真 miss（上总线） | 同上 + !cache_hit + !vc_hit |
| `perf_vc_hit_cnt` | L1 miss 但 VC hit | 同上 + !cache_hit + vc_hit |
| `perf_vc_insert_cnt` | REFILL 干净 victim 插入 VC | vc_insert |
| `perf_vc_fill_cnt` | VC 交换写次数 | vc_fill |
| `perf_prefetch_launch` | 预取发起总次数 | launch_prefetch |
| `perf_prefetch_abort` | 预取中止 | LOOKUP/REPLACE abort |
| `perf_prefetch_fill` | 预取数据写入 cache | REFILL 末拍 |

**关键指标**：
- L1 命中率 = 1 − `perf_miss_cnt` / `perf_access_cnt`
- VC 后有效 miss 率 = `perf_real_miss_cnt` / `perf_access_cnt`
- VC 抢救率 = `perf_vc_hit_cnt` / `perf_miss_cnt`
- 预取成功率 = `perf_prefetch_fill` / `perf_prefetch_launch`

---

## 13. 优化历史记录

| 阶段 | 优化 | 效果 |
|------|------|------|
| 1 | 移除 MAIN_MISS，LOOKUP miss → REPLACE | miss 路径省 1 状态 |
| 2 | LOOKUP clean miss + rd_rdy → REFILL 直通 | clean miss 再省 1 拍 |
| 3 | 早重启 | miss 有效延迟减小 |
| 4 | 下一行预取（I-cache） | 减少 I$ miss |
| 5 | 预取 abort 直通、REFILL 压写受理 | 连续操作无空闲拍 |
| 6 | Hit-write 合并 | store→load 不阻塞 |
| 7 | 空路优先替换 | 减少 conflict miss |
| 8 | PLRU 预计算 | 砍 LOOKUP 拍 256:1 mux |
| 9 | VCFILL 删除 | VC 干净交换省 1 拍 |
| 10 | 双发（rd+wr 均从 LOOKUP 发） | 脏 miss 省 1~2 拍 |
| 11 | 窗口二消除（WB 前推到 victim 行） | SWAP 触发频率减半 |
| 12 | 独热码状态编码 | 状态信号省比较器 |
| 13 | hit_word 二进制选择 | 省跨路 OR 归约 |
| 14 | vc_line 功耗门控 | 减少翻转 |
