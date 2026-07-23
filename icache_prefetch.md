# ICache Prefetch 设计文档

## 1. 动机与目标

**问题**：I-Cache 顺序取指时，cache line = 16 字节 = 4 条指令。每 4 条指令跨越一次 cache line 边界，若下一行不在 cache 中，CPU 必须等待 4+ 拍的 REFILL。

**目标**：在 CPU 消费当前 cache line 的末尾 bank 时，自动在后台发起下一行的 REFILL，使 CPU 切换到下一行时直接命中。

**效果**：顺序代码的跨行 miss 惩罚完全被隐藏。1000 条顺序指令中可消除约 250 次 miss 停顿（每次 ≥4 拍），节省约 1000+ 周期。

---

## 2. 新增信号一览

### 2.1 寄存器（3 个）

```verilog
reg         prefetch_pending;   // 延迟发射标志：LOOKUP/REFILL 完成时置位，IDLE 空闲时消费
reg         prefetch_active;    // 预取正在飞行（LOOKUP / WAITRD / REFILL）
reg  [31:0] prefetch_addr;      // 预取目标地址（因 launch_prefetch_lookup 时 req_buffer 会被覆盖）
```

### 2.2 Request/Refill Buffer 扩展字段（2 个）

| 寄存器 | 位宽 | 所属 | 含义 |
|--------|------|------|------|
| `req_is_prefetch` | 1 | Request Buffer | 当前请求是预取（launch_prefetch 或 refill_accept_new_req 时置 1） |
| `refill_is_prefetch` | 1 | Refill Buffer | 当前 REFILL 是预取发起的（enter_refill 时从 req_is_prefetch 快照） |

### 2.3 Request Buffer 额外字段（1 个）

```verilog
reg  [31:0] req_data;   // 预取 REFILL 匹配 CPU 时，前递数据的暂存
```

### 2.4 组合信号（13 个）

| 信号 | 类型 | 公式 |
|------|------|------|
| `prefetch_active` | wire | `req_is_prefetch \|\| refill_is_prefetch` |
| `last_bank_done` | wire | `req_offset[3:2] == 2'b11` |
| `next_line_addr_lookup` | wire | `{req_tag, req_index, {OFFSET_WIDTH{1'b0}}} + 32'd16` |
| `next_line_addr_idle` | wire | `{refill_tag, refill_index, {OFFSET_WIDTH{1'b0}}} + 32'd16` |
| `next_line_addr` | wire | `launch_prefetch_lookup ? next_line_addr_lookup : next_line_addr_idle` |
| `launch_prefetch_idle` | wire | `main_idle && prefetch_pending && !cpu_req && !cacop_en` |
| `launch_prefetch_lookup` | wire | `main_lookup && !prefetch_active && cache_inst_hit && !cpu_req && !cacop_en && last_bank_done && req_cached` |
| `launch_prefetch` | wire | `launch_prefetch_idle \|\| launch_prefetch_lookup` |
| `set_prefetch_pending` | wire | `main_lookup && cache_inst_hit && last_bank_done && req_cached && !prefetch_active && !accept_new_req` |
| `prefetch_cpu_match` | wire | `prefetch_active && cpu_req && cpu_cached && (cpu_tag == XXXX_tag) && (cpu_index == XXXX_index)` — 见 §3.2.4 |
| `prefetch_mismatch` | wire | `prefetch_active && cpu_req && !prefetch_cpu_match` |
| `prefetch_can_cancel` | wire | `prefetch_active && (prefetch_mismatch \|\| cacop_en) && (main_lookup \|\| main_waitrd)` |
| `pf_lookup_accept` | wire | 见 §4.1 |
| `refill_accept_new_req` | wire | `main_refill && refill_last && refill_is_prefetch && prefetch_cpu_match` |

### 2.5 性能计数器（3 个）

```verilog
reg [31:0] perf_prefetch_launch;  // 发射次数
reg [31:0] perf_prefetch_abort;   // 被中断次数
reg [31:0] perf_prefetch_fill;    // 完成 cache line 填充次数
```

---

## 3. 预取生命周期（完整状态机）

