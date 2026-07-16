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
