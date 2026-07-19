# Cache 内部组合路径分析

> 2026-07-18 更新。仅讨论 cache 模块内部组合路径，不涉及 CPU 流水线跨模块路径。
> 底座体系见 `CLAUDE_CACHE.md` §13 和 `CLAUDE_VC.md` §9。

---

## 0. 前置：BRAM 模型

所有 TagV RAM 和 Bank RAM 为单端口同步 BRAM。时钟到输出延迟远大于触发器时钟到 Q 延迟。
任何从 BRAM 输出出发的路径天生比从触发器出发的路径深。

---

## 1. 底座信号总览

LOOKUP 拍所有长路径的根源是六层底座信号（深度汇聚点）：

```
TagV BRAM 输出（晚）
  ├─ 底座A: cache_hit ─── 20位比较 + valid与门 + 多路OR
  ├─ 底座B: victim_way ── 空路优先编码 + PLRU 256:1选择 + 二选一
  │   └─ 二次索引→
  │       ├─ 底座C: victim_dirty ── d_rdata[victim] ∧ tagv_rdata[victim].V
  │       ├─ 底座E: wb_collide   ── 两道时间窗口检测牺牲行数据陈旧
  │       └─ 底座F: vc_fill_conflict ── VC交换写口与WB写口碰撞

VC 触发器（早）
  └─ 底座D: vc_hit ── 24位全地址比较 + vc_valid与门 + VC_DEPTH项OR
```

底座B 是枢纽——它自己从 BRAM 出发算出路号，立刻被 C/E/F 用于二次索引 BRAM 输出。
"BRAM→算路号→再选BRAM输出→再算"的串联是深度根源。

---

## 2. 已完成的优化（不在当前关键路径上）

### 优化1：VC 干净交换写从 LOOKUP 搬至独立 VCFILL 状态

**原问题**：vc_fill_lookup 在 LOOKUP 当拍驱动 10 块 RAM 的写使能/地址/数据引脚。写使能锥上承载了底座 A+B+C+E+F 全部深度，到 BRAM 建立时间窗口极紧。

**修改**：LOOKUP 拍只判断条件（vc_fill_lookup），锁存进 main_next 触发器进入 VCFILL 状态。VCFILL 拍从状态触发器出发执行交换写——全触发器起点，到 BRAM 引脚只需一层选择器加扇出。

**效果**：BRAM→底座B→底座C→BRAM写使能 的串联被寄存器切为两段。干净交换多 1 拍代价可忽略。

### 优化2：cache_hit 到 BRAM 读使能的预裁决

**原问题**：cache_hit（BRAM出发）串上 accept_new_req 的 4 项 AND 才到 ram_read_en。

**修改**：将 accept_ok、!hit_write_wb、main_lookup 等不依赖 BRAM 的条件提前 AND 为 `lookup_accept_cond`（全触发器出发），cache_hit 只需和它过一个与门就到 ram_read_en。预取同理（`lookup_prefetch_cond`）。

**效果**：BRAM 到 BRAM 闭环中，cache_hit 之后的门级数从 4 级降为 1 级。

---

## 3. 当前仍存在的 cache 内部长路径

### 路径甲：PLRU 256:1 大选择器 → victim_way → victim_dirty → 各扇出

这是当前 cache 内部**最深**的纯组合链。

**起点**：PLRU 触发器阵列（256 组）和 TagV BRAM 输出（valid 位）。

**链路**：
```
TagV BRAM 输出（晚）
  → 每路 valid 位 → 优先编码器找最低号无效路
  → invalid_way（1~2 级门）

PLRU 触发器阵列（早出发，但选择器深）
  → req_index 做 256:1 大选择器，选出当前 set 的 PLRU 位
  → 树状遍历（WAY_IDX_W 层移位+选择）→ plru_victim

两者汇合：
  has_invalid ? invalid_way : plru_victim → victim_way

然后立即二次索引：
  victim_way → 索引 d_rdata 寄存器输出 → 拿到脏位
  victim_way → 索引 tagv_rdata BRAM 输出 → 拿到 valid 位
  → AND → victim_dirty
```

**为什么深**：PLRU 256:1 虽然从触发器出发（比 BRAM 早），但大选择器的物理走线和门延迟不可忽略。它和 BRAM 时钟到输出延迟并行消耗 LOOKUP 拍的时间预算。BRAM 数据到后，PLRU 可能还没算完——victim_way 被两者中慢的那个决定。然后还要二次索引 BRAM 输出才得到 victim_dirty。

**victim_dirty 的五处扇出**（全在 LOOKUP 拍）：