```
                         ┌──────────────────────────────────────────┐
                         │                                          │
                         ▼                                          │
┌──────┐  set_pending   ┌──────────┐                               │
│ IDLE │◄────────────────│ PENDING  │ (prefetch_pending=1 内部标志)  │
└──┬───┘                └────┬─────┘                               │
   │                         │                                      │
   │ launch_prefetch_idle    │                                      │
   │ (cpu 空闲)               │                                      │
   ▼                         │                                      │
┌──────────┐                 │                                      │
│  LOOKUP  │◄────────────────┘                                      │
│ (launch) │                                                        │
└────┬─────┘                                                        │
     │                                                              │
     ├── hit ──────────────────────────────────────────┐            │
     │  (CPU 来了就 accept，否则 → IDLE + set_pending)    │            │
     │                                                  ▼            │
     │                                          ┌──────────────┐    │
     ├── miss + rd_rdy ────────────────────────▶│   REFILL     │    │
     │                                          │ (4 拍填充)    │    │
     │                                          └──┬───────────┘    │
     │                                             │                │
     │                                             │ refill_last     │
     │                                             ▼                │
     │                               ┌────────────────────────┐     │
     │                               │  匹配 / 不匹配 分支见    │     │
     │                               │      §3.5              │     │
     │                               └────────┬───────────────┘     │
     │                                        │                      │
     └── miss + !rd_rdy ──────┐              │                      │
                               ▼              ▼                      │
                         ┌──────────┐    ┌──────┐                    │
                         │ WAITRD   │───▶│ IDLE │────────────────────┘
                         └──────────┘    └──────┘
```

### 3.1 阶段 0：set_prefetch_pending — 预定预取

**触发时机**（仅 LOOKUP 命中时）：

```verilog
assign set_prefetch_pending = main_lookup && cache_inst_hit && last_bank_done
                            && req_cached && !prefetch_active
                            && !accept_new_req;
```

- **`last_bank_done`** — 只有在 CPU 取到 cache line 最后一个 bank（offset[3:2]==2'b11）时才触发。原因：顺序取指在当前 line 内一定命中，只有跨行才需要预取。
- **`!accept_new_req`** — 当拍有 CPU 新请求时不置 pending。新请求自己会进 LOOKUP，可能也是 miss，不需要 pending。
- **`!prefetch_active`** — 已有预取在飞行时不重复置位。

**动作**：下一个时钟沿 `prefetch_pending <= 1'b1`。

**注意**：`prefetch_pending` 也曾在 REFILL 完成时触发（见历史版本 `main_refill && return_valid && return_last && main_next == MAIN_IDLE`），但当前版本删除了此路径，因为 REFILL 完成后回 IDLE 自然可以发射。

### 3.2 阶段 1：launch_prefetch — 发射预取

两条发射路径，互斥但共享 `launch_prefetch` 汇总信号。

#### 3.2.1 launch_prefetch_idle（延迟发射）

```verilog
assign launch_prefetch_idle = main_idle && prefetch_pending
                            && !cpu_req && !cacop_en;
```

- 状态：IDLE
- 条件：`prefetch_pending` 已置位 + 没有 CPU/CACOP 请求（不能抢占正常的指令请求）
- 时序：IDLE → 下一拍 LOOKUP

**地址来源**：`next_line_addr_idle = {refill_tag, refill_index, 4'b0} + 16`（用 Refill Buffer 的上下文，因为上一次 REFILL 后的 `req_buffer` 可能已过时）

#### 3.2.2 launch_prefetch_lookup（直接发射）

```verilog
assign launch_prefetch_lookup = main_lookup && !prefetch_active
                              && cache_inst_hit && !cpu_req && !cacop_en
                              && last_bank_done && req_cached;
```

- 状态：LOOKUP（当前请求命中）
- 条件：命中 + 到 last bank + 没有后续 CPU 请求 + 没有 cacop + 没有正在飞的预取
- 时序：LOOKUP self-loop（从 LOOKUP 再进 LOOKUP，切换 req_buffer）

