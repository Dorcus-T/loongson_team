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

**更新时序**：

```
if (accept_new_req):
    req_index   <= cacop_en ? cacop_index : (launch_prefetch ? prefetch_index : cpu_index)
    req_tag     <= (cacop_en && cacop_is_hit) ? cacop_tag : (launch_prefetch ? prefetch_tag : cpu_tag)
    req_offset  <= launch_prefetch ? prefetch_offset : cpu_offset
    req_cached  <= launch_prefetch ? 1'b1 : cpu_cached
    req_is_prefetch <= launch_prefetch
    cacop_en_r  <= launch_prefetch ? 1'b0 : cacop_en
    ...
```

- `launch_prefetch` 时：index/tag 来自地址加法结果，offset 置 0，cached 置 1，`req_is_prefetch = 1`
- `prefetch_can_cancel` 时：CPU 请求取代预取，`req_is_prefetch = 0`
- `cacop_en` 时：cacop 上下文锁存

### 2.2 Refill Buffer

`main_lookup && !cache_inst_hit`（LOOKUP miss 拍）从 Request Buffer 快照，整个 REFILL 期间不变。比 `enter_refill` 早一拍——若 miss 后先入 WAITRD，Refill Buffer 已在 LOOKUP 拍锁好。

| 寄存器 | 位宽 | 说明 |
|--------|------|------|
| `refill_index` | 8 | 写回 index |
| `refill_tag` | 20 | 写回 tag |
| `refill_offset` | 4 | 原始请求的 offset（用于 `read_miss_done` 判断） |
| `refill_cached` | 1 | 是否 cached |
| `refill_is_prefetch` | 1 | 该 REFILL 是否为预取发起 |
| `refill_was_cacop` | 1 | 该 REFILL 是否为 CACOP 发起 |
| `refill_replace_way` | 1 | 替换目标路号（LOOKUP miss 拍从 `victim_way` 快照） |
| `refill_cnt` | 2 | 已接收数据拍数（0..3） |
| `refill_line[0:3]` | 4×32 | cache line 拼装缓冲区 |

### 2.3 顶层标志

| 标志 | 说明 |
|------|------|
| `refill_already_accept_new_req` | REFILL 期间已提前接受一个 CPU 请求，退出 REFILL 后进 LOOKUP 而非 IDLE |

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
    ┌──────┐  accept/launch   ┌─────────┐  hit+done    │
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
  - `accept_new_req`（idle_accept 或 launch_prefetch_idle）→ LOOKUP
- **RAM 动作**: `ram_read_en = 1`，读 tagv + bank
- **PLRU**: accept 时更新 `plru_victim_r`

#### LOOKUP

- **进入**: 从 IDLE accept/launch，或从 LOOKUP 自循环（连续 accept/hit/cancel）
- **tagv_rdata 有效**: 上一拍的 `ram_read_en` 在该拍产生 rdata
- **分支**（按优先级）:
  1. `cacop_en_r` → REFILL（CACOP 直接进 REFILL 写 tagv）
  2. `prefetch_can_cancel` → LOOKUP 自循环（取消预取，accept CPU 请求）
  3. `!cache_inst_hit && rd_rdy` → REFILL（miss 且总线就绪）
  4. `!cache_inst_hit && !rd_rdy` → WAITRD（miss 但总线未就绪）
  5. `accept_new_req` → LOOKUP 自循环（连续 accept）
  6. 否则 → IDLE
- **data_ok**: `read_hit_done = main_lookup && cache_inst_hit && !req_is_prefetch`，预取命中不产生 data_ok
- **PLRU**: `plru_upd_en = main_lookup && cache_inst_hit && !req_is_prefetch`，预取命中不更新 PLRU

#### WAITRD

- **进入**: LOOKUP miss 但 `rd_rdy = 0`
- **退出**:
  1. `prefetch_can_cancel` → LOOKUP（取消预取，accept CPU）
  2. `rd_rdy` → REFILL
- **RAM 动作**: 无（保持上一拍 rdata）
- **rd_req**: 保持为 1（持续请求总线），除非被 `prefetch_can_cancel` 压下

#### REFILL

- **进入**: `enter_refill`（LOOKUP miss+rd_rdy、LOOKUP cacop、或 WAITRD+rd_rdy）
- **Refill Buffer 快照**: `main_lookup && !cache_inst_hit` 拍（比 enter_refill 早一拍），锁存 `req_*`、`victim_way`、`refill_cnt=0`
- **第 0–3 拍（return_valid）**: `refill_line[refill_cnt] <= return_data`，`refill_cnt++`
- **`read_miss_done`**: `main_refill && return_valid && !refill_is_prefetch && (refill_cnt == refill_offset[3:2] || !refill_cached)`，预取 REFILL 不产生 read_miss_done
- **`refill_last` 拍**:
  - TagV + Bank RAM 写回
  - PLRU 更新（`refill_replace_way` 标 MRU）
