# Cache 模块设计文档

> 自动生成于 2026-07-16，覆盖 `cache.v` 全部设计细节。新会话读完本文即可以理解 cache。

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
- tagv RAM = WAY_NUM 块，每块 2^INDEX_WIDTH × (TAG_WIDTH+1) bit = 256 × 21 = 5376 bit
- bank RAM = WAY_NUM × 4 bank，每 bank 256 × 32 bit = 8192 bit，总计 8 × 8192 = 64Kb = 8KB
- PLRU = INDEX_DEPTH × (WAY_NUM-1) bit = 256 × 1 = 256 bit（2 路时等价 1-bit LRU）
- `IS_ICACHE` = 1 开启指令预取，= 0 为数据 cache

---

## 2. RAM 架构

```
每路包含：
  ┌─ sp_ram: TagV    (TAG_WIDTH+1 bit × 256)   ← 同步 BRAM，tag + valid
  ├─ sp_ram: Bank 0  (32 bit × 256)            ← 同步 BRAM，word 0
  ├─ sp_ram: Bank 1  (32 bit × 256)            ← 同步 BRAM，word 1
  ├─ sp_ram: Bank 2  (32 bit × 256)            ← 同步 BRAM，word 2
  ├─ sp_ram: Bank 3  (32 bit × 256)            ← 同步 BRAM，word 3
  └─ reg:    D bit   (1 bit × 256)             ← 分布式寄存器，脏标志
```

**4 bank 独立访问**：单拍可读/写任意一个 32-bit word，不需要 4 拍读整行。

**所有 RAM 均为单端口同步**：同一周期要么读要么写。逻辑上保证读写不冲突（读发生在 IDLE/LOOKUP，写发生在 REFILL/WB）。

---

## 3. 状态机

### 3.1 主状态机（main_state）

```
                  ┌─────────────────────────────────┐
                  │                                 │
                  ▼                                 │
  ┌──────┐  accept_new_req    ┌─────────┐          │
  │ IDLE │ ─────────────────► │ LOOKUP  │          │
  └──────┘    launch_         └────┬─────┘          │
       ▲      prefetch_idle       │                 │
       │                          │ hit             │
       │       ┌──────────────────┤ (再接新请求      │
       │       │                  │  或发起预取)     │
       │       ▼ miss             │                 │
       │  ┌──────────┐            │                 │
       │  │clean+rdy?│──yes──────┐│                 │
       │  └────┬─────┘           ││                 │
       │       │ no              │▼                 │
       │       ▼                 │                  │
       │  ┌─────────┐            │                  │
       │  │ REPLACE │            │                  │
       │  └────┬────┘            │                  │
       │       │ rd_rdy          │                  │
       │       ▼                 ▼                  │
       │  ┌─────────┐       (直接 REFILL，省一拍)    │
       │  │ REFILL  │ ◄────────────────────────────┘│
       │  └────┬────┘                               │
       │       │ return_last                        │
       └───────┘ (可继续接新请求 → LOOKUP)           │
                                                    │
  MAIN_MISS 已删除（历史状态，不再使用）              │
```

**各状态含义**：

| 状态 | 编码 | 干什么 |
|------|------|--------|
| IDLE | 0 | 等待 CPU 请求或预取 |
| LOOKUP | 1 | 读 tagv + bank → 比较 tag → 判断 hit/miss → 选数据 |
| REPLACE | 3 | 处理 miss：选牺牲行、发 wr_req（脏行写回）、发 rd_req |
| REFILL | 4 | 逐拍接收 burst 返回数据，最后一拍写入 tagv/bank/dirty |

**关键优化——LOOKUP clean miss 直通 REFILL**：
如果 LOOKUP 发现 clean miss（无脏行需写回）且 bridge 空闲（`rd_rdy=1`），`rd_req` 在 LOOKUP 当拍发出，`main_next` 直接跳到 REFILL，跳过 REPLACE 省一拍。

### 3.2 Write Buffer 状态机（wb_state）

```
  ┌────────┐  store hit LOOKUP   ┌─────────┐
  │ WB_IDLE│ ──────────────────► │ WB_WRITE│
  └────────┘                     └────┬────┘
       ▲                              │
       │     无新 store hit           │
       └──────────────────────────────┘
        (有新 store hit 则留在 WB_WRITE，合并写)
```