**地址来源**：`next_line_addr_lookup = {req_tag, req_index, 4'b0} + 16`（用当前 Request Buffer 的上下文）

#### 3.2.3 launch 拍动作

```verilog
// ram_read_en 包含 launch_prefetch
assign ram_read_en = accept_new_req || launch_prefetch;

// ram_raddr 使用 next_line_addr 的 index 字段
assign ram_raddr = launch_prefetch
                 ? next_line_addr[`OFFSET_WIDTH +: `INDEX_WIDTH]
                 : ram_raddr_req;

// pre_plru_en 也包含 launch_prefetch，预计算 victim way
assign pre_plru_en    = accept_new_req || launch_prefetch;
assign pre_plru_index = launch_prefetch
                      ? next_line_addr[`OFFSET_WIDTH +: `INDEX_WIDTH]
                      : ram_raddr_req;

// Request Buffer 更新
else if (launch_prefetch) begin
    req_index        <= next_line_addr[`OFFSET_WIDTH +: `INDEX_WIDTH];
    req_tag          <= next_line_addr[`INDEX_WIDTH + `OFFSET_WIDTH +: `TAG_WIDTH];
    req_offset       <= 4'b0;
    req_cached       <= 1'b1;
    req_is_prefetch  <= 1'b1;    // ← 标记为预取
    cacop_en_r       <= 1'b0;
    // ... 其他字段清零
end
```

关键点：
- **`req_offset <= 4'b0`** — 预取从 cache line 第一个 bank 开始（取整行）
- **`req_is_prefetch <= 1'b1`** — 标记此请求为预取，后续所有阻塞逻辑依赖于此
- **PLRU 也预计算** — 为可能的 miss 准备好替换路号

#### 3.2.4 next_line_addr 的二选一

```verilog
wire [31:0] next_line_addr;
assign next_line_addr = launch_prefetch_lookup ? next_line_addr_lookup
                                              : next_line_addr_idle;
```

| 路径 | 地址源 | Tag 来源 | Index 来源 |
|------|--------|----------|------------|
| `launch_prefetch_lookup` | `next_line_addr_lookup` | `req_tag` | `req_index` |
| `launch_prefetch_idle` | `next_line_addr_idle` | `refill_tag` | `refill_index` |

**为什么 IDLE 路径用 refill_buffer？** 因为 IDLE 发射通常发生在 REFILL 刚完成之后——此时 `req_buffer` 有可能被 `accept_new_req` 覆盖（或已经过期），而 `refill_buffer` 在整个 REFILL 期间不变，保存的是刚被填充的那一行的 tag/index。`{refill_tag, refill_index} + 16` 恰好就是下一行的起始地址。

---

### 3.3 阶段 2：LOOKUP — 预取在 LOOKUP

预取进入 LOOKUP 后，行为与普通请求几乎相同：
- **命中（hit）** → 数据已在 cache 中，无需任何总线操作
  - 如果此时 CPU 来了请求：
    - 匹配预取 → `pf_lookup_accept`，req_buffer 更新为 CPU 请求，预取自然结束
    - 不匹配 / cacop → `prefetch_can_cancel`，中断预取
  - 如果没 CPU 请求且满足 `launch_prefetch_lookup` 条件 → 可以立即发射下一个预取
  - 否则 → 回到 IDLE（`set_prefetch_pending` 可选）
- **缺失（miss）** → 进入 WAITRD 或 REFILL

**关键差异**：预取命中时：
- **不产生 `cpu_data_ok`**（`read_hit_done` 被 `!prefetch_active` 阻塞）
- **不更新 PLRU**（`plru_upd_en` 被 `!prefetch_active` 阻塞）

### 3.4 阶段 3：WAITRD — 预取在 WAITRD

预取 miss 但总线未就绪时进入 WAITRD：

```verilog
MAIN_WAITRD: begin
    if (prefetch_can_cancel)
        main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
    else if (rd_rdy)
        main_next = MAIN_REFILL;
    else
        main_next = MAIN_WAITRD;
end
```

- `prefetch_can_cancel` 在此阶段仍然有效：CPU 的新请求可以在 WAITRD 期间中断预取
- `rd_req` 在 WAITRD 时持续为 1（没有 `prefetch_can_cancel` 时可以发出总线请求）

