# 时序分析工具使用指南

基于 Yosys 开源综合工具 + Nangate45 45nm 标准单元库的 CPU 时序分析流程。

## 前置条件

```bash
sudo apt install yosys opensta   # Yosys >= 0.9, OpenSTA >= 2.0
```

Nangate45 库已下载在 `libs/NangateOpenCellLibrary_typical.lib`。
如需重新下载：`bash download_nangate.sh`

## 快速开始

```bash
cd tool/

# Yosys + OpenSTA 完整流程 → runs/sta_<timestamp>/
bash run_yosys_sta.sh

# Vivado FPGA 时序分析 → runs/vivado_<timestamp>/
# (Windows 双击 run_vivado.bat)
```

每次运行产物保存在独立目录 `runs/<tool>_YYYYMMDD_HHMMSS/`，不会互相覆盖。

## 脚本说明

| 脚本 | 耗时 | 产物 |
|------|------|------|
| `run_yosys_sta.sh` | ~20 分钟 | `runs/sta_<ts>/` (网表 + STA 报告) |
| `run_vivado.bat` | ~3 分钟 | `runs/vivado_<ts>/` (FPGA 时序报告) |
| `quick_timing.ys` | ~3 分钟 | 控制台输出 (快速扫 cell 数) |
| `analyze.ys` | ~10 分钟 | 100+400MHz 双点对比 |
| `nangate_analyze.ys` | ~15 分钟 | Nangate45 映射，面积报告 |
| `nangate_flat.ys` | ~15 分钟 | 打平网表 → `outputs/synth_flat.v` |
| `sta_flat.tcl` | ~5 分钟 | **OpenSTA STA**，生成精确延迟报告 |
| `sta_real.tcl` | ~3 分钟 | 过滤版（排除多周期假路径） |
| `download_nangate.sh` | ~30 秒 | 下载 Nangate45 库 |

## 输出文件

```
tool/
├── reports/
│   ├── sta_setup_filtered.rpt   # ⬅ OpenSTA 真实关键路径（逐级延迟+百分比）
│   ├── sta_setup.rpt            # OpenSTA setup 全量报告
│   ├── sta_hold.rpt             # OpenSTA hold 报告
│   ├── sta_wns.rpt / sta_tns.rpt  # WNS/TNS 汇总
│   ├── nangate_stat_100MHz.txt  # Nangate45 面积报告
│   ├── stat_100MHz.txt          # 通用门 100MHz cell 统计
│   └── stat_400MHz.txt          # 通用门 400MHz cell 统计
├── outputs/
│   ├── synth_flat.v             # 打平门级网表（给 OpenSTA 用）
│   └── synth_nangate.v          # 层次网表
├── libs/
│   └── NangateOpenCellLibrary_typical.lib
└── mycore.sdc                   # SDC 时序约束
```

## cell 增长大 = 组合路径长

比较 `reports/stat_100MHz.txt` 和 `reports/stat_400MHz.txt` 中各模块 cell 数的变化：
- **增幅 > 5%**：ABC 为该模块插入了大量额外逻辑门才能满足更高频率 → 大概率是关键路径所在
- **增幅 < 2%**：该模块组合路径短，轻松满足更紧时序

## 当前结果

OpenSTA STA 已完成，关键发现：
- **WNS: -4.80ns** — ALU 乘法器路径，14.3ns arrival time
- **等效 fmax: ~70MHz** — Nangate45 45nm 工艺
- **主要瓶颈**: `alu_src2` 扇出高达 151，线延迟占 78%

详见 `../doc/时序分析报告.md`。

## Vivado 时序分析

如果你的 Windows 上装了 Vivado（E:\AMDDesignTools\2025.2），可以直接用 Vivado 出更直观的报告：

```bash
# 双击运行 (Windows 资源管理器)
tool\run_vivado.bat

# 或在 WSL 的 cmd 中
cmd.exe /c tool\\run_vivado.bat
```

Vivado 报告比 OpenSTA 多了：
- **时序摘要** (`vivado_timing_summary.rpt`) — 含全局 slack 分布、百分比
- **关键路径** (`vivado_critical_paths.rpt`) — 逐级展开，logic% vs route%
- **高扇出网络** (`vivado_high_fanout.rpt`) — 布线瓶颈
- **GUI** — Vivado 打开综合后的设计可以看到彩色路径直方图

Vivado 用真实 FPGA 延迟数据库（硅实测），OpenSTA 用 ASIC .lib 估算。
两者可以互补验证。

---

# Verilator 仿真脚本

基于 chiplab 仿真环境的一键运行脚本，双击运行，自动完成编译→配置→仿真→结果输出。

## 环境要求

- WSL2 (Ubuntu-22.04)，已安装 `verilator` 和 `make`
- `CHIPLAB_HOME` 环境变量指向 chiplab 根目录
- LoongArch32 交叉编译工具链位于 `$CHIPLAB_HOME/toolchains/`

## 脚本一览

