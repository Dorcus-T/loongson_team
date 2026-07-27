# ICache 设计文档

## 1. 架构概览

| 参数 | 值 | 说明 |
|------|-----|------|
| 组相联 | 2-way | `WAY_NUM = 2` |
| 索引位宽 | 8 bit | `INDEX_WIDTH = 8`，共 256 组 |
| Tag 位宽 | 20 bit | `TAG_WIDTH = 20` |
| 偏移位宽 | 4 bit | `OFFSET_WIDTH = 4`，16 字节 cache line |
| 每行 Bank 数 | 4 | 每 Bank 32-bit，4 Bank = 128-bit |
| 替换策略 | 树状 PLRU | WAY_NUM-1 = 1 bit/组 |
| RAM 类型 | 单端口同步 | `sp_ram`，Vivado BRAM 推断，读延迟 1 拍 |

**地址划分（32-bit 虚地址）：**

```
|  TAG [31:12]  |  INDEX [11:4]  |  OFFSET [3:0]  |
|    20 bit      |     8 bit      |     4 bit       |
```

**Cache 行结构（每 way × 每 index）：**

```
|  V (1b)  |  TAG (20b)  |  Data Bank0 (32b)  |  Bank1 (32b)  |  Bank2 (32b)  |  Bank3 (32b)  |
```

**MMU 并行化**：MMU（虚实地址转换）与 cache 并行工作。CPU 请求 accept 时 cache 只拿到 `cpu_index` 和 `cpu_offset`；**下一拍** MMU 输出 `mmu_tag` / `mmu_cache` / `mmu_cancel` 到达，此时 cache 正好进入 LOOKUP 状态进行 tag 比较。

---

## 2. Buffer 设计

### 2.1 Request Buffer

`accept_new_req` 时更新，在 LOOKUP 期间保持稳定。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `req_index` | 8 | 请求 index |
| `req_offset` | 4 | 请求 offset（选中哪个 Bank） |
| `cacop_en_r` | 1 | CACOP 使能（锁存） |
| `cacop_code_r` | 5 | CACOP 操作码 |
| `cacop_way_r` | 1 | CACOP 目标路号 |
| `cacop_index_r` | 8 | CACOP 目标 index |
| `cacop_is_index_r` | 1 | CACOP 是否 index 操作 |
| `cacop_is_hit_r` | 1 | CACOP 是否 hit 操作 |

**不再包含 `req_tag` / `req_cached`**：这些信号现在从 MMU 端口（`mmu_tag` / `mmu_cache`）获取，与 request accept 错开一拍到达。

**更新时序**：

```
if (accept_new_req):
    req_index   <= cacop_en ? cacop_index : cpu_index
    req_offset  <= cpu_offset
    cacop_en_r  <= cacop_en
    ...
```

- 普通取指：`req_index` ← `cpu_index`，`req_offset` ← `cpu_offset`
- CACOP：cacop 上下文锁存
- REFILL 中 CACOP 完成后 `cacop_en_r` 清零

### 2.2 Refill Buffer

`main_lookup && !cache_inst_hit && !effective_cancel`（LOOKUP miss 拍）从 Request Buffer 快照，整个 REFILL 期间不变。比 `enter_refill` 早一拍——若 miss 后先入 WAITRD，Refill Buffer 已在 LOOKUP 拍锁好。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_index` | 8 | 写回 index |
| `refill_tag` | 20 | 写回 tag（来源：`use_mmu_buf ? mmu_buf_tag : mmu_tag`） |
| `refill_offset` | 4 | 原始请求的 offset（用于 `read_miss_done` 判断） |
| `refill_cached` | 1 | 是否 cached（来源：`use_mmu_buf ? mmu_buf_cached : mmu_cache`） |
| `refill_replace_way` | 1 | 替换目标路号（LOOKUP miss 拍从 `victim_way` 快照） |
| `refill_cnt` | 2 | 已接收数据拍数（0..3） |
| `refill_line[0:3]` | 4×32 | cache line 拼装缓冲区 |

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

**时序示意**：
```
Cycle       | REFILL(N-1)         | REFILL(N)           | REFILL(last)        | LOOKUP
------------|---------------------|---------------------|---------------------|--------
事件         | refill_early_accept | mmu_buf_capture     | refill_last         | use_mmu_buf=1
            | accept_new_req=1    | mmu_buf_valid=1     | FSM → LOOKUP        | lookup_tag=mmu_buf_tag
            | ram_read_en=1       |                     |                     | 正常命中/缺失判定
