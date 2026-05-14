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
- `csr.v` — CSR 寄存器文件（CRMD/PRMD/ERA/DMW/TLB 控制等 ~20 reg）
- `mmu.v / tlb.v` — 虚实地址转换，32项 TLB，2搜索端口
- `regfile.v` — 32×32 通用寄存器堆
- `timer_64bit.v` — 64位周期计数器
- `sram_axi_bridge.v` — 内部 SRAM 协议 → AXI3 转换
- `decoder_*_*.v` — generate 实现译码器
- `mycpu.h` — 总线位宽、CSR 地址、异常编码宏定义

## 仿真命令

- 综合工具：Verilator
- lint 工具：iverilog（详见 `.vscode/settings.json`）

## 坑点

- **复位极性**：外部 `aresetn` 低有效，内部 `reset` 高有效
- **TLB 可配置**：条目数由 parameter 控制，当前 32 项
- **SRAM 协议两通道独立**：inst_sram（取指）和 data_sram（访存）各自握手
- **CSR 写后读冒险**：跟踪 CSR 写所在的流水级来解决 RAW

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
- 位宽格式：`[ 3:0]`（MSB左补到2字符位置）
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