WB 只有 2 个状态。store 命中时锁存写操作进 write buffer，下一拍自动写 bank RAM。无需等 store 完成。

### 3.3 状态机中的预取中断处理

预取进行中如果 CPU 发来请求且地址不匹配（预错）或 CACOP 到达：
- **LOOKUP** 阶段 abort：放弃预取，`accept_new_req` 直通新请求的 LOOKUP
- **REPLACE** 阶段 abort：同上（rd_req 尚未发出时）
- **REFILL** 阶段：**不中断 burst**，收完所有 beat。但数据照写不误（不浪费总线带宽）。最后一拍可同时受理新请求

---

## 4. 请求处理流程

### 4.1 Cacheable Load（取指/读数据）

```
T0: IDLE → accept_new_req（锁存 req_*，发 cpu_addr_ok）
T1: LOOKUP（ram_read_en=1，读 tagv + bank）
    │
    ├─ hit:
    │    TagV RAM → way_hit → bank 选字 → hit_word
    │    → read_hit_done → cpu_data_ok → live_rdata → cpu_rdata
    │    → 如有 store hit conflict → hit_write_data 合并后返回
    │    → main_next = IDLE（或接新请求→LOOKUP，或 launch_prefetch_lookup）
    │    命中延迟：1 拍
    │
    └─ miss (clean) + rd_rdy=1:
         rd_req 当拍发出（rd_req_lookup）
         main_next = MAIN_REFILL（跳过 REPLACE，省 1 拍）
         命中延迟：取决于 AXI latency
         
    └─ miss (clean) + rd_rdy=0:
         main_next = MAIN_REPLACE
         等 rd_rdy → REFILL
         
    └─ miss (dirty):
         main_next = MAIN_REPLACE
         先发 wr_req 写回脏行 → 等 wr_rdy
         再发 rd_req → 等 rd_rdy → REFILL

REFILL:
    T0: return_valid → refill_buffer[0] = return_data
    T1: return_valid → refill_buffer[1] = return_data
    T2: return_valid → refill_buffer[2] = return_data
    T3: return_valid && return_last:
        → refill_buffer[3] = return_data
        → TAGV RAM: wen=1111, 写 {req_tag, V=1}
        → Bank RAM: 4 bank 同时写, 数据来自 refill_buffer + 实时 data
        → D RAM: d_ram[way][index] = req_op（读=0，干净）
        → PLRU 更新
        → main_next = IDLE（或接新请求→LOOKUP）
```
**早重启**：`read_miss_done` 在关键字到达当拍即触发（`miss_refill_cnt == req_offset[3:2]`），不必等 `return_last`。关键字到达 T0 时即可返给 CPU，T1/T2/T3 继续收剩余 beat 写 bank。

### 4.2 Cacheable Store

```
T0: IDLE → accept_new_req（锁存 req_*）
T1: LOOKUP（读 tagv + bank）
    │
    ├─ hit:
    │    lookup_store_hit → 锁存进 Write Buffer
    │      wb_way_hit, wb_index, wb_bank, wb_wstrb_mask, wb_wdata
    │    → write_done（当拍完成，store 不占 FIFO）
    │    main_next = IDLE
    │    完成延迟：1 拍
    │
    └─ miss:
         main_next = MAIN_REPLACE
         → 发 rd_req 读整行
         → REFILL 时用 refill_merged_word 合并 store wdata：
           if (miss_refill_cnt == req_offset[3:2])  // store 目标 word
               return_data = (req_wdata & req_wstrb_mask) | (return_data & ~req_wstrb_mask)
           其余 word 直接写 return_data
         → 最后一拍统一写 bank + tagv + D=1（脏）
```

**Store 不写入 L1 的 dirty 行**：store miss 时如果 victim 是脏行，先写回旧脏行到 AXI，再读新行，新行写入后 D bit = `req_op` = 1。

### 4.3 Uncacheable Load