```

---

## 3. 状态机

### 3.1 状态编码

```
IDLE (0001) → LOOKUP (0010) → WAITRD (0100) → REFILL (1000)
```

### 3.2 状态跳转图

```
                    ┌──────────────────────────────────┐
                    │                                  │
                    ▼                                  │
    ┌──────┐  accept   ┌─────────┐  hit+done    │
    │ IDLE │ ────────> │ LOOKUP  │ ────────────>│
    └──────┘           └─────────┘               │
        ▲               │    │                   │
        │       miss+   │    │ miss+             │
        │       rd_rdy  │    │ !rd_rdy           │
        │               ▼    ▼                   │
        │          ┌──────────┐                  │
        │          │  REFILL  │◄────┐            │
        │          └──────────┘     │            │
        │               │    WAITRD │            │
        │               │    ┌──────┘            │
        │          refill_last                   │
        │          or cacop_en_r                 │
        └──────────────────────┘
```

### 3.3 各状态详述

#### IDLE

- **进入**: 复位，或 LOOKUP/REFILL 无后续请求时
- **退出**:
  - `accept_new_req`（`idle_accept`）→ LOOKUP
- **RAM 动作**: `ram_read_en = 1`，读 tagv + bank
- **PLRU**: accept 时更新 `plru_victim_r`

#### LOOKUP

- **进入**: 从 IDLE accept，或从 LOOKUP 自循环（连续 accept/hit），或从 REFILL early-accept 后
- **MMU 信号有效**: `mmu_tag` / `mmu_cache` / `mmu_cancel` 在本拍到达（来自端口或 MMU Buffer）
- **tagv_rdata 有效**: 上一拍的 `ram_read_en` 在该拍产生 rdata
- **分支**（按优先级）:
  1. `effective_cancel` → IDLE（MMU 取消，丢弃当前请求）
  2. `cacop_en_r` → REFILL（CACOP 直接进 REFILL 写 tagv）
  3. `!cache_inst_hit && rd_rdy` → REFILL（miss 且总线就绪）
  4. `!cache_inst_hit && !rd_rdy` → WAITRD（miss 但总线未就绪）
  5. `accept_new_req` → LOOKUP 自循环（连续 accept）
  6. 否则 → IDLE
- **data_ok**: `read_hit_done = main_lookup && cache_inst_hit`
- **PLRU**: `plru_upd_en = main_lookup && cache_inst_hit`

#### WAITRD

- **进入**: LOOKUP miss 但 `rd_rdy = 0`
- **退出**: `rd_rdy` → REFILL
- **RAM 动作**: 无（保持上一拍 rdata）
- **rd_req**: 保持为 1（持续请求总线）

#### REFILL

- **进入**: `enter_refill`（LOOKUP miss+rd_rdy、LOOKUP cacop、或 WAITRD+rd_rdy）
- **Refill Buffer 快照**: `main_lookup && !cache_inst_hit && !effective_cancel` 拍（比 enter_refill 早一拍），锁存 `req_*`、`victim_way`、`refill_cnt=0`、以及 MMU 来源的 tag/cache
- **第 0–3 拍（return_valid）**: `refill_line[refill_cnt] <= return_data`，`refill_cnt++`
- **`read_miss_done`**: `main_refill && return_valid && (refill_cnt == refill_offset[3:2] || !refill_cached)`
- **`refill_last` 拍**:
  - TagV + Bank RAM 写回
  - PLRU 更新（`refill_replace_way` 标 MRU）
- **退出**:
  - CACOP / uncached → IDLE
  - `refill_already_accept_new_req` → LOOKUP（提前 accept 的请求等待判定）
  - 否则 → IDLE

---

## 4. 特殊机制一：REFILL 提前取指令

### 4.1 动机

普通 REFILL 期间（2-way × 4 bank，约 4 拍），CPU 空闲等待。如果当前 miss 行就是 CPU 下一拍要取的行，可以提前接受新请求、预读 RAM，REFILL 结束后直接进 LOOKUP 判定，省掉 1 拍。

### 4.2 触发条件

```verilog
assign refill_early_accept = main_refill && !refill_last
                           && !refill_already_accept_new_req
                           && !cacop_en_r
                           && !cacop_en
                           && cpu_req
                           && mmu_cache;
