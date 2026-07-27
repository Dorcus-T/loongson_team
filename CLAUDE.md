## 项目概览

LoongArch (LA) 5级顺序流水线 CPU
- 流水级：IF → ID → EX → MEM → WB
- 前推网络：EX/MEM/WB → ID 全旁路
- Load-use 停顿、CSR/ERTN 互锁
- AXI3 主接口，通过 sram_axi_bridge 桥接

## 目录结构（扁平项目）

- `mycpu_top.v` — 顶层，例化全部子模块
- `if_stage.v / id_stage.v / ex_stage.v / mem_stage.v / wb_stage.v` — 5级流水
- `alu.v` — 组合逻辑 ALU + 串行除法器
- `mydiv.v` — AXI-Stream 有符号除法器
- `mydivu.v` — AXI-Stream 无符号除法器
- `csr.v` — CSR 寄存器文件（CRMD/PRMD/ERA/DMW/TLB 控制等 ~20 reg）
- `mmu.v / tlb.v` — 虚实地址转换，32项 TLB，2搜索端口
- `regfile.v` — 32×32 通用寄存器堆
- `timer_64bit.v` — 64位周期计数器
- `sram_axi_bridge.v` — 内部 SRAM 协议 → AXI3 转换
- `decoder_*_*.v` — generate 实现译码器
- `mycpu.h` — 总线位宽、CSR 地址、异常编码宏定义

## Cache 架构

icache 和 dcache 均为 2-way 组相联，Vivado BRAM 推断，PLRU 替换。

### MMU 并行化接口

MMU（虚实地址转换）与 cache 并行工作。CPU 请求到达时，cache 先拿到 `cpu_index` / `cpu_offset`，**下一拍** MMU 输出 `mmu_tag` / `mmu_cache` / `mmu_cancel` 到达，此时 cache 进入 LOOKUP 状态做 tag 比较。

| 信号 | 方向 | 说明 |
|------|------|------|
| `mmu_tag` | input | MMU 转换的物理 tag，accept 后 1 拍有效 |
| `mmu_cache` | input | 是否 cached，accept 后 1 拍有效 |
| `mmu_cancel` | input | MMU 异常取消，accept 后 1 拍有效 |
| `mmu_cacop_tag` | input | CACOP 操作的物理 tag |

### MMU Buffer

REFILL 期间提前 accept 新请求时，accept 的下一拍 MMU 输出有效但 cache 仍在 REFILL。MMU Buffer 捕获 `mmu_tag` / `mmu_cache` / `mmu_cancel`，供后续 LOOKUP 使用。

- 捕获条件：`main_refill && refill_already_accept_new_req && !mmu_buf_valid`
- 使用选择：`use_mmu_buf = main_lookup && mmu_buf_valid` → tag/cache/cancel 从 buffer 取
- 清零：进入 LOOKUP 或 IDLE

### icache 特点

- 只读 cache，无写接口
- **无硬件预取**：原预取指（prefetch）机制已移除，REFILL 中允许提前 accept 新请求（`refill_early_accept`）补偿
- 输出 FIFO 深度 4

### dcache 特点

- 读分配 + 写回 + 写分配
- Victim Cache 4 项（仅干净行），可配置开关
- 双状态机：Main FSM（6 状态）+ WB FSM（2 状态）
- 输出 FIFO 深度 4
- `effective_cancel` 最高优先：LOOKUP 拍取消则直接回 IDLE，不触发任何总线事务

## 仿真命令

- 综合工具：Verilator
- lint 工具：iverilog（详见 `.vscode/settings.json`）

## 坑点