- **退出**:
  - CACOP / uncached → IDLE
  - `refill_already_accept_new_req` → LOOKUP（提前 accept 的请求等待判定）
  - 预取 REFILL → IDLE（预取匹配数据已走 FIFO）
  - 否则 → IDLE

---

## 4. 特殊机制一：REFILL 提前取指令

### 4.1 动机

普通 REFILL 期间（2-way × 4 bank，约 4 拍），CPU 空闲等待。如果当前 miss 行就是 CPU 下一拍要取的行，可以提前接受新请求、预读 RAM，REFILL 结束后直接进 LOOKUP 判定，省掉 1 拍。

### 4.2 触发条件

```verilog
assign refill_early_accept = main_refill && !refill_last
                           && !refill_is_prefetch           // 预取 REFILL 不适用
                           && !refill_already_accept_new_req // 只 accept 一次
                           && !cacop_en_r
                           && !cacop_en
                           && cpu_req
                           && req_cached;
```

### 4.3 时序

```
Cycle   | REFILL(0)          | REFILL(1)          | REFILL(last)       | LOOKUP
--------|--------------------|--------------------|--------------------|--------------
事件    | refill_early_accept| tagv_rdata 更新     | tagv/bank 写回      | Tag/Data Bypass
        | accept_new_req = 1 | (新请求的 index)    | refill_already...=0 | 统一判定命中/缺失
        | ram_read_en = 1    |                    | FSM → LOOKUP       |
        | req_buffer 更新     |                    |                    |
        | refill_already...=1|                    |                    |
信号    | cpu_addr_ok = 1    |                    |                    | data_ok 产生
```

- **REFILL 中间拍**：只做 `ram_read_en` + `req_buffer` 更新，不做命中/缺失判定，不返回 `data_ok`
- **REFILL 末拍**：TagV/Bank 正常写回，FSM 进 LOOKUP
- **LOOKUP 拍**：通过 **Tag/Data Bypass** 用 `refill_tag`/`refill_line` 替代过期 RAM 输出，统一做命中/缺失判定

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
- **预取 REFILL 不适用**（由 `!refill_is_prefetch` 排除）
- CACOP REFILL 不适用（`!cacop_en_r` 排除）
- REFILL 末拍不适用（`!refill_last`）

---

## 5. 特殊机制二：预取指（Prefetch）

### 5.1 动机

顺序取指时，每 4 条指令（16 字节）跨越一次 cache line 边界。若下一行不在 cache 中，CPU 必须等待 4+ 拍 REFILL。预取机制在 CPU 取到当前行末尾时，后台发起下一行的查找/填充，使跨行 miss 惩罚被隐藏。

### 5.2 触发条件

```verilog
// IDLE 发射：刚完成 REFILL，CPU 空闲，上一行 offset 在最后一个 bank
assign prefetch_idle   = main_idle && !cpu_req && !cacop_en && !refill_is_prefetch
                       && refill_cached && !refill_was_cacop;
assign launch_prefetch_idle = prefetch_idle && (refill_offset[3:2] == 2'b11);

// LOOKUP 发射：命中 cache，CPU 空闲，当前 offset 在最后一个 bank
assign prefetch_lookup = main_lookup && cache_inst_hit && !cpu_req
                       && !cacop_en && !req_is_prefetch;
assign launch_prefetch_lookup = prefetch_lookup && (req_offset[3:2] == 2'b11);
```

- 只在 offset 落在最后一个 Bank 时触发
- 不允许连续预取（`!req_is_prefetch` / `!refill_is_prefetch` 防止）
- CPU 请求优先级高于预取（`!cpu_req`）
- IDLE 发射额外排除 uncached（`refill_cached`）和 CACOP（`!refill_was_cacop`）

### 5.3 地址计算

```verilog
// LOOKUP 发射: 用 request buffer
prefetch_base_addr = {req_tag, req_index, 4'b0}
// IDLE 发射: 用 refill buffer（REFILL 刚完成，req_buffer 可能已被覆盖）
prefetch_base_addr = {refill_tag, refill_index, 4'b0}
// 下一行地址
prefetch_next_addr = prefetch_base_addr + 32'd16
// 提取新 tag/index，offset 置 0
prefetch_index  = prefetch_next_addr[OFFSET_WIDTH +: INDEX_WIDTH]
prefetch_tag    = prefetch_next_addr[INDEX_WIDTH + OFFSET_WIDTH +: TAG_WIDTH]
prefetch_offset = 0
```

