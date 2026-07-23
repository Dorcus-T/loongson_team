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

---

## 2. Buffer 设计

### 2.1 Request Buffer

`accept_new_req`、`launch_prefetch` 或 `refill_accept_new_req` 时更新。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `req_index` | 8 | 请求 index |
| `req_tag` | 20 | 请求 tag |
| `req_offset` | 4 | 请求 offset（选中哪个 Bank） |
| `req_cached` | 1 | 是否 cached 访问 |
| `req_is_prefetch` | 1 | 当前请求是否为预取 |
| `cacop_en_r` | 1 | CACOP 使能（锁存） |
| `cacop_code_r` | 5 | CACOP 操作码 |
| `cacop_way_r` | 1 | CACOP 目标路号 |
| `cacop_index_r` | 8 | CACOP 目标 index |
| `cacop_is_index_r` | 1 | CACOP 是否 index 操作 |
| `cacop_is_hit_r` | 1 | CACOP 是否 hit 操作 |
| `req_data` | 32 | 预取前递数据（仅 `refill_accept_new_req` 时写入） |

**更新时机：**

1. `accept_new_req`（优先级 2）：正常接受 CPU/CACOP 请求 → `req_is_prefetch = 0`
2. `launch_prefetch`（优先级 3）：发射预取 → `req_is_prefetch = 1`
3. `refill_accept_new_req`（优先级 1，最高）：预取 REFILL 匹配 → `req_is_prefetch = 1`，`req_data` 锁存前递数据
4. `main_refill && cacop_en_r`（优先级 4）：CACOP REFILL 退出，清除 `cacop_en_r`
5. REFILL 结束时清除 `req_is_prefetch`（非匹配预取）
6. IDLE 下 CPU 消费预取前递数据后清除 `req_is_prefetch`

### 2.2 Refill Buffer

`enter_refill` 时从 Request Buffer 快照，整个 REFILL 期间不变。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_index` | 8 | 写回 index |
| `refill_tag` | 20 | 写回 tag |
| `refill_offset` | 4 | 原始请求的 offset（用于 `read_miss_done` 判断） |
| `refill_cached` | 1 | 是否 cached |
| `refill_is_prefetch` | 1 | 该 REFILL 是否为预取 |
| `refill_replace_way` | 1 | 替换目标路号（`enter_refill` 时从 `victim_way` 快照） |
| `refill_cnt` | 2 | 已接收数据拍数（0..3） |
| `refill_line[0:3]` | 4×32 | cache line 拼装缓冲区 |

### 2.3 顶层标志

| 标志 | 说明 |
|------|------|
| `prefetch_pending` | LOOKUP hit + last_bank 时置位，待 IDLE 空闲时发射 |
| `refill_already_accept_new_req` | REFILL 期间已提前接受一个 CPU 请求 |

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
    ┌──────┐  accept/launch   ┌─────────┐  hit+done   │
    │ IDLE │ ───────────────> │ LOOKUP  │ ────────────>│
    └──────┘                  └─────────┘               │
        ▲                      │    │                   │
        │              miss+   │    │ miss+             │
        │              rd_rdy  │    │ !rd_rdy           │
        │                      ▼    ▼                   │
        │                 ┌──────────┐                  │
        │                 │  REFILL  │◄────┐            │
        │                 └──────────┘     │            │
        │                      │    WAITRD │            │
        │                      │    ┌──────┘            │
        │                 refill_last                   │
        │                 or cacop_en_r                 │
        └──────────────────────┘
```

### 3.3 各状态详述

#### IDLE

- **进入**: 复位，或 LOOKUP/REFILL 无后续请求时
- **退出**:
  - `accept_new_req`（idle_accept）→ LOOKUP：CPU 或 CACOP 请求到来，读 RAM
  - `launch_prefetch_idle` → LOOKUP：`prefetch_pending` 且无新请求，发射预取，读 RAM
- **RAM 动作**: accept 或 launch 时 `ram_read_en=1`，读 tagv + bank
- **PLRU**: accept 时更新 `plru_victim_r`