### 3.5 阶段 4：REFILL — 预取在 REFILL

预取进入 REFILL 后**不能再被中断**（`prefetch_can_cancel` 不覆盖 REFILL 状态）。REFILL 的 4 拍数据填充完成后，在 `refill_last` 拍有两个分支：

#### 3.5.1 refill_accept_new_req：CPU 匹配预取

```verilog
assign refill_accept_new_req = main_refill && refill_last
                             && refill_is_prefetch
                             && prefetch_cpu_match;
```

**匹配条件**：
```verilog
assign prefetch_cpu_match = prefetch_active && cpu_req && cpu_cached
                          && (cpu_tag == (main_refill ? refill_tag : req_tag))
                          && (cpu_index == (main_refill ? refill_index : req_index));
```

**时序**：

```
Cycle  | REFILL(0..2)       | REFILL(last)           | IDLE
-------|--------------------|------------------------|-----------
事件   | return_valid 拍    | return_last            | cpu_data_ok=1
       | refill_line 拼装    | refill_accept_new_req  | (来自 req_is_prefetch)
       |                    | req_buffer 更新         | cpu_rdata = req_data
       |                    | req_is_prefetch=1       |
       |                    | req_data 锁存前递数据    |
       |                    | tagv/bank 写回          |
       |                    | FSM → IDLE              |
       |                    | cpu_addr_ok=1           |
```

**action**：在 `refill_last` 拍：
1. `req_buffer` 更新为 CPU 请求（`req_is_prefetch=1`）
2. `req_data` 锁存预取数据（从 `refill_line` 或 `return_data` 按 offset 选择）
3. FSM → IDLE

**下一拍 IDLE**：`req_is_prefetch=1` → `live_data_ready=1` → CPU 直接从 `req_data` 取数据

#### 3.5.2 无匹配：预取完成，静默回 IDLE

```verilog
MAIN_REFILL: begin
    if (refill_last || cacop_en_r) begin
        // ...
        else if (refill_is_prefetch)
            main_next = MAIN_IDLE;    // ← 没有任何附加动作
        // ...
    end
end
```

- tagv 和 bank RAM 已正常写回
- FSM → IDLE，不产生 data_ok
- 后续如果有 CPU 请求同一行，自然命中

**清除 req_is_prefetch**：非匹配预取 REFILL 完成时，`req_is_prefetch` 不会自动清除。有两个路径清除：
1. `main_refill && refill_last && req_is_prefetch && !refill_accept_new_req` → `req_is_prefetch <= 1'b0`
2. IDLE 下 `cpu_accept && cpu_fifo_empty && main_idle && req_is_prefetch` → 被 CPU 消费时清除

---

## 4. 与主逻辑的交互点

### 4.1 accept_new_req 扩展

预取引入了 `pf_lookup_accept`：

```verilog
assign pf_lookup_accept = prefetch_active && (main_lookup || main_waitrd)
                        && (cpu_req || cacop_en)
                        && !(prefetch_cpu_match && !cache_inst_hit && !cacop_en);
```

**含义**：预取在 LOOKUP/WAITRD 期间（未握手），CPU 来了新请求时可以"抢占"。有以下分支：

| 条件 | 行为 |
|------|------|
| prefetch_cpu_match + hit | 不属于 pf_lookup_accept；CPU 通过 `hit_accept` 直接命中，预取作废 |
| prefetch_cpu_match + miss | 不中断（`!(匹配 && miss)`=0），让预取继续进 REFILL |
| prefetch_mismatch | 中断预取，accept CPU 请求 |
| cacop_en | 中断预取，accept CACOP |

完整 `accept_new_req`：
```verilog
assign accept_new_req = (idle_accept && accept_ok)        // IDLE
                     || (hit_accept && accept_ok)         // LOOKUP 命中
                     || (pf_lookup_accept && accept_ok)   // 预取被中断
                     || (refill_early_accept && accept_ok);// REFILL 提前
```

### 4.2 数据通路阻塞