- **复位极性**：外部 `aresetn` 低有效，内部 `reset` 高有效
- **TLB 可配置**：条目数由 parameter 控制，当前 32 项
- **SRAM 协议两通道独立**：inst_sram（取指）和 data_sram（访存）各自握手
- **CSR 写后读冒险**：跟踪 CSR 写所在的流水级来解决 RAW
- **MMU-cache 时序**：MMU 输出（tag/cache/cancel）比 cache accept 晚 1 拍到达。cache 内部无 `req_tag`/`req_cached` 寄存器——LOOKUP 拍直接用 `mmu_tag`/`mmu_cache` 端口。REFILL 提前 accept 时由 MMU Buffer 桥接这段时间差
- **`effective_cancel`**：LOOKUP 拍若 MMU 报告取消，cache 直接回 IDLE 不发起任何总线事务。该信号在 icache/dcache 内由 `use_mmu_buf ? mmu_buf_cancel : mmu_cancel` 推导

# Verilog 代码格式规范

## 1. 模块声明

```verilog
module module_name (
    // 分组注释（无=====）
    input  wire [ 3:0] port_name,   // 行内注释（对齐）
    output wire [31:0] port_name2,  // 行内注释（对齐）
    input  wire        port_name3   // 最后一个端口无逗号
);
```

- `module module_name (` 小括号前有空格
- 端口必须显式声明 `wire` 或 `reg`
- 端口列表用 `// 注释` 分组（不带 `==========`）
- 位宽格式：`wire [ 3:0]` — `[` 紧接类型关键字（隔一个空格），括号内 MSB 补到 2 字符（如 `[ 3:0]`、`[31:0]`）
- 无位宽端口：类型关键字后用空格补位，使端口名对齐
- 行内 `//` 注释对齐到一致列
- 最后一个端口不加逗号

## 2. 缩进

- 模块内容用 4 空格缩进
- `always` 块内用 4 空格再缩进

## 3. 区块分隔

- 模块内大区块：`// ============================================================`（60个=）
- 子区块：`// ========== 标题 ==========`

## 4. Always 块

```verilog
always @(posedge clk) begin
    if (reset) begin
        ...
    end
    else if (...) begin
        ...
    end
end
```

- `always @(posedge clk)` 不额外加空格
- `if (` 有空格
- `begin` 与条件同行
- `else` 与 `end` 同行，`else if` 另起

## 5. Assign 语句

```verilog
assign signal = (condition)
              | (condition2);
```

- 多行按逻辑断行，`|`/`||`/`&&` 放在行首对齐
- 操作符两侧留空格：`a & b`，`a == b`
- `~a` 取反不加空格

## 6. 模块实例化

```verilog
    module_name u_inst_name (
        .port_name_long  (signal),
        .port_name_short (signal2),
        .port            (signal3)
    );
```

## 7. 注释

- 端口注释：信息量越少越好，没必要每行都写
- 不改动原有注释文字，只修间距
- `//` 后有空格：`// 注释`（不是 `//注释`）

## 8. Generate

```verilog
generate
    for (i = 0; i < N; i = i + 1) begin : label
        assign out[i] = (in == i);
    end
endgenerate
```

- `for` 内 `=`、`<`、`+` 两侧留空格
- `begin : label` 另起一行
- `end` 和 `endgenerate` 分两行

## 9. 内部信号声明对齐

```verilog
    wire [31:0] signal_a;   // wire = 4字符 + 1空格 = 5字符占位
    reg  [31:0] signal_b;   // reg  = 3字符 + 2空格 = 5字符占位（与wire对齐）
    wire        signal_c;   // 无位宽时同理，信号名对齐到一致列
```

- `wire` 和 `reg` 关键字不等长，通过补空格使**信号名**起始列对齐
- 有/无位宽的信号之间，通过类型关键字后的空格补位，使信号名起始列一致
- **同一组内**上下行的右侧 `//` 注释必须对齐到相同列

## Agent skills

### Issue tracker

GitHub Issues，使用 `gh` CLI 操作。详见 `docs/agents/issue-tracker.md`。

### Triage labels

使用默认标签名：`needs-triage`、`needs-info`、`ready-for-agent`、`ready-for-human`、`wontfix`。详见 `docs/agents/triage-labels.md`。

### Domain docs

单上下文仓库，`CONTEXT.md` + `docs/adr/` 位于仓库根目录。详见 `docs/agents/domain.md`。