#### LOOKUP（第 1 拍：tagv_rdata 到齐）

- **进入**: 从 IDLE accept/launch，或从 LOOKUP 自循环（连续 accept/hit）
- **tagv_rdata 有效**: 上一拍的 `ram_read_en` 在该拍产生 rdata
- **分支**:
  - `prefetch_can_cancel`（预取被中断）→ 有新请求则回 LOOKUP，否则回 IDLE
  - `cacop_en_r` → REFILL（CACOP 直接进 REFILL 写 tagv）
  - `!cache_inst_hit && rd_rdy` → REFILL（miss 且总线就绪）
  - `!cache_inst_hit && !rd_rdy` → WAITRD（miss 但总线未就绪）
  - 命中（hit）→ 有新 accept 或 launch_prefetch 则留 LOOKUP，否则 IDLE
- **data_ok**: 命中时 `read_hit_done=1` → 数据从 bank_rdata 选字输出
- **PLRU**: 命中时更新命中路为 MRU

#### WAITRD

- **进入**: LOOKUP miss 但 `rd_rdy=0`
- **退出**:
  - `prefetch_can_cancel` → 同 LOOKUP 的 cancel 路径
  - `rd_rdy` → REFILL
- **RAM 动作**: 无（保持上一拍 rdata）
- **rd_req**: 保持为 1（持续请求总线）

#### REFILL（4 拍 cache line 填充）

- **进入**: `enter_refill`（从 LOOKUP miss+rd_rdy、LOOKUP cacop、或 WAITRD+rd_rdy）
- **`enter_refill` 拍**: 快照 Request Buffer → Refill Buffer（`victim_way` 也在此拍锁存）
- **第 1–4 拍**: `return_valid` 时 `refill_line[refill_cnt] <= return_data`，`refill_cnt++`
- **`read_miss_done`**: 当 `refill_cnt == refill_offset[3:2]`（CPU 所需 Bank 到齐）时 `data_ok=1`
- **`refill_last` 拍**:
  - TagV RAM 写回（`refill_tag` + V=1，写入 `refill_replace_way` 路 `refill_index` 组）
  - Bank RAM 写回（4 Bank 同时写，`refill_line[0:2]` + `return_data`）
  - PLRU 更新（`refill_replace_way` 标 MRU）
- **退出**:
  - CACOP / uncached → IDLE
  - 预取 REFILL → IDLE（无论是否匹配）
  - 一般指令 + `refill_already_accept_new_req` → LOOKUP
  - 一般指令 + 无提前 accept → IDLE

---

## 4. 关键信号

### 4.1 请求接受

| 信号 | 条件 | 说明 |
|------|------|------|
| `idle_accept` | IDLE + (cpu_req \| cacop_en) | IDLE 接受 |
| `hit_accept` | LOOKUP + cache_inst_hit + (cpu_req \| cacop_en) + !prefetch_active | 命中接受 |
| `pf_lookup_accept` | prefetch_active + (LOOKUP \| WAITRD) + 新请求 + 非「匹配且miss」| 预取未握手时被中断 |
| `refill_early_accept` | REFILL + !refill_last + !prefetch + !cacop + cpu_req + cached | REFILL 提前接受 |
| `accept_new_req` | 以上任一 + accept_ok | 最终接受信号 |
| `refill_accept_new_req` | REFILL + refill_last + refill_is_prefetch + prefetch_cpu_match | 预取匹配接受 |

### 4.2 命中/缺失

| 信号 | 说明 |
|------|------|
| `way_hit[WAY_NUM-1:0]` | 各路 tag 比较结果（V=1 + tag 匹配 + cached 或 cacop） |
| `cache_inst_hit` | 任意路命中且非 cacop |
| `hit_way_idx` | 命中路号（优先编码） |
| `victim_way` | 受害者路号：cacop 按 code → 无效路 → PLRU |

### 4.3 数据交付