预取请求不应该向 CPU 返回数据，通过 `!prefetch_active` 阻塞：

```verilog
assign read_hit_done  = main_lookup && cache_inst_hit && !prefetch_active;
assign read_miss_done = main_refill && return_valid && !prefetch_active
                      && (refill_cnt == refill_offset[3:2] || !refill_cached);
```

**例外 — 预取前递**：`refill_accept_new_req` 后的 IDLE 拍：
```verilog
assign live_data_ready = read_result_ready
                      || (main_idle && req_is_prefetch);   // ← 预取前递出口
```

### 4.3 PLRU 更新阻塞

预取命中不应改变替换策略（预取不是真正的程序行为）：

```verilog
assign plru_upd_en = (main_lookup && cache_inst_hit && !prefetch_active)
                  || refill_tagv_we;
```

但预取 **REFILL** 的 tagv 写回（`refill_tagv_we`）会正常更新 PLRU——因为填充是真实发生的。

### 4.4 hit_accept 阻塞

CPU 和预取同时在 LOOKUP 时，不能走普通 `hit_accept`（因为 `cache_inst_hit` 此时可能来自预取请求，不是 CPU 请求）：

```verilog
assign hit_accept = main_lookup && cache_inst_hit && (cpu_req || cacop_en)
                 && !prefetch_active;
```

`!prefetch_active` 排除了以下场景：预取在 LOOKUP 命中 → `cache_inst_hit=1` → CPU 也恰好 `cpu_req=1` → 此时应走 `pf_lookup_accept`。

### 4.5 rd_req 阻塞

预取在 LOOKUP/WAITRD 被中断时，不应发出总线请求：

```verilog
assign rd_req = (main_lookup && !cache_inst_hit && !prefetch_can_cancel && !cacop_en_r)
              || (main_waitrd && !prefetch_can_cancel);
```

`prefetch_can_cancel=1` 时 `rd_req` 被压死，避免向 AXI 发出无用的读请求。

### 4.6 cpu_addr_ok 扩展

```verilog
assign cpu_addr_ok = (accept_new_req && !cacop_en) || refill_accept_new_req;
```

正常 accept 或预取 REFILL 匹配时都拉高。

---

## 5. 状态机变化

### 5.1 IDLE

```verilog
MAIN_IDLE: begin
    if (accept_new_req || launch_prefetch_idle)
        main_next = MAIN_LOOKUP;
    else
        main_next = MAIN_IDLE;
end
```

**新增** `launch_prefetch_idle` 跳转条件。

### 5.2 LOOKUP

```verilog
MAIN_LOOKUP: begin
    if (prefetch_can_cancel)
        main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
    else if (cacop_en_r)                          // CACOP
        main_next = MAIN_REFILL;
    else if (!cache_inst_hit && rd_rdy)           // miss + 总线就绪
        main_next = MAIN_REFILL;
    else if (!cache_inst_hit)                     // miss + 总线忙
        main_next = MAIN_WAITRD;
    else if (accept_new_req || launch_prefetch_lookup)  // hit + 继续
        main_next = MAIN_LOOKUP;
    else                                          // hit + 空闲
        main_next = MAIN_IDLE;
end
```

**新增** `prefetch_can_cancel` 和 `launch_prefetch_lookup` 两个分支。

### 5.3 WAITRD

```verilog
MAIN_WAITRD: begin
    if (prefetch_can_cancel)
        main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
    else if (rd_rdy)
        main_next = MAIN_REFILL;
    else
        main_next = MAIN_WAITRD;
end
```

**新增** `prefetch_can_cancel` 分支。

### 5.4 REFILL

```verilog
MAIN_REFILL: begin
    if (refill_last || cacop_en_r) begin
        if (cacop_en_r || !refill_cached)
            main_next = MAIN_IDLE;
        else if (refill_is_prefetch)               // ← 预取 REFILL
            main_next = MAIN_IDLE;
        else if (refill_already_accept_new_req)    // ← 普通指令提前 accept
            main_next = MAIN_LOOKUP;
        else
            main_next = MAIN_IDLE;
    end
    else
        main_next = MAIN_REFILL;
end
```