```
T0: IDLE → accept_new_req（req_cached=0）
T1: LOOKUP（读，但 cache_hit = 0 因为 req_cached=0 → way_hit=全0）
    main_next = MAIN_REPLACE
T2-3: REPLACE → rd_req（rd_type=3'b010 字），等 rd_rdy
T4: REFILL → return_valid（单拍，return_last=1）
    数据直接 return_data → cpu_rdata（不写 bank/tagv）
    main_next = IDLE
```

### 4.4 Uncacheable Store

```
T0: IDLE → accept_new_req（req_cached=0, req_op=1）
T1: LOOKUP → main_next = MAIN_REPLACE
T2: REPLACE → wr_req（wr_type=字/半字/字节，wr_data=req_wdata）
    等 wr_rdy → wr_req_accepted
    等 wr_done → main_next = IDLE
    不写任何 bank RAM
```

### 4.5 预取（仅 I-cache, IS_ICACHE=1）

```
触发条件：
  set_prefetch_pending: CPU 取指（is_ifetch）完成且 main_next == IDLE
    ├─ hit:  main_lookup + cache_hit + main_next = IDLE
    └─ miss: main_refill + return_valid + return_last + main_next = IDLE
  → prefetch_pending = 1
  → prefetch_addr = {req_tag, req_index, 4'b0} + 16  (下一行)

触发时机：
  ├─ IDLE:  launch_prefetch_idle  — 空闲时发起挂起的预取
  └─ LOOKUP: launch_prefetch_lookup — 取指 hit 后同拍发起（不经过 IDLE）

预取请求锁存（launch_prefetch）：
  req_op=0, req_index=prefetch_addr的index, req_tag=prefetch_addr的tag
  req_offset=0, req_cached=1, cacop_en_r=0

预取 LOOKUP：
  ├─ hit:  prefetch_active 清除，无后续动作（行已在 cache）
  ├─ miss + CPU mismatch: abort（不上总线）
  └─ miss: 正常 miss 流程 → rd_req → REFILL

预取命中 CPU 请求（prefetch_cpu_match）：
  CPU 请求和预取目标相同 → prefetch_active 清除，数据直接给 CPU

预取失配（prefetch_mismatch）：
  LOOKUP/REPLACE 阶段：abort，不发 rd_req
  REFILL 阶段：数据照写（不浪费总线带宽），写完后可受理新请求

预取对 PLRU 的影响：
  预取 hit 不更新 PLRU（避免预取干扰替换决策）
  预取 refill 写 tagv 时更新 PLRU
```

---

## 5. 替换算法 —— 树状 PLRU

- 每个 set 维护 WAY_NUM-1 个 PLRU bit（2 路时 = 1 bit，即简单 LRU）
- Hit 时：把被访问路的路径置为「远离该路」→ 该路变成 MRU
- Miss 时：**空路优先**（tagv[].V == 0），无空路时选 PLRU victim
- Refill 时：更新 PLRU 把新填入的路标为 MRU
- Prefetch hit 不更新 PLRU，Prefetch refill 才更新

---

## 6. Write Buffer（命中 store 延迟写）

store hit 时不直接写 bank RAM（因为 bank RAM 和 tagv RAM 正在为当前 LOOKUP 读），而是：

```
T0: store 命中 → 锁存进 write buffer（wb_way_hit, wb_index, wb_bank, ...）
T1: wb_state = WB_WRITE → bank RAM 写（wen = wstrb_mask）
T2: wb_state = WB_IDLE（如无新 store→WB_WRITE保持）
```

连续 store 到同一 bank+way+index 时，wb_state 保持在 WB_WRITE，后续 store 的 wb_* 寄存器不断更新，连续写入 bank RAM。

**Hit-write conflict 处理**：
- 同一拍有 load 且和上一拍的 store 写同一 bank → `hit_write_lookup` 检测到
- 读数据 = `(wb_wdata & wb_wstrb_mask) | (bank_rdata & ~wb_wstrb_mask)` —— 把刚写的数据合并进读结果
- `hit_write_lookup_r` 寄存一个周期，在下一拍做合并

---

## 7. 输出 FIFO

4 深 FIFO，缓冲 miss 读结果（hit 结果直接走 live_rdata 旁路）：