```

- `mmu_cache` 由 MMU 端口在本拍给出——此时 `cpu_req` 有效，MMU 并行输出 `mmu_cache`
- 每个 REFILL 只 accept **一次**
- CACOP REFILL 不适用
- REFILL 末拍不适用（`!refill_last`）

### 4.3 时序

```
Cycle   | REFILL(0)          | REFILL(1)          | REFILL(last)       | LOOKUP
--------|--------------------|--------------------|--------------------|--------------
事件    | refill_early_accept| mmu_buf_capture    | tagv/bank 写回      | Tag/Data Bypass
        | accept_new_req = 1 | tagv_rdata 更新     | refill_already...=0 | 统一判定命中/缺失
        | ram_read_en = 1    | (新请求的 index)    | FSM → LOOKUP       |
        | req_buffer 更新     |                    |                    |
        | refill_already...=1|                    |                    |
信号    | cpu_addr_ok = 1    |                    |                    | data_ok 产生
```

- **REFILL 中间拍**：只做 `ram_read_en` + `req_buffer` 更新，不做命中/缺失判定，不返回 `data_ok`
- **REFILL 下一拍**：MMU 数据到达 → MMU Buffer 捕获（`mmu_buf_capture`）
- **REFILL 末拍**：TagV/Bank 正常写回，FSM 进 LOOKUP
- **LOOKUP 拍**：使用 MMU Buffer 中的 tag/cache/cancel，通过 **Tag/Data Bypass** 统一做命中/缺失判定

### 4.4 Tag/Data Bypass

进入 LOOKUP 时，REFILL 的写回数据尚未在 RAM 中可见（RAM 写延迟）。bypass 逻辑用 `refill_tag` 和 `refill_line` 覆盖 RAM 输出：

```verilog
assign bypass_active = main_lookup && refill_already_accept_new_req
                     && (req_index == refill_index);

