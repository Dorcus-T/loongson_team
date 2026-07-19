# TLB 时序优化方案

> 创建: 2026-07-19
> 背景: Vivado `full_20260718_235614` 报告，cpu_clk WNS=1.064ns @ 50MHz
> 关键路径: PRE_MEM → TLB → 异常编码 → FSM → DCache → EX/MUL → 分支预测器 (24 LUT, 18.4ns)

---

## 已完成：展平异常优先级链

**文件**: `mmu.v` | **状态**: ✅ 已实施，待验证

### 问题

`s0_tlb_exc`（IF端口3bit）和 `s1_tlb_exc`（MEM端口5bit）的异常编码采用串行优先级链：

```verilog
// 旧代码 — 5 级 LUT 串联
assign s1_tlb_exc[4] = s1_found == 1'b0 && ...;
assign s1_tlb_exc[3] = plv > s1_plv   && !s1_tlb_exc[4] && ...;  // 依赖 [4]
assign s1_tlb_exc[2] = load  && !s1_v && !s1_tlb_exc[4]
                                      && !s1_tlb_exc[3] && ...;  // 依赖 [4][3]
assign s1_tlb_exc[1] = store && !s1_v && !s1_tlb_exc[4]
                                      && !s1_tlb_exc[3]
                                      && !s1_tlb_exc[2] && ...;  // 依赖 [4][3][2]
assign s1_tlb_exc[0] = store && !s1_d && !s1_tlb_exc[4]
                                      && !s1_tlb_exc[3]
                                      && !s1_tlb_exc[2]
                                      && !s1_tlb_exc[1] && ...;  // 依赖 [4][3][2][1]
```

exc[0] 依赖 exc[1] 依赖 exc[2] 依赖 exc[3] 依赖 exc[4]，形成 5 级 LUT 串联链。在 Vivado 报告中对应段 9–17（6 级 LUT + 走线 = 3.46ns）。

### 修改

所有异常条件改为一拍并行计算，用 MUX 树做优先级选择（2 级 LUT）：

```verilog
// s0 端口（IF, 3bit）
// 优先级: PPF(2) > PIL(1) > PPL(0)
wire s0_exc_ppf = (s0_found == 1'b0);
wire s0_exc_pil = (s0_v == 1'b0);
wire s0_exc_ppl = (plv > s0_plv);

assign s0_tlb_exc = s0_exc_ppf ? 3'b100 :
                    s0_exc_pil ? 3'b010 :
                    s0_exc_ppl ? 3'b001 : 3'b000;

// s1 端口（MEM, 5bit）
// 优先级: PPE(4) > PPL(3) > PIL(2) > PIS(1) > PME(0)
wire exc_ppe = (s1_found == 1'b0) && !tlbsrch_en && !invtlb_en;
wire exc_ppl = (plv > s1_plv)      && !tlbsrch_en && !invtlb_en;
wire exc_pil = load  && !s1_v      && !tlbsrch_en && !invtlb_en;
wire exc_pis = store && !s1_v      && !tlbsrch_en && !invtlb_en;
wire exc_pme = store && !s1_d      && !tlbsrch_en && !invtlb_en;

assign s1_tlb_exc = exc_ppe ? 5'b10000 :
                    exc_ppl ? 5'b01000 :
                    exc_pil ? 5'b00100 :
                    exc_pis ? 5'b00010 :
                    exc_pme ? 5'b00001 : 5'b00000;
```

### 影响

| 指标 | 旧 | 新 |
|------|-----|-----|
| LUT 级数 | 3 (s0) / 5 (s1) | 2 (双方) |
| 功能等价性 | — | ✅ 等效（优先级语义不变） |
| 预估延迟减少 | — | ~1.2ns (3 LUT + 串联走线) |

### 验证

- [ ] iverilog lint 无新增 warning
- [ ] Vivado 综合后确认 s1_tlb_exc 路径 LUT 级数 ≤2
- [ ] difftest 回归通过

---

## 计划中：TLB 输出寄存器

**文件**: `tlb.v`, `mmu.v` | **状态**: ⬜ 计划中

### 目标

在 TLB search port 1（s1）的组合输出和 MMU 异常编码之间插入寄存器，切断当前的组合长链：

```
当前: match1(组合) → s1_found/s1_ppn/s1_plv(组合) → mmu异常编码(组合) → PRE_MEM FSM
改为: match1(组合) → s1_found/s1_ppn/s1_plv → [REG] → mmu异常编码(组合) → PRE_MEM FSM
```

### 修改点

**`tlb.v`** — s1 输出加寄存器：

```verilog
// 新增输出寄存器
reg        s1_found_r;
reg  [4:0] s1_index_r;
reg [19:0] s1_ppn_r;
reg  [5:0] s1_ps_r;
reg  [1:0] s1_plv_r;
reg  [1:0] s1_mat_r;
reg        s1_d_r;
reg        s1_v_r;

always @(posedge clk) begin
    s1_found_r <= |match1;
    s1_index_r <= s1_index_comb;
    s1_ppn_r  <= s1_ppn_comb;
    s1_ps_r   <= s1_ps_comb;
    s1_plv_r  <= s1_plv_comb;
    s1_mat_r  <= s1_mat_comb;
    s1_d_r    <= s1_d_comb;
    s1_v_r    <= s1_v_comb;
end

// 对外信号改为寄存器版本
assign s1_found = s1_found_r;
assign s1_ppn   = s1_ppn_r;
// ... 其余类推
```