| 扇出 | 终点 | 深度 |
|------|------|------|
| miss_needs_write → !miss_needs_write → rd_req_lookup → 出模块 | 路径①跨模块 | 加一层 NOT + AND |
| !victim_dirty → vc_fill_lookup → main_next = VCFILL | 状态 FF | 加一层 NOT + AND |
| victim_dirty → vc_swap_wb_r D 端 | 寄存器 D | 加一层 AND |
| !victim_dirty → vc_fill_conflict → goto_swap → main_next | 状态 FF | 加一层 NOT + AND + OR |
| victim_dirty → miss_needs_write → REPLACE 状态机 | REPLACE 拍用，不走 LOOKUP 链 | — |

**优化方向**：PLRU 预计算。在接受拍（req_index 已知时）提前读 PLRU 并锁存 plru_victim_r，LOOKUP 拍从触发器出发。

---

### 路径乙：BRAM 输出 → cache_hit → accept_new_req → ram_read_en → BRAM 输入

BRAM 到 BRAM 的闭环——从 BRAM 数据输出经组合逻辑回到同组 BRAM 的使能引脚。

**链路**：
```
TagV BRAM 输出
  → 20位比较 + valid与门 + 两路OR → cache_hit
  → AND lookup_accept_cond（已预裁决，全FF出发，一层与门）
  → accept_new_req
  → ram_read_en
  → 扇出到 10 块 BRAM 的 en 引脚
```

**现状**：经优化2后 cache_hit 只过一级 AND 就到 ram_read_en。逻辑深度约 6~7 级门（比较器 ~4 + OR ~1 + AND ~1），通常不构成首要瓶颈。但如果频率进一步推高，BRAM 时钟到输出 + 6 级门 + BRAM 建立时间的闭环可能首先碰壁。

**进一步优化空间**：投机读——不管命中与否先发起读，miss 时丢弃结果。但会与 VCFILL 的 BRAM 输出保存冲突，需要加显式锁存寄存器，代价偏高。

---

### 路径丙：REFILL 末拍扇出

逻辑不深（全触发器出发），但扇出极大。

**链路**：
```
return_last（触发器）
  → 同时扇出到：
    - 4 块 bank RAM（wen/addr/data）
    - 1 块 TagV RAM（写入 tag+valid）
    - d_ram 写（dirty 位）
    - PLRU 更新（标 MRU）
    - VC 插入（写 vc_valid/vc_addr/vc_data + vc_fifo_ptr 自增）
    - refill_d_we / refill_tagv_we / miss_refill_cnt 等控制信号
    - 可能同时受理新请求（压写路径）
```

深度不是问题，但物理扇出负载需要插入缓冲树。通常综合工具能处理。

---

### 路径丁：BRAM 输出 → hit_word → live_rdata → cpu_rdata

数据路径。Bank BRAM 输出经跨路 OR 归约和选字，经少量 MUX 出模块。

**链路**：
```
Bank BRAM 输出（晚）
  → 一热 OR 归约（跨路选同 bank 字）→ hit_word
  → hit_write_data 合并（仅在 hit_write_lookup_r 为真时，且此路径从 FF 出发）
  → lookup_rdata
  → live_rdata（三选一：hit / VC / miss）
  → cpu_fifo_empty ? live_rdata : fifo_mem
  → cpu_rdata → 出模块
```

出模块后进入 CPU 流水线（字节移位→前推→分支→取指），那是体系级路径，不在 cache 内部讨论。

---

## 4. 威胁排名

| 优先级 | 路径 | 本质 | 深度来源 | 松绑方案 | 代价 |
|--------|------|------|---------|---------|------|
| 1 | 甲：PLRU→victim_way→victim_dirty | PLRU 256:1 大选择器 | PLRU 大选择器 + 二次BRAM索引 | PLRU 预计算锁存 | 极小（RAW可忽略） |
| 2 | 乙：BRAM→hit→accept→BRAM | BRAM 到 BRAM 闭环 | BRAM时钟到输出 | 投机读（不推荐）/已优化至极限 | 功耗 |
| 3 | 丙：REFILL末拍扇出 | 扇出大 | 同时写 10+ 处 | 分散写操作 | 一般不必要 |
| 4 | 丁：BRAM→hit_word→rdata | 数据通路 | BRAM时钟到输出 | 体系级问题 | — |

---

## 5. 路径甲 PLRU 预计算方案简述

**核心思路**：把 PLRU 256:1 选择器和树状遍历从 LOOKUP 拍搬到接受拍。
接受拍时 req_index 已知，和 BRAM 地址摆放并行执行，时间空间充裕。

**改动**：
- 新增 `plru_victim_r` 寄存器
- 接受拍：读 PLRU[ram_raddr_req] + 树状遍历 → 锁存
- LOOKUP 拍：`victim_way = has_invalid ? invalid_way : plru_victim_r`
- 同一 set 背靠背访问的 RAW 冒险：PLRU 更新比预读晚一拍，牺牲路可能次优但不破坏正确性

**收益**：砍掉 LOOKUP 拍中整个 256:1 选择器 + 树状遍历的深度。victim_dirty 及其全部扇出间接受益。
