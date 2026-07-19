# Victim Cache (VC) 设计文档

> 2026-07-17 定稿，对应 `cache.v` 内嵌 VC 的最终实现。
> 新会话读完本文即可理解/修改 VC；末章为 L2 cache 的继承指南。
> cache 本体设计见 `CLAUDE_CACHE.md`。

---

## 1. 定位与设计原则

VC 是嵌在 `cache.v` 内部的小型全相联缓冲，接住 L1 被逐出的**干净行**，
在 L1 miss 时以 1 拍延迟（与 L1 hit 相同）救回最近被踢的行。
**仅 D-cache 启用**（`VC_EN` 参数，I 侧取指以顺序流为主、换行震荡少，
`u_icache` 例化时 `VC_EN=0` 整体关断，存储/比较器被综合裁剪）。

三条铁律，全部实现都由此推导：

| 原则 | 内容 | 推论 |
|------|------|------|
| **clean-only** | VC 只存干净行；脏行永远走 AXI 写通道去内存，不进 VC | VC 无脏位、无写回通路；失效=清 valid 位即可；CACOP 零代价 |
| **互斥不变量** | L1 ∩ VC = ∅（同一行绝不同时在两边） | VC 数据永不需要与 writebuffer 合并；VC 无重复项；仿真断言可查 |
| **v1 不衔接** | VC hit 拍不受理新请求 | 该拍 RAM 写口空闲 → 交换写当拍完成，无需独立状态、无交换缓冲寄存器 |

## 2. 参数与存储

```verilog
parameter VC_DEPTH = 4;                    // 条目数，例化可覆盖（cache #(.VC_DEPTH(N))）
parameter VC_EN    = 1;                    // 使能：D-cache=1，u_icache 例化覆盖为 0
localparam VC_IDX_W = $clog2(VC_DEPTH);

reg                  vc_valid [0:VC_DEPTH-1];
reg  [TAG+INDEX-1:0] vc_addr  [0:VC_DEPTH-1];   // {tag, index} 全地址
reg  [127:0]         vc_data  [0:VC_DEPTH-1];   // 整行 16B
reg  [VC_IDX_W-1:0]  vc_fifo_ptr;               // 仅插入路径用；交换是原地回填
```

`VC_EN=0` 关断链：`vc_hit` / `vc_insert` / CACOP 失效三处门控 → 所有 VC 写源
与服务路径失活 → `vc_valid` 恒 0 → 存储、比较器、wen 负载全被综合裁剪。
SWAP 碰撞修复态**不受 VC_EN 影响**（它是脏写回/CACOP 写回的正确性修复；
I 侧无 store，天然不可达）。

- 纯触发器实现（4 项约 600 FF），组合读，独立写口——与 L1 的 sp_ram 端口零冲突
- 全地址匹配（tag+index 都比），所以换入行天然落在 `req_index` 的 set，无需地址换算
- 替换：插入路径 FIFO 指针轮转；交换路径原地回填命中 entry（不动指针）

## 3. 查找与数据通路

```verilog
vc_match[i] = vc_valid[i] && (vc_addr[i] == {req_tag, req_index})   // 组合，LOOKUP 拍出结果
vc_hit      = (|vc_match) && req_cached && !cacop_en_r              // uncached/CACOP 硬门控
vc_serve    = main_lookup && !cache_hit && vc_hit                   // L1 优先
vc_word     = vc_data[vc_hit_idx] 按 req_offset[3:2] 选字
```

- `vc_hit` 必须在 LOOKUP 当拍组合可用——它 gate `rd_req_lookup`（clean-miss 直通优化），
  VC 命中绝不发总线读
- 数据交付复用 hit 通道：`vc_read_done → live_rdata → cpu_rdata`，FIFO 占位规则与 L1 hit 完全一致

## 4. 全场景逐拍时序

### 4.1 L1 hit
VC 全程旁观，一切照旧。

### 4.2 L1 miss + VC hit + victim 干净/空路（交换，当拍完成）

```
T0: accept 拍锁 req_*，一次性读全部 tagv/bank/d
T1: LOOKUP：L1 miss、VC 命中（vc_fill_lookup=1）
    ld → vc_word 给 data_ok；st → write_done，wdata 当拍组合合并进换入行(vc_fill_word)
    写使能/数据当拍铺好，T1→T2 的上跳沿一次写完：
      victim way 4 bank ← 换入行；tagv ← {req_tag,1}；d ← req_op；PLRU 标 MRU
      VC entry ← 干净 victim 回填（{victim_tag, req_index} + 整行）
                 victim 是空路 → 无物可回填，entry 清 valid
    本拍不受理（唯一的代价拍——写口被交换写占用）
T2: IDLE：正常受理，新请求读到的已是交换后的 L1/VC 状态
```

