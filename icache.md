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

**更新时序**：

```
if (accept_new_req):
    req_index   <= cacop_en ? cacop_index : cpu_index
    cacop_en_r  <= cacop_en
    ...
```

- `cacop_en` 时：cacop 上下文锁存

### 2.2 Refill Buffer

`main_lookup && !cache_inst_hit`（LOOKUP miss 拍）快照，整个 REFILL 期间不变。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_index` | 8 | 写回 index |
| `refill_tag` | 20 | 写回 tag |
| `refill_offset` | 4 | 原始请求的 offset（用于 `read_miss_done` 判断） |
| `refill_cached` | 1 | 是否 cached |
| `refill_replace_way` | 1 | 替换目标路号（LOOKUP miss 拍从 `victim_way` 快照） |
| `refill_cnt` | 2 | 已接收数据拍数（0..3） |
| `refill_line[0:3]` | 4×32 | cache line 拼装缓冲区 |

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
    ┌──────┐  accept   ┌─────────┐  hit+done           │
    │ IDLE │ ────────> │ LOOKUP  │ ───────────────────>│
    └──────┘           └─────────┘                      │
        ▲               │    │                          │
        │       miss+   │    │ miss+                    │
        │       rd_rdy  │    │ !rd_rdy                  │
        │               ▼    ▼                          │
        │          ┌──────────┐                         │
        │          │  REFILL  │◄────┐                   │
        │          └──────────┘     │                   │
        │               │    WAITRD │                   │
        │               │    ┌──────┘                   │
        │          refill_last                          │
        │          or cacop_en_r                        │
        └───────────────────┘
```

### 3.3 各状态详述

#### IDLE

- **进入**: 复位，或无后续请求时
- **退出**: `accept_new_req`（idle_accept）→ LOOKUP
- **RAM 动作**: `ram_read_en = 1`，读 tagv + bank
- **PLRU**: accept 时更新 `plru_victim_r`

#### LOOKUP

- **进入**: 从 IDLE accept，或从 LOOKUP 自循环（连续 accept/hit）
- **tagv_rdata 有效**: 上一拍的 `ram_read_en` 在该拍产生 rdata
- **分支**（按优先级）:
  1. `cacop_en_r` → REFILL（CACOP 直接进 REFILL 写 tagv）
  2. `!cache_inst_hit && rd_rdy` → REFILL（miss 且总线就绪）
  3. `!cache_inst_hit && !rd_rdy` → WAITRD（miss 但总线未就绪）
  4. `accept_new_req` → LOOKUP 自循环（连续 accept）
  5. 否则 → IDLE
- **data_ok**: `read_hit_done = main_lookup && cache_inst_hit`
- **PLRU**: `plru_upd_en = main_lookup && cache_inst_hit`

#### WAITRD

- **进入**: LOOKUP miss 但 `rd_rdy = 0`
- **退出**: `rd_rdy` → REFILL
- **RAM 动作**: 无（保持上一拍 rdata）
- **rd_req**: 保持为 1（持续请求总线）

#### REFILL

- **进入**: LOOKUP miss+rd_rdy、LOOKUP cacop、或 WAITRD+rd_rdy
- **Refill Buffer 快照**: `main_lookup && !cache_inst_hit` 拍，锁存 `req_*`、`victim_way`、`refill_cnt=0`
- **第 0–3 拍（return_valid）**: `refill_line[refill_cnt] <= return_data`，`refill_cnt++`
- **`read_miss_done`**: `main_refill && return_valid && (refill_cnt == refill_offset[3:2] || !refill_cached)`
- **`refill_last` 拍**: TagV + Bank RAM 写回，PLRU 更新（`refill_replace_way` 标 MRU）
- **退出**: refill_last 或 cacop_en_r → IDLE

---

## 4. 数据通路

### 4.1 数据来源

```
live_rdata =
  1. read_hit_done  → hit_word      （命中: bank_rdata[hit_way_idx][offset]）
  2. read_miss_done → return_data   （miss: AXI 返回数据）
  3. 其他           → 0
```

所有数据源统一通过 `live_data_ready → FIFO → cpu_data_ok + cpu_rdata`，无旁路。

### 4.2 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- FIFO 满时 `accept_ok = 0`，反压上游
- `accept_ok = (cpu_fifo_cnt < 3)`：保留 2 个空位（当前请求 + 可能的下一请求）
- FIFO 空且数据就绪时，数据直通（bypass FIFO）
- 先 accept 先返回，顺序不乱；IF 阶段冲刷不影响 cache 侧

