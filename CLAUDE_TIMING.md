# Cache 组合逻辑路径分析（实测）

> 2026-07-19，Vivado v2026.1 综合后时序报告。目标器件 xc7k325tffg900-2（-2 速度等级）。
> 综合选项：`-mode out_of_context -flatten_hierarchy none`，保留模块边界。
> 报告使用 `-max_paths 50 -nworst 1`，取每条路径的最差端点。

---

## 1. 顶层汇总

| 路径 | 起点 | 终点 | 延迟 | 级数 | 逻辑延迟 | 预估布线 |
|------|------|------|------|------|----------|----------|
| **DCache 内部** | 标签 BRAM | 体 BRAM 写使能 | **7.070ns** | 13 | 2.695ns | 4.375ns |
| ICache → Bridge | 标签 BRAM | Bridge AR 寄存器 CE | 4.436ns | 8 | 2.484ns | 1.952ns |
| Bridge → DCache | Bridge FF | DCache 体 BRAM 写使能 | 4.626ns | — | 1.680ns | 2.946ns |
| Bridge → ICache | Bridge FF | ICache FIFO 寄存器 CE | 4.504ns | — | 1.649ns | 2.855ns |
| Bridge 内部 | 写追踪器 FF | AR 寄存器 CE | 4.211ns | 14 | 1.551ns | 2.660ns |

> 布线延迟为综合后未布局的估计值，实际布局后通常下降 30%~50%。

---

## 2. DCache 内部关键路径

### 2.1 路径总览

**7.070ns / 13 级逻辑。标签 BRAM → 体 BRAM 写使能的闭环。**

这是整个 cache 模块内部最深的组合链，决定了 LOOKUP 拍的最小时钟周期。

### 2.2 路径逐级结构

```
时钟沿
  ↓
标签 BRAM 阵列读出（1.800ns）
  ↓
21-bit 标签减法比较器，进位链两级（CARRY4 × 2，0.380ns）
  |—— 将 BRAM 读出的标签值与 CPU 请求的标签做逐位相等比较
  ↓
命中路一热解码（LUT4，0.128ns）
  |—— 比较结果译码为"第几路命中"的独热信号，扇出 139 条
  ↓
替换路选择（LUT6，0.043ns）
  |—— 判断被踢出的路是空路还是 PLRU 预计算结果
  ↓
总线写请求条件判定（LUT6，0.043ns）
  |—— 综合缺失类型 + 脏位 + 碰撞检测，决定是否发总线写
  ↓
状态机下一拍计算（LUT6，0.043ns）
  |—— 十条分支的优先编码器，拍板本拍去向
  ↓
VC 有效位更新条件（LUT6，0.043ns）
  |—— 缓存交换时更新受害者缓存的元数据
  ↓
标签存储器写使能（LUT4，0.043ns）
  |—— 决定是否以及如何写标签 BRAM
  ↓
体写条件（LUT2，0.043ns）
  ↓
体写使能汇聚（LUT6，0.043ns）
  ↓
体 BRAM 使能最终多路选择（LUT5，0.043ns）
  ↓
体 BRAM 使能引脚（ENARDEN）
```

### 2.3 路径特征

- **起点和终点均为 BRAM 原语**：BRAM 的时钟→输出延迟（1.800ns）远大于普通寄存器（0.223ns），两头夹击多出约 1.6ns
- **本质是"BRAM 读结果控制 BRAM 写"的闭环**：一条 BRAM 的读出穿过组合逻辑后，决定另一条（或同一条）BRAM 是否被写
- **标签比较（CARRY4 进位链）是路径前半段的核心**：21 位减法比较器跨两级进位
- **FSM 优先编码器是路径中部的瓶颈**：八条优先级分支的串行判定
- **VC 交换逻辑是路径后半段的尾巴**：仅 VC 交换场景触发，但在 LOOKUP 拍和标签比较串行排列

---

## 3. Bridge 内部关键路径

### 3.1 路径总览

**4.211ns / 14 级逻辑。地址冲突检测链。**

### 3.2 路径逐级结构