```
live_rdata ──┬── cpu_rdata（cpu_fifo_empty 时）
             │
             └── cpu_fifo_mem[0..3]（FIFO 非空时 cpu_rdata 取自 rptr）

cpu_takes_live: cpu_accept && cpu_fifo_empty && read_result_ready
  → 数据不经过 FIFO，直接给 CPU

cpu_fifo_we: read_result_ready && !cpu_takes_live
  → 数据进 FIFO，等 CPU 接受

cpu_fifo_re: cpu_accept && !cpu_fifo_empty
  → CPU 取走 FIFO 队首
```

**accept_ok 逻辑**：读请求需预留 FIFO 空位满足当前+新请求，否则拒绝接受。
- store 请求不占 FIFO，`cpu_op=1` 时 `accept_ok = 1`
- 读请求 `cnt < 3` 或 `cnt == 3 && req_op`（当前是 store 不占位）

---

## 8. CACOP 指令处理

### 8.1 CACOP code 分类

```
cacop_code[4:3]:
  00: 索引全清行（清除整行，含 tag）
  01: 索引清 valid（仅清除 V 位，可含写回脏行）
  10: 命中清 valid（按 PA tag 查询，命中则清 V + 可写回）
  11: 无操作（不写 TagV）
```

### 8.2 CACOP 执行流程

```
T0: IDLE → accept_new_req（cacop_en=1，锁存 cacop_en_r, cacop_code_r 等）
T1: LOOKUP → 读 tagv（cacop_en_r=1，cache_hit=0 但 way_hit 正常判断）
    main_next = MAIN_REPLACE
T2: REPLACE:
    ├─ miss_needs_write=1（脏行需写回）→ 等 wr_req 被 bridge 接受
    └─ miss_needs_write=0 → main_next = MAIN_REFILL
T3: REFILL（return_valid=true 的第一拍）:
    → tagv_do_write: 写 TagV
      ├─ code00: 写全 0（清 tag+V）→ wen=1111
      ├─ code01: 写 byte0=0（清 V）→ wen=0001
      └─ code10: 命中时写 byte0=0 → wen=0001
    → main_next = IDLE
```

### 8.3 CACOP 写回

CACOP code01/10 在清 V 之前，如果目标行 dirty，触发写回（cacop_wb）：
- `cacop_wb_index`（code01）：用 VA index 定位，指定 cacop_way_r
- `cacop_wb_hit`（code10）：查询 tagv 找命中路
- `cacop_dirty`：目标行的 dirty 位（从 d_rdata + tagv_rdata 组合得出）
- 写回地址 = `{tagv_rdata[way][TAG:1], index, 4'b0}`

---

## 9. AXI 总线接口

### 9.1 读请求

`rd_req` 在 **LOOKUP（clean miss 直通）或 REPLACE** 时发出：

| 请求类型 | rd_type | rd_addr | 说明 |
|----------|---------|---------|------|
| cached | 3'b100 (burst 4) | {tag, index, 4'b0} | 16B 整行 burst |
| uncached load | 3'b010 (字) | {tag, index, offset} | 单拍 |
| uncached store | 3'b010/001/000 | {tag, index, offset} | 字/半字/字节 |

`rd_req` 抑制条件：`prefetch_abort_req`（预取失配且未上总线时）。

### 9.2 写请求

`wr_req` 在 **REPLACE** 时发出：