| 信号 | 条件 | 说明 |
|------|------|------|
| `read_hit_done` | LOOKUP + cache_inst_hit + !prefetch_active | 命中数据就绪 |
| `read_miss_done` | REFILL + return_valid + !prefetch_active + refill_cnt 匹配 | miss 数据就绪 |
| `live_data_ready` | read_hit_done \| read_miss_done \| (IDLE + req_is_prefetch) | 任何实时数据就绪 |
| `cpu_addr_ok` | (accept_new_req + !cacop_en) \| refill_accept_new_req | CPU 可锁存地址 |
| `cpu_data_ok` | live_data_ready \| !cpu_fifo_empty | CPU 可取数据 |

### 4.4 预取

| 信号 | 说明 |
|------|------|
| `prefetch_active` | `req_is_prefetch \|\| refill_is_prefetch` |
| `prefetch_cpu_match` | 预取活跃 + CPU 请求匹配当前预取地址 |
| `prefetch_can_cancel` | 预取在 LOOKUP/WAITRD 且 mismatch 或 cacop |
| `launch_prefetch` | `launch_prefetch_idle`（IDLE + pending）或 `launch_prefetch_lookup`（LOOKUP hit + last_bank + 空闲）|
| `set_prefetch_pending` | LOOKUP hit + last_bank + cached + !prefetch + !accept |

### 4.5 RAM 控制

| 信号 | 说明 |
|------|------|
| `ram_read_en` | `accept_new_req \|\| launch_prefetch` |
| `ram_raddr` | launch_prefetch ? next_line_addr.index : (cacop ? cacop_index : cpu_index) |
| `refill_tagv_we` | REFILL last + cached，或 REFILL + cacop_en_r |

---

## 5. 典型时序

### 5.1 LOOKUP 命中（最快路径）

```
Cycle  | IDLE              | LOOKUP
-------|-------------------|-------------------
事件   | cpu_req=1         | tagv_rdata 到齐
       | accept_new_req=1  | cache_inst_hit=1
       | ram_read_en=1     | read_hit_done=1
       | req_buffer 更新    | cpu_data_ok=1
信号   | cpu_addr_ok=1     | cpu_rdata = hit_word
```

### 5.2 LOOKUP miss → REFILL

```
Cycle  | IDLE    | LOOKUP     | WAITRD/REFILL(0) | REFILL(1..3)        | REFILL(last)
-------|---------|------------|------------------|---------------------|-------------------
事件   | accept  | miss       | enter_refill     | return_valid 拍     | return_last
       |         | rd_req     | refill_buffer 快照 | refill_line 拼装     | tagv/bank 写回
       |         |            | rd_addr 发出      |                     | PLRU 更新
信号   | aok=1   |            |                  | read_miss_done=1    |
       |         |            |                  | (所需 bank 到齐)      |
       |         |            |                  | cpu_data_ok=1       |
```

### 5.3 REFILL 提前接受

```
Cycle  | REFILL(0)          | REFILL(1)          | REFILL(last)       | LOOKUP
-------|--------------------|--------------------|--------------------|--------------
事件   | refill_early_accept| tagv_rdata 更新     | tagv/bank 写回      | 统一判定命中
       | accept_new_req=1   | (新请求的 index)    | PLRU 更新           | /缺失
       | ram_read_en=1      |                    | refill_already...=0 |
       | req_buffer 更新     |                    | FSM → LOOKUP       |
       | refill_already...=1|                    |                    |
信号   | cpu_addr_ok=1      |                    |                    | data_ok 产生
```

- 提前接受只做：读 tagv/bank RAM + 更新 req_buffer，**不做**命中/缺失判定、不发 rd_req、不返回 data_ok
- 所有数据交付推迟到 LOOKUP 拍统一处理

### 5.4 预取 LOOKUP 命中 + 新请求匹配