```
时钟沿
  ↓
写追踪器寄存器 Q 端（0.223ns）
  ↓
32-bit 加法器：待完成写地址 + 写长度 - 1（CARRY4 × 8，0.797ns）
  |—— 计算待完成写事务覆盖的地址范围上界
  ↓
读就绪判定（LUT6 → LUT4 → LUT4，0.214ns）
  |—— 地址冲突检测 OR 状态机空闲 OR FIFO 未满
  ↓
AR 通道使能（LUT4，0.043ns）
  ↓
AR 地址寄存器 CE 引脚
```

### 3.3 路径特征

- **8 级进位链是核心**：`addr_conflict` 函数中的 32 位加法器，每次读请求到达时需与最多 4 个待完成写事务逐一做地址范围重叠检测
- 起点是普通寄存器（FDRE），0.223ns 启动，比 BRAM 快得多
- 4.2ns 在 100MHz（10ns 周期）下裕量充足

---

## 4. 跨模块路径

### 4.1 ICache → Bridge（4.436ns / 8 级）

```
ICache 标签 BRAM 读出（1.800ns）
  ↓
标签比较（CARRY4 × 2，0.380ns）
  ↓
总线读请求生成（LUT6 + LUT2，0.090ns）
  ↓
Bridge 仲裁 + AR 使能（LUT4 × 2，0.086ns）
  ↓
Bridge AR 地址寄存器 CE
```

ICache 的 `rd_req` 路径比 DCache 短，因为无 VC 无 WB，条件少。

### 4.2 Bridge → DCache（4.626ns）

Bridge 内部寄存器（FIFO 读指针/数据）→ DCache 内部的缺失返回数据处理 → 体 BRAM 写使能。起点是普通 FF，路径较短。

### 4.3 Bridge → ICache（4.504ns）

同 Bridge → DCache，更短因为 ICache 无 VC 插入逻辑。

---

## 5. 优化效果验证

### 5.1 方案三（纯代码写法优化）— 无效

| 指标 | 改前 | 改后 | 变化 |
|------|------|------|------|
| DCache 内部 | 7.078ns | 7.070ns | -0.008ns |
| Bridge 内部 | 4.204ns | 4.211ns | +0.007ns |
| 逻辑级数 | 13 / 14 | 13 / 14 | 不变 |

结论：Vivado 综合器对 Verilog 写法不敏感。拆分 wire、重组表达式、更改封装函数等"微调"对最终网表无影响。**要真正缩短路径，必须做架构级改动。**

### 5.2 未采用的架构优化方案

| 方案 | 核心思路 | 预估效果 | 代价 |
|------|---------|----------|------|
| 有效位拆寄存器 | 标签 BRAM 中的 valid 位迁至独立寄存器，接受拍预判 | 7ns → 3~4ns | ~512 FF + 一致性维护 |
| VC 交换延迟一拍 | LOOKUP 拍只读不写，写入挪至下一拍 | 7ns → 4~5ns | VC 命中时多占一拍 |

### 5.3 当前状态

7.070ns / 13 级在 100MHz（10ns 周期）下裕量约 2.9ns。布局后布线延迟通常下降 30%~50%，实际路径延迟预计在 5~6ns 区间。**设计敲定，不再优化。**

---

## 6. 分析脚本

时序分析脚本：`d:/Desktop/timing/run_analysis.tcl`

```tcl
source "d:/Desktop/timing/run_analysis.tcl"
```

报告输出目录：`d:/Desktop/timing/`

| 文件 | 内容 |
|------|------|
| `01_dcache_internal.txt` | DCache 内部寄存器→寄存器路径 |
| `02_icache_internal.txt` | ICache 内部（注意：含管道假路径污染） |
| `03_bridge_internal.txt` | Bridge 内部寄存器→寄存器路径 |
| `04_dcache_to_bridge.txt` | DCache → Bridge（注意：含管道假路径污染） |
| `05_bridge_to_dcache.txt` | Bridge → DCache |
| `06_icache_to_bridge.txt` | ICache → Bridge（干净） |
| `07_bridge_to_icache.txt` | Bridge → ICache |
| `08_logic_levels.txt` | 全局逻辑级数分布 |
| `09_high_fanout.txt` | 全局高扇出信号 |