### 5.4 生命周期

```
launch_prefetch
    │  req_is_prefetch <= 1
    ▼
LOOKUP (prefetch)
    │
    ├── 命中 ──> 数据已在 cache，不产生 data_ok
    │            有 CPU 请求 → prefetch_can_cancel 中断
    │            无 CPU 请求 → FSM 回 IDLE
    │
    ├── miss ──> enter_refill (refill_is_prefetch <= 1)
    │               │
    │               ▼
    │           REFILL (4 拍)
    │               │
    │               ├── CPU 请求匹配（return_last 拍）
    │               │     cpu_addr_ok = 1
    │               │     prefetch_match_data_ready = 1 → 数据进 FIFO
    │               │     TagV/Bank 写回，FSM → IDLE
    │               │
    │               ├── CPU 请求不匹配（return_last 拍）
    │               │     cpu_addr_ok = 0，CPU 等 IDLE 后重试
    │               │     TagV/Bank 写回，FSM → IDLE
    │               │
    │               └── REFILL 前三拍：不理 CPU 请求
    │
    └── LOOKUP/WAITRD 中 CPU 来请求
            │
            ▼
        prefetch_can_cancel → 取消预取，accept CPU 请求 → 新 LOOKUP
```

### 5.5 取消逻辑

```verilog
assign prefetch_can_cancel = (main_lookup || main_waitrd) && req_is_prefetch
                           && ((cpu_req && cpu_cached) || cacop_en);
```

- **LOOKUP/WAITRD 期间**：任意 CPU/CACOP 请求立即抢占，预取被取消
- **REFILL 期间**：不可取消（总线已握手），CPU 请求被阻塞
- `accept_new_req` 包含此路径，`req_is_prefetch` 清零

### 5.6 匹配前递

```verilog
assign prefetch_match_after_shake = main_refill && refill_is_prefetch
                                  && (refill_index == cpu_index)
                                  && (refill_tag   == cpu_tag)
                                  && !cacop_en && cpu_req && cpu_cached;

// 数据就绪（并入 FIFO）
assign prefetch_match_data_ready = main_refill && return_valid && return_last
                                 && refill_is_prefetch && prefetch_match_after_shake;
assign prefetch_match_rdata = (cpu_offset[3:2] == refill_cnt) ? return_data
                                                              : refill_line[cpu_offset[3:2]];
```

- 只在 `return_last` 拍产生 `data_ok`
- 数据通过 `live_data_ready → FIFO → cpu_data_ok`，与其他数据源统一

### 5.7 数据阻塞规则

| 信号 | 阻塞条件 | 原因 |
|------|----------|------|
| `read_hit_done` | `!req_is_prefetch` | 预取命中不向 CPU 返回数据 |
| `read_miss_done` | `!refill_is_prefetch` | 预取 REFILL 不触发正常的 miss 数据就绪 |
| `plru_upd_en`（命中） | `!req_is_prefetch` | 预取不是程序真实行为，不更新替换策略 |
| `refill_early_accept` | `!refill_is_prefetch` | 预取 REFILL 不接受提前 accept |
| `rd_req` | `!prefetch_can_cancel` | LOOKUP/WAITRD 中取消时压下总线请求 |

---

## 6. 数据通路

### 6.1 数据来源

```
live_rdata =
  1. read_hit_done              → hit_word          （命中: bank_rdata[hit_way_idx][offset]）
  2. read_miss_done             → return_data       （miss: AXI 返回数据）
  3. prefetch_match_data_ready  → prefetch_match_rdata （预取匹配: refill_line/return_data）
  4. 其他                       → 0
```

所有数据源统一通过 `live_data_ready → FIFO → cpu_data_ok + cpu_rdata`，无旁路。

### 6.2 输出 FIFO

- 深度 4，解耦数据生产和 CPU 消费
- FIFO 满时 `accept_ok = 0`，反压上游
- `accept_ok = (cpu_fifo_cnt < 3)`：保留 2 个空位（当前请求 + 可能的下一请求）
- FIFO 空且数据就绪时，数据直通（bypass FIFO）
- 先 accept 先返回，顺序不乱；IF 阶段冲刷不影响 cache 侧

### 6.3 CPU 接口契约

- 一次 `cpu_addr_ok` 握手 → 一次 `cpu_data_ok` + 对应数据
- `cpu_addr_ok` 来源：
  1. `accept_new_req && !cacop_en`（正常 accept / 预取取消后 accept）
  2. `main_refill && return_last && prefetch_match_after_shake && accept_ok`（预取匹配）