```
Cycle  | LOOKUP (prefetch active)   | LOOKUP
-------|-----------------------------|-------------------
事件   | cpu_req=1, cache_inst_hit=1 | 新请求的 tagv 到齐
       | pf_lookup_accept=1          | 正常判定命中
       | accept_new_req=1            |
       | req_buffer 更新             |
信号   | cpu_addr_ok=1              | data_ok (下一拍)
```

### 5.5 预取 miss → REFILL → CPU 匹配（refill_accept_new_req）

```
Cycle  | ...REFILL...    | REFILL(last)              | IDLE
-------|-----------------|---------------------------|--------------
事件   | return_valid 拍 | return_last               | cpu_data_ok=1
       | refill_line 拼装 | refill_accept_new_req=1   | (来自 req_is_prefetch)
       |                 | req_buffer 更新            | cpu_rdata = req_data
       |                 | (is_prefetch=1, data 锁存)  |
       |                 | tagv/bank 写回             |
       |                 | FSM → IDLE                 |
信号   |                 | cpu_addr_ok=1              |
```

- `addr_ok` 在 `refill_last` 拍，`data_ok` 在下一拍 IDLE
- 预取的前递数据写入 `req_buffer.req_data`，IDLE 下通过 `req_is_prefetch` 从 `req_data` 输出

### 5.6 预取中途被中断（prefetch_can_cancel）

```
Cycle  | LOOKUP/WAITRD (prefetch active)
-------|----------------------------------
事件   | cpu_req=1, prefetch_mismatch=1
       | prefetch_can_cancel=1
       | pf_lookup_accept=1
       | accept_new_req=1
       | req_buffer 更新 (is_prefetch=0)
       | rd_req 被压死 (prefetch_can_cancel)
信号   | cpu_addr_ok=1
```

- 此时预取尚未握手（未进 REFILL），可安全中断
- rd_req 立即变为 0，预取的总线请求被取消

---

## 6. 预取策略

### 6.1 触发条件

| 触发路径 | 条件 |
|----------|------|
| LOOKUP 直接发射 | `main_lookup + cache_inst_hit + last_bank_done + !cpu_req + !cacop_en + !prefetch_active + req_cached` |
| IDLE 延迟发射 | `main_idle + prefetch_pending + !cpu_req + !cacop_en` |

- **只在 offset 落在最后一个 Bank（`offset[3:2]==2'b11`）时触发预取**。因为按顺序取值，只有取到行尾才需要跳到下一行。
- **不在 REFILL 完成时触发预取**。REFILL 完成后自然回到 IDLE，若有 `prefetch_pending` 则由 IDLE 路径发射。

### 6.2 生命周期

```
launch_prefetch
    │
    ▼
LOOKUP (req_is_prefetch=1)
    │
    ├── hit  ──> 数据已在 cache，有 CPU 请求则 accept，无则 → IDLE
    │            (如果 LOOKUP 中 last_bank 满足可再次 launch)
    │
    ├── miss ──> enter_refill (refill_is_prefetch=1)
    │               │
    │               ▼
    │           REFILL
    │               │
    │               ├── CPU 匹配 ──> refill_accept_new_req → IDLE (前递数据)
    │               │
    │               └── 无匹配 ──> refill_last → IDLE
    │
    └── mismatch/cacop in LOOKUP/WAITRD
            │
            ▼
        prefetch_can_cancel → 中断预取，accept 新请求
```

### 6.3 地址计算

```verilog
// LOOKUP 发射: 用 request_buffer 中的 tag/index
next_line_addr_lookup = {req_tag,    req_index,    4'b0} + 16

// IDLE 发射: 用 refill_buffer 中的 tag/index（REFILL 后）
next_line_addr_idle   = {refill_tag, refill_index, 4'b0} + 16
```

---

## 7. 数据通路

### 7.1 数据来源优先级

```
cpu_rdata =
  1. FIFO 非空  → cpu_fifo_mem[cpu_fifo_rptr]   （缓冲数据）
  2. IDLE + req_is_prefetch → req_data          （预取前递）
  3. read_hit_done  → hit_word                   （命中：bank_rdata[hit_way_idx][offset]）
  4. read_miss_done → return_data                 （miss：AXI 返回的当前拍）
  5. 其他          → 0
```