CPU 可见延迟 1 拍（同 hit），cache 占用共 2 拍。

### 4.3 L1 miss + VC hit + victim 脏（写通道踢出 + 免总线读换入）

```
T1: LOOKUP：data_ok / write_done 照发（数据来自 VC 行，与 victim 无关，必正确）
    vc_swap_wb_r ← 1；miss_replace_way ← victim_way（复用现有锁存）
T2…: REPLACE：只发 wr_req 踢脏行（rd_req 被 vc_swap_wb_r 压死，全程零总线读）
      wr_addr = {victim_tag, req_index, 0}，wr_data = accept 拍读到的 victim 整行
      写握手拍（wr_req && wr_rdy）当拍完成交换写（同 4.2 那组写），VC entry 清空
      —— 安全前提：bridge 在握手拍把整行锁进 wr_data_latched，
         且 bank 写不改 bank_rdata 输出寄存器，AXI 写出数据不受影响
T3: IDLE
```

对 st 的收益最大：旧方案（退化重取）要写回+整行 burst 读+合并，现在只写回。

### 4.4 L1 miss + VC miss（正常 miss + 尾部插入）

原 REPLACE/REFILL 流程完全不变（含 LOOKUP 直通 REFILL 快路径），仅在
REFILL 末拍（`return_last`）追加：

```verilog
vc_insert = refill_d_we && tagv_rdata[miss_replace_way][0]   // victim 有效
                        && !d_rdata[miss_replace_way];        // 且干净
```

成立则 victim 整行+地址写入 `vc_fifo_ptr` 指向的 entry、指针+1。
脏 victim 走原写回不进 VC。victim 数据自 accept 拍起一直保持在 bank_rdata
输出寄存器里（miss 期间无新读），到末拍仍有效；末拍压写受理的新读在
拍末才更新 rdata，NBA 语义保证插入锁到旧值——正确。

### 4.5 WB 碰撞 → SWAP 修复态

```
T1: LOOKUP miss 且撞碰撞窗口（见 §5）：
    该给的 data_ok/write_done 照给，置 data_sent_r → SWAP
T2: SWAP：ram_read_en 重读 req_index 一整套（WB 此时必已排空，见 §5.3）
T3: LOOKUP 重入：数据全新鲜，重新走 4.2/4.3/4.4 任一路径
    data_sent_r 抑制重复 data_ok/write_done/perf 计数，拍末自清
```

## 5. WB 碰撞检测（victim 数据/脏位陈旧性）

### 5.1 三个窗口

| 窗口 | 条件 | 后果 |
|------|------|------|
| 一 | accept 拍与 `wb_write` 同拍 | 该 way 该 bank 的读被写抢占**丢弃**（跨 set 也算），残留旧地址数据。accept 拍记录 `collide_valid_r / collide_wayhit_r` |
| 二 | 本 LOOKUP 拍 `wb_write && wb_index==req_index && wb_way_hit[use_way]` | 读早于写：victim 行缺 store 数据、脏位假干净 |
| 三（`vc_fill_conflict`） | 本 LOOKUP 拍 `wb_write && wb_way_hit[victim_way]`（跨 set 同 way）且要做当拍交换 | 纯 bank **写口**冲突（WB 写与交换写抢同一 way 的单端口） |

```verilog
wb_collide = victim_needed && tagv_rdata[use_way][0]
           && ( (collide_valid_r && collide_wayhit_r[use_way])            // 窗口一
              || (wb_write && wb_index==req_index && wb_way_hit[use_way]) ); // 窗口二
goto_swap  = main_lookup && !cache_hit && (wb_collide || vc_fill_conflict);
```

- `use_way`：普通 miss = victim_way；CACOP code10 = hit_way_idx；code00/01 = cacop_way_r
- `victim_needed`：cached miss / CACOP code01 / code10 命中。uncached 与 code00 不用行数据，不修复
- 脏位陈旧只朝危险方向错（真脏被看成假干净），故碰撞判定**不看脏位**，先修复再判

### 5.2 覆盖范围（不止 VC）

SWAP 同时保护：VC 交换的 victim 锁存、REFILL 插入的 victim 数据、
**普通脏写回**、**CACOP 写回**——顺带修复了 VC 之前就存在的
"wb_write 拍受理 → 跨 set 脏写回带错一个 bank"存量隐患。

### 5.3 为什么 SWAP 固定 1 拍、无需等待

WB 写拍 = 某 store hit LOOKUP 的下一拍；同一拍只有一个请求占 LOOKUP，
而进 SWAP 的请求自己占了 LOOKUP 且是 miss → `wb_next=IDLE`。
所以进 SWAP 时 WB 必已排空，SWAP 只是一个重读拍。
同理可证 WB 写拍与交换写拍永不同拍（除窗口三的跨 set 情形，已让位处理）。

## 6. ld / st 差异（仅三点）