### 4.3 CPU 接口契约

- 一次 `cpu_addr_ok` 握手 → 一次 `cpu_data_ok` + 对应数据
- `cpu_addr_ok = accept_new_req && !cacop_en`

---

## 5. PLRU 替换算法

### 5.1 数据结构

2-way 时 PLRU 树只需 1 bit/组 × 256 组 = 256 bit：

```
plru[index][0] = 0 → way0 是 MRU
plru[index][0] = 1 → way1 是 MRU
```

### 5.2 两阶段时序

- **Accept 拍**：组合遍历 PLRU 树 → `plru_victim_pre` → `plru_victim_r`（锁存）
- **LOOKUP 拍**：`victim_way = has_invalid ? invalid_way : plru_victim_r`

### 5.3 更新

- **命中**: `plru_upd_way = hit_way_idx`
- **填充**: `plru_upd_way = refill_replace_way`

---

## 6. CACOP 处理

### 6.1 操作码

| code[4:3] | 类型 | 说明 |
|-----------|------|------|
| 00 | Index Invalidate | 指定 index 的指定路 V←0 |
| 01 | Index Store Tag | 指定 index 的指定路写入 tag |
| 10 | Hit Invalidate | 命中路 V←0 |
| 11 | — | 预留 |

### 6.2 流程

```
accept_new_req (cacop_en=1)
    → req_buffer 锁存 cacop 上下文
    → LOOKUP (读 tagv)
    → 直接进 REFILL（无总线事务）
    → REFILL 中 cacop_en_r 触发 tagv 写
    → 写完后 cacop_en_r ← 0，FSM → IDLE
```

- CACOP 的 `victim_way`：code=10(hit) 用 `hit_way_idx`，否则用 `cacop_way_r`
- CACOP 不产生 `cpu_data_ok`（`cache_inst_hit = (|way_hit) && !cacop_en_r`）
- CACOP 不产生 `cpu_data_ok`（`cache_inst_hit = (|way_hit) && !cacop_en_r`）

---

## 7. AXI 读接口

| 信号 | 说明 |
|------|------|
| `rd_req` | LOOKUP miss 或 WAITRD，且 `!prefetch_can_cancel` 且 `!cacop_en_r` |
| `rd_type` | cached→`3'b100`（cache line 读），uncached→`3'b010`（单字读） |
| `rd_addr` | cached: `{req_tag, req_index, 4'b0}`；uncached: `{req_tag, req_index, req_offset}` |
| `rd_rdy` | AXI 总线就绪 |
| `return_valid/return_last/return_data` | AXI 读返回通道 |

---

## 8. uncached 访问

- `req_cached = 0` 时：
  - `way_hit` 强制为 0（`req_cached || cacop_en_r` 为 0）
  - `cache_inst_hit = 0`（必然 miss）+ `!cacop_en_r`
  - LOOKUP 必然进入 WAITRD → REFILL
  - REFILL 中不写 tagv（`refill_cached = 0`）
  - `read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
  - AXI `rd_addr` 使用 offset 精确地址
- uncached REFILL 不退化为 LOOKUP，直接回 IDLE

---

## 9. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数（含预取 launch 和取消） |
| `perf_access_cnt` | cached 访问进入 LOOKUP 的次数（不含 cacop） |
| `perf_miss_cnt` | cached miss 次数 |
| `perf_real_miss_cnt` | 同上（冗余，与 miss_cnt 一致） |

---

## 10. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer 中的信号 |
| `refill_*` | Refill Buffer 中的信号 |
| `cpu_*` | CPU 接口信号 |
| `cacop_*` | CACOP 接口/上下文信号 |
| `plru_*` | PLRU 替换算法相关 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `(idle_accept \| hit_accept) && accept_ok` |
| `ram_read_en` | `accept_new_req` |
| `ram_raddr` | `cacop ? cacop_index : cpu_index` |
| `refill_last` | `main_refill && return_valid && return_last` |
| `cache_inst_hit` | `(\|way_hit) && !cacop_en_r` |
| `read_result_ready` | `read_hit_done \| read_miss_done` |
| `cpu_addr_ok` | `accept_new_req && !cacop_en` |
| `cpu_data_ok` | `live_data_ready \| !cpu_fifo_empty` |