### 7.2 输出 FIFO

- 深度 4，用于解耦数据生产和 CPU 消费
- FIFO 满时 `accept_ok=0`，反压上游
- `accept_ok = (cpu_fifo_cnt < 3)`：保留 2 个空位（当前请求 + 可能的下一请求）
- 当 FIFO 空且数据就绪时，数据直通（bypass FIFO）

---

## 8. PLRU 替换算法

### 8.1 数据结构

2-way 时 PLRU 树只需 1 bit/node × 256 index = 256 bit：
```
plru[index][0] = 0 → way0 是 MRU
plru[index][0] = 1 → way1 是 MRU
```

### 8.2 两阶段时序

```
Accept/Launch 拍:
  组合遍历 PLRU 树 → plru_victim_pre → plru_victim_r (锁存)

LOOKUP 拍:
  tagv_rdata 到齐 → has_invalid/invalid_way 有效
  victim_way = has_invalid ? invalid_way : plru_victim_r
```

### 8.3 更新

- **命中**: `plru_upd_way = hit_way_idx`
- **填充**: `plru_upd_way = refill_replace_way`
- **时机**: LOOKUP hit 时即刻更新；REFILL last 时延迟更新

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
    → req_buffer 锁存 cacop 上下文
    → LOOKUP (读 tagv)
    → 直接进 REFILL（无总线事务）
    → REFILL 中 cacop_en_r 触发 tagv 写
    → 写完后 cacop_en_r←0，FSM → IDLE
```

- CACOP 的 `victim_way`：code=10(hit) 用 `hit_way_idx`，否则用 `cacop_way_r`
- CACOP 不产生 `cpu_data_ok`（`cache_inst_hit = (|way_hit) && !cacop_en_r`）
- CACOP REFILL 不接受提前 accept

---

## 10. AXI 读接口

| 信号 | 说明 |
|------|------|
| `rd_req` | LOOKUP miss 或 WAITRD，且 `!prefetch_can_cancel` 且 `!cacop_en_r` |
| `rd_type` | cached→`3'b100`（cache line 读），uncached→`3'b010`（单字读） |
| `rd_addr` | cached: `{req_tag, req_index, 4'b0}`；uncached: `{req_tag, req_index, req_offset}` |
| `rd_rdy` | AXI 总线就绪 |
| `return_valid/return_last/return_data` | AXI 读返回通道 |

---

## 11. uncached 访问

- `req_cached = 0` 时：
  - `way_hit` 强制为 0（因 `req_cached || cacop_en_r` 为 0）
  - `cache_inst_hit = 0`（必然 miss）+ `!cacop_en_r`
  - LOOKUP 必然进入 WAITRD → REFILL
  - REFILL 中不写 tagv（`refill_cached=0`）
  - `read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
  - AXI `rd_addr` 使用 offset 精确地址
- uncached REFILL 不退化为 LOOKUP，直接回 IDLE

---

## 12. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer 中的信号 |
| `refill_*` | Refill Buffer 中的信号 |
| `cpu_*` | CPU 接口信号 |
| `cacop_*` | CACOP 接口/上下文信号 |
| `pf_*` | 预取相关 |
| `plru_*` | PLRU 替换算法相关 |
| `perf_*` | 性能计数器 |

### 关键组合信号

| 信号 | 推导 |
|------|------|
| `prefetch_active` | `req_is_prefetch \|\| refill_is_prefetch` |
| `accept_new_req` | `(idle \| hit \| pf_lookup \| refill_early)_accept && accept_ok` |
| `ram_read_en` | `accept_new_req \|\| launch_prefetch` |
| `enter_refill` | `(LOOKUP + cacop) \| (LOOKUP + miss + rd_rdy) \| (WAITRD + rd_rdy)` |
| `refill_last` | `main_refill && return_valid && return_last` |