1. **数据方向**：ld 走 `vc_read_done`（占输出 FIFO 空位）；st 走 `write_done`（posted，LOOKUP 拍即完成，后续是后台事）
2. **合并点**：st 的 wdata 当拍组合合并进换入行（`vc_fill_word`），换入行 d 位=`req_op`。
   **不经 writebuffer**——书上 WB 防的是"BRAM 读出→组合→同 BRAM 写入"的数据闭环，
   而这里写数据源是 VC 触发器 ⊕ 请求缓冲触发器，无 BRAM 输出参与（详见 §9）
3. 其余状态序列 ld/st 完全一致，st 无退化路径

## 7. CACOP / Uncached / 预取

### CACOP
- 查询隔离：`vc_hit` 含 `!cacop_en_r`——CACOP 期间 VC 不命中不交换不插入
- **但 CACOP 会动 VC**（漏掉即 DMA/自修改代码错误）：在 CACOP 的 LOOKUP 拍当拍完成
  - code10：全地址精确比较，清匹配 entry（最多 1 行）
  - code00/01：index 字段匹配，清 0~VC_DEPTH 行（VC 行无 way 概念，保守全清同 index；clean-only 使过度失效永远安全）
  - code11：不动
- CACOP 写回路径纳入 SWAP 碰撞保护（`use_way`/`victim_needed` 的 cacop 分支）

### Uncached
- `vc_hit` 含 `req_cached`：查找/交换/插入全程绕开，地址在 VC 里也照走总线
- uncached store 的陈旧副本问题 = 软件 CACOP 职责（与 L1 现状一致）

### 预取（I-cache）
当前 `u_icache` 已 `VC_EN=0`，本节仅在将来重开 I 侧 VC 时生效（逻辑保留在代码中）：
- 预取 LOOKUP 的 VC hit：不给 data_ok、不交换，转 IDLE 视作预取命中（`prefetch_active` 门控）
- ifetch 的 VC hit 完成也挂下一行预取（`set_prefetch_pending` 的 `(cache_hit || vc_serve)` 分支）
- 预取 refill 的干净 victim 照常插入 VC
- I 侧无 store ⇒ 无 WB/SWAP/合并/脏路径，自动退化为纯 load 交换子集

## 8. 状态机全貌（VC 集成后）

```
IDLE → LOOKUP ─ hit ──────────────→ (衔接/IDLE)
              ─ miss+VC hit 干净 ──→ IDLE          交换写在离开 LOOKUP 的上跳沿完成
              ─ miss+VC hit 脏 ───→ REPLACE ─wr握手→ IDLE   握手拍完成交换写，零总线读
              ─ miss+VC miss ─────→ (REPLACE→)REFILL ─末拍插入VC→ IDLE/衔接
              ─ miss+WB 碰撞 ─────→ SWAP → LOOKUP 重入
```

交换写是**事件驱动**而非状态：

```verilog
vc_fill_lookup  = vc_serve && !victim_dirty && !prefetch_active && !goto_swap;  // LOOKUP 当拍
vc_fill_replace = main_replace && vc_swap_wb_r && wr_req && wr_rdy;             // 写握手拍
vc_fill         = vc_fill_lookup || vc_fill_replace;
vc_fill_way     = vc_fill_replace ? miss_replace_way : victim_way;
```

两个事件拍 RAM 均无读（v1 不衔接 / REPLACE 无受理），写口天然空闲。

## 9. 时序路径分析（为什么当拍 fill 不需要 writebuffer）

| 路径 | 组成 | 性质 |
|------|------|------|
| bank 写数据 | `vc_data`(FF) ⊕ `req_wdata`(FF) → mux → BRAM 入 | 无 BRAM 输出参与，浅 |
| VC 行/字选择 | `vc_match` 一热 OR 归约（同 `hit_word` 风格），不经 `vc_hit_idx` 优先编码 | 与 L1 选字同深度 |
| tagv 写数据 | `{req_tag,1}`(FF) | 浅 |
| VC entry 回填 | `bank_rdata`(BRAM 输出寄存器) → 1 层 mux → `vc_data`(FF) | BRAM 出→FF 入，可接受 |
| **写使能/选路** | `tagv_rdata`(BRAM 出) → tag 比较 → victim/dirty/conflict → BRAM wen | 与现有 `rd_req_lookup`/`main_next` 同锥同深度，仅多挂 wen 负载 |

书上 WB 防的"BRAM 出→组合→同 BRAM 写数据"闭环在此不存在。
**回退预案**：若综合后 wen 路径成为关键路径，恢复"锁存+下一拍写"版本
（git 历史中的 MAIN_VCFILL + vcf_* 实现），代价 = 干净交换多 1 个死拍。

## 10. 计数器与断言