| 请求类型 | wr_type | wr_addr | wr_data | wr_wstrb |
|----------|---------|---------|---------|----------|
| 脏行写回 | 3'b100 | {victim_tag, victim_index, 4'b0} | replace_line_data | 4'b1111 |
| CACOP 写回 | 3'b100 | {target_tag, target_index, 4'b0} | replace_line_data | 4'b1111 |
| uncached store | 字/半字/字节 | {tag, index, offset} | {96'd0, wdata} | wstrb |

`wr_req_accepted` 跟踪写请求是否已被 bridge 握手。同一 REPLACE 序列只发一次写请求。

---

## 10. 关键信号汇总

| 信号 | 方向 | 含义 |
|------|------|------|
| `cpu_req` | in | CPU 请求有效 |
| `cpu_op` | in | 0=load, 1=store |
| `cpu_addr_ok` | out | cache 接受请求 |
| `cpu_data_ok` | out | 读数据就绪 / 写完成 |
| `cpu_rdata` | out | 读数据 |
| `cpu_accept` | in | CPU 取走数据 |
| `cacop_en` | in | CACOP 请求有效 |
| `cacop_rdy` | out | CACOP 请求被接受 |
| `rd_req` | out | AXI 读请求 |
| `rd_rdy` | in | bridge 接受读请求 |
| `wr_req` | out | AXI 写请求 |
| `wr_rdy` | in | bridge 接受写请求 |
| `wr_done` | in | 写操作完成 |
| `return_valid` | in | 返回数据有效 |
| `return_last` | in | burst 最后一拍 |
| `bus_accept` | out | 固定为 1（直通桥） |

---

## 11. 性能计数器

| 计数器 | 含义 | 计数时机 |
|--------|------|----------|
| `perf_total_req` | 总请求数（含 uncache/CACOP） | accept_new_req |
| `perf_access_cnt` | 可缓存查找数（排除预取） | main_lookup + req_cached + !prefetch_active |
| `perf_miss_cnt` | miss 次数（同上范围） | 同上 + !cache_hit |
| `perf_prefetch_launch` | 预取发起总次数 | launch_prefetch |
| `perf_prefetch_abort` | 预取中止（未上总线就被打断） | LOOKUP/REPLACE 阶段的 abort |
| `perf_prefetch_fill` | 预取落盘（REFILL 数据写入 cache） | REFILL last beat |

**关键指标**：
- miss 率 = `perf_miss_cnt / perf_access_cnt`
- 预取成功率 = `perf_prefetch_fill / perf_prefetch_launch`
- 预取中止率 = `perf_prefetch_abort / perf_prefetch_launch`

---

## 12. 设计决策与优化记录

### 12.1 已做优化

| 优化项 | 说明 | 收益 |
|--------|------|------|
| 移除 MAIN_MISS | LOOKUP miss 直通 REPLACE，省 1 拍 | 每个 miss 少 1 拍 |
| LOOKUP clean miss 直通 REFILL | bridge 空闲时 rd_req 在 LOOKUP 当拍发出 | clean miss 再省 1 拍 |
| 早重启 | miss 关键字到达即返 CPU，不等全行 | 减小 miss 有效延迟 |
| 下一行预取 | CPU 取指完成时自动预取 PC+16 下一行 | 减少指令 miss |
| 预取 abort 直通受理 | 预取被打断时直接接受 CPU 新请求，不绕 IDLE | abort 后省 1 拍 |
| REFILL 压写受理 | REFILL 最后拍同时受理新请求 | 无空闲拍的连续 miss 不卡顿 |
| REFILL 不丢预错数据 | 预错时 refill 数据照写 cache（不浪费总线带宽） | 预取数据可能未来命中 |
| Hit-write 合并 | store 命中后 load 同 bank 同一拍合并返回 | 免除 store→load 停顿 |
| 空路优先替换 | 有空路先填空路，避免 PLRU 踢有效行 | 减少不必要的 conflict miss |

### 12.2 状态机精简历史

```
原始:  IDLE → LOOKUP → MISS → REPLACE → REFILL → IDLE
当前:  IDLE → LOOKUP → REFILL  (clean miss 最优)
                    → REPLACE → REFILL  (dirty miss / bridge忙)
MISS 阶段已删除，REPLACE 在 clean miss + bridge 空闲时可被跳过。
```

### 12.3 注意点

- 复位：外部 `aresetn` 低有效，cache 内部 `resetn` 高有效（`resetn = ~aresetn`）
- IS_ICACHE 参数在例化时传入，I-cache 设 1，D-cache 设 0
- TagV/Dirty 写只在 REFILL，读只在 IDLE/LOOKUP，保证单端口 RAM 不冲突
- Prefetch 仅 I-cache 有，D-cache 的 IS_ICACHE=0 时预取逻辑静默
- 预取 PLRU 隔离：prefetch hit 不更新 PLRU，防止预取污染替换决策
- bridge 共享：I/D 共享一个 `cache_axi_bridge`，DCache 读优先级更高
