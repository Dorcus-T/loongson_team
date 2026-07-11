# CACOP 指令 TLB miss 时 EX 阶段死锁修复

## 文件

`ex_stage.v`

## 改动

```verilog
// 下游异常/flush 时放行 EX：否则 EX 等 cache 但 cache 请求被阻断 → 死锁
wire ex_flush_pending;
assign ex_flush_pending = |mem_exc || mem_exc_valid || mem_ertn_flush || wb_ertn_flush || wb_exc_valid;

assign ex_ready_go   = is_div_inst ? (div_ready || div_ready_r) || (!ex_valid || |ex_exc[12:3] || mem_ertn_flush || mem_exc_valid || wb_ertn_flush || wb_exc_valid) :
                                    ex_valid && (mem_we || res_from_mem) && !(|mem_exc || ex_rf_valid) ? (dcache_cpu_req && dcache_cpu_addr_ok) || req_already || ex_flush_pending :
                                    ex_valid && cache_en && (cache_code[2:0] == 3'd0) ? (icache_cacop_rdy || cacop_req_already || ex_flush_pending) :
                                    ex_valid && cache_en && (cache_code[2:0] == 3'd1) ? (dcache_cacop_rdy || req_already || ex_flush_pending) : 1'b1;
```

## 信号含义

| 信号 | 触发场景 |
|------|---------|
| `|mem_exc` | 当前 EX 指令自身携带异常（含数据侧 TLB miss/PIL/PIS 等） |
| `mem_exc_valid` | MEM 级存在异常，当前指令将被冲刷 |
| `mem_ertn_flush` | MEM 级 ERTN 冲刷 |
| `wb_ertn_flush` | WB 级 ERTN 冲刷 |
| `wb_exc_valid` | WB 级存在异常，将冲刷流水线 |

## 影响范围

`ex_ready_go` 的**三条等待分支**均已追加 `|| ex_flush_pending`：

| 分支 | 原返回值 | 新返回值 |
|------|---------|---------|
| load / store | `(dcache_cpu_req && dcache_cpu_addr_ok) \|\| req_already` | `... \|\| ex_flush_pending` |
| ICache CACOP | `icache_cacop_rdy \|\| cacop_req_already` | `... \|\| ex_flush_pending` |
| DCache CACOP | `dcache_cacop_rdy \|\| req_already` | `... \|\| ex_flush_pending` |

## 死锁场景（修复前）

```
1. CACOP code[4:3]==2'b10 (hit 模式) 进入 EX
2. MMU 翻译虚地址时 TLB miss → mem_tlb_exc[4]=1
3. cache_en_final = 0  ← 被 !(cacop_hit_mode && |mem_tlb_exc) 阻断
4. cacop_en 到 D-Cache = 0 → accept_new_req = 0 → cpu_addr_ok = 0
5. dcache_cacop_rdy = dcache_cpu_addr_ok = 0
6. req_already = 0 (请求从未发出)
7. ex_ready_go = 0 → EX 永久停顿 → 死锁
```

同时 `mem_exc=0x2000`（TLBR 异常）已生成但永远到不了 WB。

修复后：`ex_flush_pending = |mem_exc = 1` → `ex_ready_go = 1` → 指令推进 → 异常送达 WB。

## 附加修复：`ld_and_str` 包含 CACOP hit 模式

```verilog
assign ld_and_str = {ex_load_op || (cache_en && cache_code[4:3] == 2'b10), mem_we} & {2{ex_valid}};
```

CACOP hit 模式（code[4:3]==2'b10）需要 MMU 翻译地址，`ld_and_str[1]` 为 1 保证 `valid_mem_tlb_exc` 不被门控清零，TLB 异常能正常通过 `mem_exc` 送入流水线。

此改动为项目原有，非本次修改引入。

## 相关分析：`cache_en_final` 的 TLB miss 阻断

```verilog
assign cache_en_final = ... && !(cacop_hit_mode && |mem_tlb_exc) && ...;
```