**新增** `refill_is_prefetch` 分支。预取 REFILL 不退化为 LOOKUP（因为不产生 data_ok）。

---

## 6. 时序图

### 6.1 预取 LOOKUP 命中（无 CPU 等待）

```
Cycle  | LOOKUP (req: bank3) | IDLE (pending)      | LOOKUP (prefetch)
-------|---------------------|---------------------|--------------------
条件   | cache_inst_hit=1    | prefetch_pending=1  | launch_prefetch_idle
       | last_bank_done=1    | !cpu_req            |
       | !cpu_req            |                     |
       | !prefetch_active    |                     |
事件   | set_prefetch_pending|                     | ram_read_en=1
       |                     |                     | req_is_prefetch=1
       | FSM → IDLE          | FSM → LOOKUP        |
状态   | prefetch_active=0   | prefetch_active=0   | prefetch_active=1
```

### 6.2 预取 LOOKUP miss → REFILL（CPU 后来匹配）

```
Cycle  | LOOKUP(prefetch) | REFILL 0-2    | REFILL(last)           | IDLE
-------|------------------|---------------|------------------------|-----------
事件   | cache_inst_hit=0 | return_valid  | return_last            | cpu_data_ok=1
       | rd_req=1         | refill_line   | refill_accept_new_req  | (refill 填完后)
       | enter_refill     | 拼装          | req_buffer←CPU         |
       |                  |               | tagv/bank 写回          |
       |                  |               | FSM → IDLE             |
信号   |                  |               | cpu_addr_ok=1          |
CPU    |                  | cpu_req=1     | ← 匹配，等 REFILL       | cpu_rdata 有效
       |                  | (等待)         | 完成                   |
```

### 6.3 预取被不匹配 CPU 中断

```
Cycle  | LOOKUP(prefetch)      | LOOKUP(CPU req)
-------|-----------------------|------------------------
条件   | cache_inst_hit=1      | 新 req_buffer
       | cpu_req=1             |
       | cpu_tag ≠ req_tag     |
事件   | prefetch_mismatch=1   | accept_new_req=1
       | prefetch_can_cancel=1 |
       | pf_lookup_accept=1    |
       | req_buffer 更新为 CPU  |
状态   | prefetch_active → 0   |
```

### 6.4 预取 LOOKUP miss + 总线忙 → WAITRD → 被中断

```
Cycle  | LOOKUP(prefetch)| WAITRD         | IDLE / LOOKUP(CPU req)
-------|-----------------|----------------|------------------------
条件   | cache_inst_hit=0| !rd_rdy        | prefetch_mismatch=1
       | !rd_rdy         | cpu_req=1      |
       |                 | 不匹配          |
事件   | → WAITRD        | prefetch_can_  | accept_new_req=1
       |                 |   cancel=1     | FSM → IDLE(无新req)
       |                 |                |    或 LOOKUP(有)
```

---

## 7. 控制寄存器时序

### 7.1 prefetch_pending

```verilog
always @(posedge clk) begin
    if (~resetn)
        prefetch_pending <= 1'b0;
    // 清除：优先级高于置位
    else if (accept_new_req || launch_prefetch || refill_accept_new_req)
        prefetch_pending <= 1'b0;
    // 置位
    else if (set_prefetch_pending)
        prefetch_pending <= 1'b1;
end
```

**清除优先级最高** — 因为 `set_prefetch_pending` 和 `accept_new_req` 可能在同一 LOOKUP 拍同时成立（命中 + 新 CPU 请求同时来），此时 accept 优先。

**`refill_accept_new_req` 也清除** — 预取 REFILL 匹配到 CPU 请求后，pending 已无意义。

### 7.2 prefetch_active

没有独立寄存器，由 `req_is_prefetch` 和 `refill_is_prefetch` 组合得出：
```verilog
assign prefetch_active = req_is_prefetch || refill_is_prefetch;
```