原有的组合逻辑 `|term` 输出改名为 `_comb` 内部信号。

**`mmu.v`** — 新增 `mem_tlb_req` 输出端口：

```verilog
// 端口列表新增
output wire mem_tlb_req,   // PRE_MEM 访存需要查 TLB 页表

// 逻辑（在 ex_tlb_exc 赋值后）
// 条件: 页表翻译模式 && DMW 未命中 && 非 TLB 维护指令 && 非 INVTLB
assign mem_tlb_req = (dapg == 2'b01) && (ex_match == 2'b00)
                   && !tlbsrch_en && !invtlb_en;
```

不需要判断 `load`/`store`——非访存指令的 `pre_mem_ready_go = 1'b1`，不会走到 TLB 等待分支。

**`pre_mem_stage.v`** — 新增 `mem_tlb_req` 输入端口 + 握手控制：

新增端口：

```verilog
input wire mem_tlb_req,   // MMU 告知当前指令需要查 TLB
```

TLB 多一拍后，`pre_mem_ready_go` 需要等待 TLB 结果寄存器更新。新增一个 `tlb_wait` 信号（类似现有的 `req_already` 模式）：

```verilog
// 本地组合逻辑
wire need_tlb_lookup = (mem_we || res_from_mem) && !cacop_en && mem_tlb_req;

// 状态寄存器
reg tlb_wait;  // 当前正在等待 TLB 结果

always @(posedge clk) begin
    if (reset || pre_mem_flush_pending)
        tlb_wait <= 1'b0;
    else if (pre_mem_valid && need_tlb_lookup && !tlb_wait)
        tlb_wait <= 1'b1;
    else if (pre_mem_allowin)
        tlb_wait <= 1'b0;
end

// ready_go 加入 TLB 条件
wire tlb_ready = !need_tlb_lookup || !tlb_wait;
assign pre_mem_ready_go = tlb_ready && (原有条件);

// dcache_cpu_req 也必须被 tlb_ready 门控 ——
// 否则 Cycle N 的 dcache_cpu_req 会用上一拍的 padd（TLB 尚未更新），
// DCache 会锁存到错误的物理 tag
wire dcache_cpu_req_raw = pre_mem_valid && (无异常条件) && !req_already
                        && (mem_we || res_from_mem);
assign dcache_cpu_req = dcache_cpu_req_raw && tlb_ready;
// ↑ 仅加了最后一个条件，其余行不变
```

**关键细节：为什么必须门控 `dcache_cpu_req`**

```
当前一拍（无 TLB 寄存）:
  posedge → EX→PRE_MEM 有 va → TLB组合 → padd 有效 → dcache_cpu_tag有效
         → dcache_cpu_req=1 → DCache.accept_new_req → posedge锁存正确tag

TLB 寄存后（不门控 dcache_cpu_req）:
  Cycle N posedge → EX→PRE_MEM 有 va → TLB组合开始 → padd=旧值 ✗
                  → dcache_cpu_req=1 → DCache 锁存错误 tag ✗
  Cycle N+1 posedge → TLB输出寄存器更新 → padd 正确但已来不及

TLB 寄存后（门控 dcache_cpu_req）:
  Cycle N:   tlb_wait=1, tlb_ready=0 → dcache_cpu_req=0, DCache 不理
  Cycle N+1: TLB输出寄存器有效, padd正确, tlb_wait=0, tlb_ready=1
             → dcache_cpu_req=1, dcache_cpu_tag正确 → DCache锁存 ✓
```

**`mycpu_top.v`** — 连接新信号：

```verilog
// 新增 wire 声明（在 mmu 和 pre_mem 信号声明区）
wire mem_tlb_req;          // 发 pre_mem: 是否需要查 TLB

// mmu 实例化新增
.mem_tlb_req    (mem_tlb_req),

// pre_mem_stage 实例化新增（排在 .mem_tlb_exc 附近）
.mem_tlb_req    (mem_tlb_req),
```

### 影响

| 指标 | 旧 | 新 |
|------|-----|-----|
| 访存延迟 | 1 拍 TLB | 2 拍 TLB |
| TLB 段组合延迟 | 5.4ns (当前关键路径的一段) | 0ns (被寄存器切断) |
| CPU 频率潜力 | ~52.8 MHz | ~70+ MHz (受下一个瓶颈限制) |
| IPC 影响 | — | 极小（dcache miss 本就需要多拍，TLB +1 拍被遮盖） |
| 寄存器开销 | — | ~200 FF |

### 风险