CACOP hit 模式 + TLB miss 时，`cache_en_final=0` 阻止 CACOP 请求发给 D-Cache。这是正确行为——TLB miss 时无法获得物理 tag，cache 操作无意义。异常通过 `mem_exc` 正常传递。

---

# ICache cpu_fifo 陈旧数据丢弃修复

## 问题

重定向（分支/异常/ertn/rf）时，`inst_dirty` 仅计数 IF+preIF 阶段的 0~2 条陈旧条目，未计入 cache.v 内部 `cpu_fifo`（深度 4）中已缓冲的指令数据。T/O/C/I 异常或 cacop TLB miss 时流水线停顿，cpu_fifo 堆积 2~4 条预取指令，重定向后陈旧数据残留导致取指错乱。

## 文件

`cache.v` `if_stage.v` `mycpu_top.v`

## 设计

### cache.v

新增两个端口：

```verilog
input  wire  flush;            // 重定向时清空 cpu_fifo 指针
output wire  pipeline_active;  // IF 读请求在途标志（排除 cacop）
```

`pipeline_active = (main_state != MAIN_IDLE) && !cacop_en_r` 精确区分三种状态：

| cache 状态 | `pipeline_active` |
|------------|-------------------|
| IDLE | 0 |
| 忙 cacop（`cacop_en_r=1`） | 0 |
| 忙 IF 读（旧请求在途） | 1 |

cpu_fifo 复位逻辑增加 flush：

```verilog
if (~resetn || flush) begin
    cpu_fifo_wptr <= 2'd0;
    cpu_fifo_rptr <= 2'd0;
    cpu_fifo_cnt  <= 3'd0;
end
```

### if_stage.v

二段式时序设计：

```
Cycle N:   redirect_rising=1 → icache_flush 清 cpu_fifo（0~4 条）
           icache_cpu_req=0（不发新请求，避免 flush 误清新数据）
           if_blocked=1（阻塞普通指令，异常指令除外）

Cycle N+1: redirect_r=1 → inst_dirty = pipeline_active（0 或 1）
           if_blocked=1（等 inst_dirty 递减完毕）
```

关键信号：

```verilog
// 边沿检测：仅重定向上升沿为 1（单周期脉冲）
assign redirect_rising = (wb_ertn_flush || exc_no_rf || br_taken || rf_valid) && !redirect_r;

// 阻塞信号：异常指令（|if_exc）不受 redirect_r 阻塞
assign if_blocked = br_taken || exc_no_rf || wb_ertn_flush || rf_valid || fork_r
                  || (redirect_r && !(|if_exc));

// 重定向首周期不发新请求
assign icache_cpu_req = pre_if_valid && !req_already_final && !(pre_if_exc_valid)
                      && !redirect_rising;

// inst_dirty 延迟 1 周期取值
if (redirect_r && (inst_dirty == 2'b0))
    inst_dirty <= {1'b0, icache_pipeline_active};
```

### mycpu_top.v

端口连线：

```verilog
// ICache 实例
.flush            (icache_flush),
.pipeline_active  (icache_pipeline_active),

// DCache 实例
.flush            (1'b0),       // 不因取指重定向冲刷 DCache
.pipeline_active  (),           // DCache 此信号未使用

// if_stage 实例
.icache_flush           (icache_flush),
.icache_pipeline_active (icache_pipeline_active),
```

## 各场景行为

| 场景 | cache 状态 | flush | inst_dirty | 结果 |
|------|-----------|-------|------------|------|
| 正常分支 | IDLE | 清 cpu_fifo | 0 | 新数据直接使用 |
| rf_valid 重取指 | IDLE | 清 cpu_fifo | 0 | 不丢数据 |
| cacop 执行中（IF 阻塞） | 忙 cacop | 清 cpu_fifo | 0（cacop_en_r 屏蔽） | 不丢数据 |
| 旧 IF miss REFILL 中 + 重定向 | 忙 IF 读 | 清 cpu_fifo | 1 | 丢弃在途旧数据 |
| TLB miss / ADEF 异常 | - | 清 cpu_fifo | - | 异常指令直接通过（`\|if_exc` 旁路） |