**生命周期**：
- 置位：`launch_prefetch` 或 `refill_accept_new_req`（写 `req_is_prefetch <= 1`）
- 清除：
  - `accept_new_req` 更新 req_buffer 时 `req_is_prefetch <= 0`
  - `main_refill && refill_last && req_is_prefetch && !refill_accept_new_req` 清除 req_is_prefetch
  - IDLE 下 `cpu_accept` 消费预取前递数据后清除

### 7.3 refill_is_prefetch

```verilog
// enter_refill 时从 req_is_prefetch 快照
if (enter_refill) begin
    refill_is_prefetch <= req_is_prefetch;
    // ...
end
```

在整个 REFILL 期间保持不变，用于：
- `prefetch_active`（组合逻辑）
- `refill_early_accept` 阻塞（预取 REFILL 不接受提前 accept）
- 状态机 REFILL 退出路径（预取 → IDLE，不退化 LOOKUP）

---

## 8. Request Buffer 更新完整流程

```verilog
always @(posedge clk) begin
    if (~resetn) begin
        // 全部清零
    end
    else begin
        // 优先级 1：refill_accept_new_req（预取 REFILL 匹配）
        if (refill_accept_new_req) begin
            req_index        <= cpu_index;
            req_tag          <= cpu_tag;
            req_offset       <= cpu_offset;
            req_cached       <= cpu_cached;
            req_is_prefetch  <= 1'b1;   // ← 仍为预取（前递模式）
            cacop_en_r       <= 1'b0;
            // ...
            req_data         <= {从 refill_line/return_data 选择};  // 前递
        end
        // 优先级 2：accept_new_req
        else if (accept_new_req) begin
            // ... 正常更新，req_is_prefetch <= 0
        end
        // 优先级 3：launch_prefetch
        else if (launch_prefetch) begin
            // ... 地址 = next_line_addr, req_is_prefetch <= 1
        end
        // 优先级 4：CACOP REFILL 退出
        else if (main_refill && cacop_en_r) begin
            cacop_en_r <= 1'b0;
        end
        // 优先级 5：非匹配预取 REFILL 完成
        else if (main_refill && refill_last && req_is_prefetch && !refill_accept_new_req) begin
            req_is_prefetch <= 1'b0;
        end
        // 优先级 6：IDLE 下 CPU 消费预取前递数据
        else if (cpu_accept && cpu_fifo_empty && main_idle && req_is_prefetch) begin
            req_is_prefetch <= 1'b0;
        end
    end
end
```

---

## 9. 信号交互全局视图

```
                    ┌──────────────────────────────────────────────┐
                    │              prefetch_pending                │
                    │  set_prefetch_pending ↑    ↓ 清除            │
                    │  (LOOKUP hit +              (accept/launch/  │
                    │   last_bank)               match)           │
                    └──────────────┬───────────────────────────────┘
                                   │
                    ┌──────────────▼───────────────────────────────┐
                    │            launch_prefetch                   │
                    │  ┌─ launch_prefetch_idle (IDLE)             │
                    │  └─ launch_prefetch_lookup (LOOKUP)         │
                    │         req_is_prefetch <= 1                │
                    └──────────────┬───────────────────────────────┘
                                   │
          ┌────────────────────────┼──────────────────────────┐
          ▼                        ▼                          ▼
    ┌──────────┐           ┌──────────┐              ┌──────────┐
    │  LOOKUP  │           │  WAITRD  │              │  REFILL  │
    │          │           │          │              │          │
    │ prefetch │           │ prefetch │              │ prefetch │
    │ _can_    │           │ _can_    │              │ _is_     │
    │ cancel   │           │ cancel   │              │ prefetch │
    └────┬─────┘           └────┬─────┘              └────┬─────┘
         │                      │                         │
         ▼                      ▼                         ▼
    ┌──────────────────────────────────────────────────────────┐
    │                    数据通路阻塞                          │
    │  read_hit_done  ← !prefetch_active                      │
    │  read_miss_done ← !prefetch_active                      │
    │  plru_upd_en    ← !prefetch_active (只阻塞命中)          │
    │  hit_accept     ← !prefetch_active                      │
    │  rd_req         ← !prefetch_can_cancel                  │
    └──────────────────────────────────────────────────────────┘
```

---