// Tag bypass: 替换路用 {refill_tag, 1'b1} 替代 RAM 过期的 tagv_rdata
assign tagv_lookup[way] = (bypass_active && way == refill_replace_way)
                        ? {refill_tag, 1'b1}
                        : tagv_rdata[way];

// Data bypass: 替换路命中时从 refill_line 取数据
assign hit_word = (bypass_active && hit_way_idx == refill_replace_way)
                ? refill_line[req_offset[3:2]]
                : bank_rdata[hit_way_idx][req_offset[3:2]];
```

### 4.5 限制

- 每个 REFILL 只 accept **一次**（`refill_already_accept_new_req` 阻止重复）
- CACOP REFILL 不适用（`!cacop_en_r` 排除）
- REFILL 末拍不适用（`!refill_last`）

---

## 5. 数据通路

### 5.1 数据来源

```
live_rdata =
  1. read_hit_done  → hit_word     （命中: bank_rdata[hit_way_idx][offset] 或 bypass）
  2. read_miss_done → return_data  （miss: AXI 返回数据）
  3. 其他           → 0
```

所有数据源统一通过 `live_data_ready → FIFO → cpu_data_ok + cpu_rdata`，无旁路。

### 5.2 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- FIFO 满时 `accept_ok = 0`，反压上游
- `accept_ok = (cpu_fifo_cnt < 3)`：保留 2 个空位（当前请求 + 可能的下一请求）
- FIFO 空且数据就绪时，数据直通（bypass FIFO）
- 先 accept 先返回，顺序不乱；IF 阶段冲刷不影响 cache 侧

### 5.3 CPU 接口契约

- 一次 `cpu_addr_ok` 握手 → 一次 `cpu_data_ok` + 对应数据
- `cpu_addr_ok` 来源：`accept_new_req && !cacop_en`

---

## 6. PLRU 替换算法

### 6.1 数据结构

2-way 时 PLRU 树只需 1 bit/组 × 256 组 = 256 bit：

```
plru[index][0] = 0 → way0 是 MRU
plru[index][0] = 1 → way1 是 MRU
```

### 6.2 两阶段时序

- **Accept 拍**：组合遍历 PLRU 树 → `plru_victim_pre` → `plru_victim_r`（锁存）
- **LOOKUP 拍**：`victim_way = has_invalid ? invalid_way : plru_victim_r`

### 6.3 更新

- **命中**: `plru_upd_way = hit_way_idx`
- **填充**: `plru_upd_way = refill_replace_way`

---

## 7. CACOP 处理

### 7.1 操作码

| code[4:3] | 类型 | 说明 |
|-----------|------|------|
| 00 | Index Invalidate | 指定 index 的指定路 V←0 |
| 01 | Index Store Tag | 指定 index 的指定路写入 tag |
| 10 | Hit Invalidate | 命中路 V←0 |
| 11 | — | 预留 |

### 7.2 流程

```
accept_new_req (cacop_en=1)
    → req_buffer 锁存 cacop 上下文
    → LOOKUP (读 tagv)
    → 直接进 REFILL（无总线事务）
    → REFILL 中 cacop_en_r 触发 tagv 写
    → 写完后 cacop_en_r ← 0，FSM → IDLE
```

- CACOP 的 `victim_way`：code=10(hit) 用 `hit_way_idx`，否则用 `cacop_way_r`
- CACOP 不产生 `cpu_data_ok`（`cache_inst_hit = (|way_hit) && !cacop_en_r && !effective_cancel`）
- CACOP REFILL 不接受提前 accept
- **CACOP tag 来源**：`mmu_cacop_tag`（独立端口，不走 MMU Buffer）

---

## 8. AXI 读接口

| 信号 | 说明 |
|------|------|
| `rd_req` | LOOKUP miss 或 WAITRD，且 `!cacop_en_r` 且 `!effective_cancel` |
| `rd_type` | cached→`3'b100`（cache line 读），uncached→`3'b010`（单字读） |
| `rd_addr` | cached: `{tag, index, 4'b0}`；uncached: `{tag, index, offset}` |
| `rd_rdy` | AXI 总线就绪 |
| `return_valid/return_last/return_data` | AXI 读返回通道 |

- `rd_addr` 的 tag/cached 来源：LOOKUP 状态用 MMU 端口/Buffer 值，WAITRD/REFILL 状态用 Refill Buffer 快照

---

## 9. uncached 访问

- `mmu_cache = 0`（来自 MMU 端口或 MMU Buffer）时：
  - `way_hit` 强制为 0（`lookup_cached || cacop_en_r` 为 0）
  - `cache_inst_hit = 0`（必然 miss）
  - LOOKUP 必然进入 WAITRD → REFILL
  - REFILL 中不写 tagv（`refill_cached = 0`）
  - `read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
  - AXI `rd_addr` 使用 offset 精确地址
- uncached REFILL 不退化为 LOOKUP，直接回 IDLE

---

## 10. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数 |
| `perf_access_cnt` | cached 访问进入 LOOKUP 的次数（不含 cacop） |
| `perf_miss_cnt` | cached miss 次数 |
| `perf_real_miss_cnt` | 同上（冗余，与 miss_cnt 一致） |

- cached 判断来自 `use_mmu_buf ? mmu_buf_cached : mmu_cache`

---

## 11. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer 中的信号 |
| `refill_*` | Refill Buffer 中的信号 |
| `mmu_buf_*` | MMU Buffer 中的信号 |
| `cpu_*` | CPU 接口信号 |
| `mmu_*` | MMU 输入端口（`mmu_tag` / `mmu_cache` / `mmu_cancel` / `mmu_cacop_tag`） |
| `cacop_*` | CACOP 接口/上下文信号 |
| `plru_*` | PLRU 替换算法相关 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `(idle_accept \| hit_accept \| refill_early_accept) && accept_ok` |
| `ram_read_en` | `accept_new_req` |
| `ram_raddr` | `cacop ? cacop_index : cpu_index` |
| `enter_refill` | `(LOOKUP + cacop) \| (LOOKUP + miss + rd_rdy) \| (WAITRD + rd_rdy)` |
| `refill_last` | `main_refill && return_valid && return_last` |
| `effective_cancel` | `use_mmu_buf ? mmu_buf_cancel : mmu_cancel` |
| `cache_inst_hit` | `(\|way_hit) && !cacop_en_r && !effective_cancel` |
| `read_result_ready` | `read_hit_done \| read_miss_done` |
| `cpu_addr_ok` | `accept_new_req && !cacop_en` |
| `cpu_data_ok` | `live_data_ready \| !cpu_fifo_empty` |
| `use_mmu_buf` | `main_lookup && mmu_buf_valid` |
| `mmu_buf_capture` | `main_refill && refill_already_accept_new_req && !mmu_buf_valid` |