```
L1 命中率    = 1 - perf_miss_cnt / perf_access_cnt
VC 后命中率  = 1 - perf_real_miss_cnt / perf_access_cnt     ← 与无 VC 基线直接对比
VC 抢救率    = perf_vc_hit_cnt / perf_miss_cnt
VC 利用率    = perf_vc_hit_cnt / perf_vc_insert_cnt
```

计数均被 `!data_sent_r` 门控防 SWAP 重入双计。
断言（`SYNTHESIS` 宏隔离）：L1∩VC=∅ 违反报 FAIL；VC 重复 entry 报 WARN。

## 11. 已知良性 corner

仅 I 侧、预取失配压写受理拍：新请求 LOOKUP 用到被 refill 写抢占的陈旧
tagv/bank 视图，极端序列下 VC 可能出现重复 entry——两份数据一致且干净，
只浪费槽位不破坏正确性（断言 WARN 可观测）。

## 12. 新增信号速查

| 信号 | 类型 | 作用 |
|------|------|------|
| `vc_valid/vc_addr/vc_data/vc_fifo_ptr` | reg | VC 存储本体 |
| `vc_match/vc_hit/vc_hit_idx/vc_line/vc_word` | wire | 查找与选字 |
| `vc_serve` | wire | L1 miss && VC hit（服务判定） |
| `vc_fill_lookup/vc_fill_replace/vc_fill/vc_fill_way` | wire | 交换写事件与目标 way |
| `vc_fill_word[0:3]` | wire | 换入行（含 st 合并），bank 写数据源 |
| `vc_swap_wb_r` | reg | 脏交换模式标志（REPLACE 只写不读的路由） |
| `wb_collide/vc_fill_conflict/goto_swap` | wire | 三窗口碰撞检测 |
| `collide_valid_r/collide_wayhit_r` | reg | 窗口一的 accept 拍记录 |
| `data_sent_r` | reg | SWAP 重入拍抑制重复交付/计数 |
| `use_way/victim_needed` | wire | 碰撞检测的目标 way / 是否需要修复 |
| `vc_insert` | wire | REFILL 末拍插入条件 |
| `MAIN_SWAP` | state | 修复重读拍（编码 2，复用原 MISS 槽位） |

---

## 13. L2 继承指南（后续做 L2 时从这里开始）

### 13.1 推荐形态：透明式 L2，L1 零改动

```
L1 (cache.v 不动) ⇄ [rd/wr 内部协议] ⇄ L2 (新模块) ⇄ [同一协议] ⇄ cache_axi_bridge
```

- L1 照常发 `rd_req/wr_req`；L2 命中则数拍内回 `return_valid`，miss 则转发 bridge
- L1 **感知不到 L2 的存在**——miss 只是变快了，本文件所有 VC 逻辑与 L2 正交共存
- L2 内部结构抄 `cache.v` 骨架（状态机/PLRU/sp_ram bank），CPU 侧接口从
  "字请求+offset"改成"整行请求"（rd_type 3'b100 burst 语义已在协议里）
- 建议规格：64KB 起步、4 路、**行大小与 L1 相同 16B**（避免子行填充）、写回+写分配、
  uncached 旁路直通、I/D 统一（顺带改善自修改代码的 I/D 一致性）

### 13.2 直接继承的资产（与 VC 去留无关）

1. **SWAP 碰撞修复**：victim 行提取完整性的正确性修复，L2 时代照样需要
2. **victim 行提取路径**：REFILL 末拍整行+地址的提取时机（`vc_insert` 处）——
   若做排他式 L2（二期），这就是 L1 干净驱逐行喂 L2 的入口
3. **计数器口径**：`perf_real_miss_cnt` 改名为"L2 后有效 miss"沿用即可
4. bridge 的 `wr_data_latched` 握手锁存语义（L2 的写通道同样依赖）

### 13.3 L2 落地后 VC 的去留

- VC 每次抢救的收益从"省一次内存往返"缩水为"省一次 L1↔L2 往返（约 4~6 拍）"
- 用数据决定：L2 后跑回归看 `perf_vc_hit_cnt × 每次节省拍数` 是否还值那 ~600 FF
  和 LOOKUP 路径上的比较器（fmax 压力点）
- 删除是机械操作：所有 VC 逻辑带 `vc_`/`vc_fill`/`vc_swap` 前缀 + `MAIN_SWAP` 保留、
  `goto_swap` 中去掉 `vc_fill_conflict` 项即可；§12 表就是删除清单

### 13.4 若做排他式（victim-based）L2

VC 就是它的 4 项寄存器原型：全地址匹配、驱逐喂入、命中换回、clean-only 简化——
把存储换 BRAM、查找从组合比较改成流水一拍、插入从 `vc_insert` 事件改成
写端口请求，即为排他式 L2 的雏形。届时本文件 §4/§5 的全部时序结论仍然适用。