| 脚本 | 用途 | 测试规模 |
|------|------|----------|
| `run_mycpu_func.bat [-v] [-w] [-d]` | func 指令测试（79 点）+ golden trace 比对 | 79 |
| `run_nscscc_func.bat [-v] [-w] [-d]` | NSCSCC 功能测试（58 点） | 58 |
| `run_perf.bat <bench> [-v] [-w] [-d] [-s hex]` | 性能测试（20 个 benchmark + allbench 可选） | 1 |
| `run_cpu_diag.bat [-v] [-w] [-d]` | CPU 诊断测试 | 1 |

## perf 可用 benchmark

```
quick_sort  select_sort  bubble_sort  dhrystone  coremark
stream_copy  bitcount  crc32  sha  stringsearch
inner_product  lookup_table  loop_induction
minmax_sequence  my_memcmp
fireye_A0  fireye_B2  fireye_C0  fireye_D1  fireye_I2
allbench    ← 全部集成，用 -s 拨码开关选择
```

## 开关说明

| 参数 | 作用 |
|------|------|
| `-v` | 逐周期打印 PC、指令、寄存器值 |
| `-w` | 生成 fst 波形到 `tool/simu_trace.fst` |
| `-d` | 启用 difftest |
| `-s <hex>` | 仿真拨码开关输入值（仅 `allbench` 需要） |

### allbench 拨码开关映射

`run_perf.bat allbench -s 0x1c` 等价于拨码开关拨到 `0x1c`。
程序读取 `SWITCH_ADDR & 0x1f` 后取反（`xori 0x1f`）得到 benchmark 编号：

```
0x1f=end    0x1e=bitcount  0x1d=bubble_sort  0x1c=coremark
0x1b=crc32  0x1a=dhrystone 0x19=quick_sort   0x18=select_sort
0x17=sha    0x16=stream_copy  0x15=stringsearch
0x14=fireye_A0  0x13=fireye_B2  0x12=fireye_C0
0x11=fireye_D1  0x10=fireye_I2  0x0f=inner_product
0x0e=lookup_table  0x0d=loop_induction  0x0c=my_memcmp
0x0b=minmax_sequence
```

> 默认 `0xff` → 低 5 位为 `0x1f` → 直接结束（等价于不选任何 benchmark）。
> 单个 benchmark 不用 `-s`，直接 `run_perf.bat coremark` 即可。

## 终止条件

1. **UART `0x00`** — 测试程序写 `st.w zero, UART_ADDR` 标记结束
2. **golden trace 比对失败** — `golden_trace.txt` 存在时自动逐条比对，不一致即退
3. **30s 无进度** — func 用 `num_data` 检测，perf 用 `inst_total` 检测
4. **死循环异常处理 `0x1c000380`** — 命中即退
5. **30 分钟硬超时** — bat 内 `timeout 1800`

## 自定义/复用说明

若要移植到其他环境或 CPU，需修改以下位置：

### 1. 路径变量（每个 bat 开头）

```bat
set WSL_CHIPLAB=/home/xxx/chiplab            ← 你的 chiplab WSL 路径
set WSL_FUNC=.../software/examples/mycpu_func  ← func 测试程序路径
set WSL_PERF=.../software/examples/nscscc_perf ← perf 测试程序路径
```

### 2. 工具链路径（每个 bat 的 wsl 命令中）

```bash
export PATH=/home/xxx/chiplab/toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0/bin:$PATH
```

### 3. WSL 发行版名（每个 `wsl -d` 调用）

```bat
wsl -d Ubuntu-22.04 -e bash -c "..."     ← 改为你的发行版名
```

### 4. 仿真超时

bat 第 4 步中 `timeout 1800` → 30 分钟，按需调整。testbench 内 30s 卡死检测在 `testbench.cpp` 中。

### 5. 测试结束 PC（`run_mycpu_func.bat`）

```bash
--end-pc 1c000100    ← test_finish 地址，不同链接脚本可能不同
```

### 6. 注册新测试到 configure.sh

`sims/verilator/run_prog/configure.sh` 中新增 case 分支：
```bash
your_test_name)
    RUN_FUNC=y             # func 测试
    # RUN_C=y              # C 程序
    DEAD_CLOCK_EN=y        # 卡死检测
    mkdir -p ./obj/
    mkdir -p ./log/
    ;;
```

### 7. testbench 改动点（`sims/verilator/testbench/`）

| 文件 | 改动内容 |
|------|----------|
| `testbench.cpp` | switch 上拉（FPGA 仿真适配）、golden trace 比对、进度监控、超时检测 |
| `emu.cpp` | UART `0x00` → 测试结束退出 |
| `difftest.h` / `golden_trace.h` | END_PC 修改（避免误触发） |
| `simu_top.v` | 分支预测计数器、perf 计数器引出 |
| `common.h/cpp` + `cpu_tool.cpp` | `--show-pc-info` 运行时开关 |
| `difftest.cpp` | PC trace 运行时开关 |