---

## 7. PLRU 替换算法

### 7.1 数据结构

2-way 时 PLRU 树只需 1 bit/组 × 256 组 = 256 bit：

```
plru[index][0] = 0 → way0 是 MRU
plru[index][0] = 1 → way1 是 MRU
```

### 7.2 两阶段时序

- **Accept/Launch 拍**：组合遍历 PLRU 树 → `plru_victim_pre` → `plru_victim_r`（锁存）
- **LOOKUP 拍**：`victim_way = has_invalid ? invalid_way : plru_victim_r`

### 7.3 更新

- **命中**（非预取）: `plru_upd_way = hit_way_idx`
- **填充**: `plru_upd_way = refill_replace_way`
- **预取命中**：不更新（`!req_is_prefetch` 阻塞）

---

## 8. CACOP 处理

### 8.1 操作码

| code[4:3] | 类型 | 说明 |
|-----------|------|------|
| 00 | Index Invalidate | 指定 index 的指定路 V←0 |
| 01 | Index Store Tag | 指定 index 的指定路写入 tag |
| 10 | Hit Invalidate | 命中路 V←0 |
| 11 | — | 预留 |

### 8.2 流程

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
- CACOP REFILL 不接受提前 accept
- CACOP 不触发预取（`prefetch_idle/lookup` 都要求 `!cacop_en`）

---

## 9. AXI 读接口

| 信号 | 说明 |
|------|------|
| `rd_req` | LOOKUP miss 或 WAITRD，且 `!prefetch_can_cancel` 且 `!cacop_en_r` |
| `rd_type` | cached→`3'b100`（cache line 读），uncached→`3'b010`（单字读） |
| `rd_addr` | cached: `{req_tag, req_index, 4'b0}`；uncached: `{req_tag, req_index, req_offset}` |
| `rd_rdy` | AXI 总线就绪 |
| `return_valid/return_last/return_data` | AXI 读返回通道 |

---

## 10. uncached 访问

- `req_cached = 0` 时：
  - `way_hit` 强制为 0（`req_cached || cacop_en_r` 为 0）
  - `cache_inst_hit = 0`（必然 miss）+ `!cacop_en_r`
  - LOOKUP 必然进入 WAITRD → REFILL
  - REFILL 中不写 tagv（`refill_cached = 0`）
  - `read_miss_done` 在 `return_valid` 第一拍即就绪（`|| !refill_cached`）
  - AXI `rd_addr` 使用 offset 精确地址
- uncached REFILL 不退化为 LOOKUP，直接回 IDLE

---

## 11. 性能计数器

| 计数器 | 说明 |
|--------|------|
| `perf_total_req` | 总 accept 次数（含预取 launch 和取消） |
| `perf_access_cnt` | cached 访问进入 LOOKUP 的次数（不含 cacop） |
| `perf_miss_cnt` | cached miss 次数 |
| `perf_real_miss_cnt` | 同上（冗余，与 miss_cnt 一致） |

---

## 12. 信号命名约定

| 前缀 | 含义 |
|------|------|
| `req_*` | Request Buffer 中的信号 |
| `refill_*` | Refill Buffer 中的信号 |
| `cpu_*` | CPU 接口信号 |
| `cacop_*` | CACOP 接口/上下文信号 |
| `prefetch_*` | 预取相关 |
| `plru_*` | PLRU 替换算法相关 |
| `perf_*` | 性能计数器 |

### 关键组合信号速查

| 信号 | 推导 |
|------|------|
| `accept_new_req` | `(idle_accept \| hit_accept \| refill_early_accept \| launch_prefetch \| prefetch_can_cancel) && accept_ok` |
| `ram_read_en` | `accept_new_req` |
| `ram_raddr` | `launch_prefetch ? prefetch_index : (cacop ? cacop_index : cpu_index)` |
| `enter_refill` | `(LOOKUP + cacop) \| (LOOKUP + miss + rd_rdy) \| (WAITRD + rd_rdy)` |
| `refill_last` | `main_refill && return_valid && return_last` |
| `cache_inst_hit` | `(\|way_hit) && !cacop_en_r` |
| `read_result_ready` | `read_hit_done \| read_miss_done \| prefetch_match_data_ready` |
| `cpu_addr_ok` | `(accept_new_req && !cacop_en) \| (REFILL_last + prefetch_match + accept_ok)` |
| `cpu_data_ok` | `live_data_ready \| !cpu_fifo_empty` |