- `pre_mem_ready_go` 的 TLB 等待逻辑需要与现有 `req_already`（DCache 握手）、`pre_mem_flush_pending`（死锁预防）协调
- s0 端口（IF 取指）暂不改动——如果 IF TLB 也成瓶颈再单独处理

---

## 计划中：Micro-TLB

**文件**: 新建 `utlb.v` + 修改 `mmu.v`, `pre_mem_stage.v` | **状态**: ⬜ 计划中

### 架构

在 32 项全相联大 TLB 前增加 4 项全相联 micro-TLB：

```
命中路径 (1拍):
  va → μTLB(4项, 组合查找) → hit → 同拍输出 PPN/PLV/MAT → PRE_MEM

未命中路径 (3拍, <5%):
  Cycle N:   μTLB miss → 锁存请求 → stall
  Cycle N+1: 大TLB match1(组合) → 结果写入输出寄存器
  Cycle N+2: 大TLB结果 → PRE_MEM 继续; 同时回填 μTLB
```

### μTLB 结构

```
4 项 × {valid, ps, g, asid[9:0], vppn[18:0], ppn[19:0], plv[1:0], mat[1:0], d, v}
≈ 4 × 60bit = 240 FF
+ LRU 状态 4×3bit = 12 FF
+ 4路比较器 + 4:1 MUX ≈ 30 LUT
```

查找逻辑：

```verilog
// utlb.v — 4路全相联比较
for (i = 0; i < 4; i = i + 1) begin : gen_match
    assign match[i] = (vppn[18:9] == tag_vppn[i][18:9])
                   && (ps[i] || vppn[8:0] == tag_vppn[i][8:0])
                   && ((asid == tag_asid[i]) || g[i])
                   && valid[i];
end

assign hit = |match;

// 4:1 MUX 选命中项
assign ppn  = match[0] ? ppn_entry[0] :
              match[1] ? ppn_entry[1] :
              match[2] ? ppn_entry[2] :
              match[3] ? ppn_entry[3] : 20'd0;
```

### 替换策略

LRU（4项用6bit状态矩阵）：

- 命中时：更新 LRU 状态
- 未命中回填时：选 LRU victim 替换
- INVTLB 时：全部 4 项 valid 清零（不回逐个比较，避免时序路径）

### 与 mmu.v 集成

μTLB 查找结果和全量 TLB 结果来自同一组 `s1_*` 信号，在 `mmu.v` 内部通过 `mem_tlb_req` 走已有路径。`pre_mem_stage.v` 中 `need_tlb_lookup` 不变（已经区分了"访存 + 需页表翻译"和"DMW/无需翻译"）：

```verilog
// mmu.v 内部
utlb u_utlb (
    .vppn    (ex_vppn),
    .asid    (s1_asid),
    .hit     (u_tlb_hit),
    .ppn     (u_tlb_ppn),
    .plv     (u_tlb_plv),
    .mat     (u_tlb_mat),
    .d       (u_tlb_d),
    .v       (u_tlb_v),
    // 写端口
    .we      (big_tlb_hit && tlb_wait_done),
    .w_vppn  (tlb_req_vppn_r),
    .w_ppn   (s1_ppn_r),
    // ...
);

// s1_* 选源：μTLB hit → μTLB结果, μTLB miss → 大TLB结果(已寄存)
assign s1_found_final = u_tlb_hit ? u_tlb_hit : s1_found_r;
assign s1_ppn_final   = u_tlb_hit ? u_tlb_ppn : s1_ppn_r;
// ...
```

### 时序

| 场景 | 延迟 |
|------|------|
| μTLB 命中 | 4路比较(1 LUT) + 4:1 MUX(1 LUT) + 走线 ≈ 1.4ns |
| 大 TLB 未命中 | 32路比较(2 LUT) + OR-reduce(3 LUT) + 32:1 MUX(2 LUT) ≈ 5ns（上下有寄存器） |

### 实现顺序

1. **先做大 TLB 输出寄存**（方案二），验证流水线握手正确
2. **再叠 μTLB**（在方案二稳定后），只需加入选源 MUX 和回填逻辑

---

## 预期总收益

| 阶段 | cpu_clk WNS | 等效 fmax | 说明 |
|------|-------------|-----------|------|
| 当前 | 1.064ns | ~52.8 MHz | `full_20260718_235614` report |
| 展平异常链 | ~2.3ns | ~56.5 MHz | 仅改 mmu.v，已实施 |
| +TLB 输出寄存 | ~7.7ns | ~81 MHz | 切断最大一段组合路径 |
| +Micro-TLB | ~6ns (命中) | ~100+ MHz | 之后瓶颈转移到乘法器/前递 |

---

## 相关文件

| 文件 | 角色 |
|------|------|
| `mmu.v` | 异常编码（已改）+ μTLB 集成点 |
| `tlb.v` | 大 TLB 输出寄存器 |
| `utlb.v` | 微 TLB（待新建） |
| `pre_mem_stage.v` | TLB 等待握手控制 |
| `doc/时序分析报告.md` | Yosys/OpenSTA ASIC 视角 |
| `tool/runs/full_20260718_235614/` | Vivado FPGA 基线数据 |