## 10. 实现步骤清单

### Phase 1：寄存器 + 基础信号（约 60 行）

1. `prefetch_pending`、`prefetch_active`、`prefetch_addr` 寄存器
2. `req_is_prefetch`、`refill_is_prefetch`、`req_data` 字段
3. `next_line_addr_lookup`、`next_line_addr_idle`、`next_line_addr` 地址计算
4. `last_bank_done` 组合信号
5. `set_prefetch_pending`、`launch_prefetch_idle/lookup/launch` 发射逻辑
6. 时序控制：`prefetch_pending` 和 `prefetch_addr` 的 always 块
7. `req_is_prefetch` 更新：launch_prefetch / refill_accept_new_req / 清除路径

### Phase 2：匹配 + 中断逻辑（约 40 行）

8. `prefetch_cpu_match`、`prefetch_mismatch`
9. `prefetch_can_cancel`（LOOKUP/WAITRD 可中断）
10. `pf_lookup_accept`（预取中断时 accept CPU）
11. `refill_accept_new_req`（预取 REFILL 匹配 CPU）

### Phase 3：状态机修改（约 20 行）

12. IDLE：添加 `launch_prefetch_idle`
13. LOOKUP：添加 `prefetch_can_cancel` 和 `launch_prefetch_lookup` 分支
14. WAITRD：添加 `prefetch_can_cancel` 分支
15. REFILL：添加 `refill_is_prefetch` 分支

### Phase 4：阻塞逻辑（约 15 行）

16. `ram_read_en`、`ram_raddr`、`pre_plru_en/index` 包含 launch_prefetch
17. `read_hit_done`、`read_miss_done` 添加 `!prefetch_active`
18. `hit_accept` 添加 `!prefetch_active`
19. `plru_upd_en` 添加 `!prefetch_active`（命中路径）
20. `rd_req` 添加 `!prefetch_can_cancel`
21. `cpu_addr_ok` 添加 `|| refill_accept_new_req`
22. `live_data_ready` 添加 IDLE + req_is_prefetch 前递路径
23. `live_rdata` 添加 req_data 路径
24. `cpu_rdata` 添加预取前递

### Phase 5：性能计数器（可选，约 15 行）

25. `perf_prefetch_launch`、`perf_prefetch_abort`、`perf_prefetch_fill`

---

## 11. 与当前精简版 icache.v 的集成注意点

当前 icache.v 已删除所有 prefetch 代码，结构更干净：

- **Request Buffer**：只有 `accept_new_req` 一条更新路径 → 需添加 `launch_prefetch` 和 `refill_accept_new_req` 路径
- **Refill Buffer**：无 `refill_is_prefetch` 字段 → 需添加
- **数据通路**：`live_rdata` 只有 2 路 MUX → 需添加预取前递第三路
- **状态机**：LOOKUP 6 分支、WAITRD 2 分支、REFILL 4 分支 → 各增加 1-2 分支
- **RAM 控制**：`ram_read_en` / `ram_raddr` 单一路径 → 需添加 launch_prefetch 第二路径
- **PLRU 预计算**：`pre_plru_en` / `pre_plru_index` 单一路径 → 同上

---

## 12. 已知取舍

| 取舍 | 理由 |
|------|------|
| `set_prefetch_pending` 只在 LOOKUP hit 时，不在 REFILL 完成时 | REFILL 完成回 IDLE 后，若有 pending 自然由 idle launch 发射 |
| `launch_prefetch_lookup` 不要求 `main_next == MAIN_IDLE` | LOOKUP self-loop 时直接替换 req_buffer，比回 IDLE 再 accept 快 1 拍 |
| `refill_is_prefetch` 时 `refill_early_accept` 不可用 | 预取 REFILL 期间 CPU 请求应走 `refill_accept_new_req`（匹配）或等 REFILL 完成 |
| 预取命中不更新 PLRU | 预取不是程序真实行为，不应影响替换策略 |
| 预取期间不产生 data_ok（除 refill_accept_new_req 前递） | 预取的目标数据不应被 CPU 看到，除非 CPU 正好在请求同一行 |
