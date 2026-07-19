# MMU 功能测试程序设计

## 概述

独立的 LoongArch32 汇编测试程序，覆盖 MMU 全部功能：DMW 翻译、TLB 4KB/4MB 页翻译、TLB 指令（SRCH/RD/WR/FILL/INVTLB）、TLB 异常（TLBR/PIL/PIS/PIF/PME/PPI）、μTLB 行为。

## 测试环境约束

- CPU 始终内核态（PLV=0）运行
- 无操作系统，TLB 项由测试程序自行填充
- 独立汇编文件，不依赖现有 func 测试框架
- 入口地址: `0x1c000000`

## 地址布局

```
VA 范围              用途
─────────────────────────────────────────────
0x00000000-0x1FFFFFFF  恒等映射区 (DMW0: VSEG=0b000, PSEG=0b000)
                       包含全部代码、handler、数据
0x80000000-0x9FFFFFFF  TLB 测试区 (VA[31:29]=0b100)
                       不匹配任何 DMW，强制走 TLB
0xA0000000-0xBFFFFFFF  TLB 4MB 页测试区 (VA[31:29]=0b101)
```

### DMW0 配置

```
DMW0 = {VSEG=3'b000, 0, MAT=2'b01, 0, PLV3=1'b0, 0, PLV0=1'b1, PSEG=3'b000}
     = 0b 000_0_01_0_0_0_1_000 = 0x00000008

即: VA[31:29]=0b000 且 PLV=0 时 → PA[31:29]=0b000, MAT=1(可缓存)
```

此窗口覆盖 `0x1c000000`（代码）和 `0x1c008000`（handler），保证 PG=1 后程序不崩溃。

### 异常入口

| CSR | 值 | 说明 |
|-----|-----|------|
| EENTRY (0x0C) | `tlb_exc_handler` | PIL/PIS/PIF/PME/PPI 异常入口 |
| TLBRENTRY (0x88) | `tlb_refill_handler` | TLB miss 异常入口 |

Handler 均放在 DMW0 覆盖区（VA 0x1c00xxxx），DA=1 时可直接寻址。

## Handler 设计

### TLB Refill Handler

位于 `tlb_refill_handler`。功能:

1. SAVE0 ← r30（保存临时寄存器）
2. 读取 TLBEHI（获取异常 VA 的 VPPN）
3. 查找软件页表（硬编码映射表）
4. 填充 TLBELO0/TLBELO1（PPN, V, D, PLV, MAT）
5. 设置 ASID
6. TLBFILL（随机项写入）
7. r30 ← SAVE0（恢复）
8. ERTN（返回原执行流）

软件页表为简化实现: VA `0x800xxxxx` → PA `0x000xxxxx`（线性映射），PS=4KB。

### TLB 异常 Handler

位于 `tlb_exc_handler`。功能:

1. 读取 ESTAT.ECODE → 判断异常类型
2. 记录异常信息到约定寄存器（r25=异常码）
3. 检查 CRMD/PRMD/ERA 是否与预期一致
4. 不匹配则跳 `inst_error`
5. ERTN（如果是预期异常则返回）
6. 对于不可恢复的异常，跳 `inst_error`

## 测试用例列表

共 12 个测试用例，按功能域分组:

### 组1: DMW 翻译

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 1 | `test_dmw_translation` | DMW0 恒等映射: VA 0x00001000 st/ld 验证 | st.w 立即数 → ld.w → bne 比较 |
| 2 | `test_dmw_priority` | DMW 优先级高于 TLB: 同 VA 同时命中 DMW 和 TLB 时走 DMW | 先建 TLB 映射到 PA_X, DMW 映射到 PA_Y, 访问后验证读回的是 PA_Y 的值 |

### 组2: TLB 4KB 页翻译

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 3 | `test_tlb_4kb_basic` | VA 0x8000_0000 → PA 0x0000_A000 的 st/ld 往返 | tlbwr 建项 → st.w → ld.w → bne 比较 |
| 4 | `test_tlb_4kb_odd_even` | VA[12] 选 EVEN(0)/ODD(1) 页表项 | 同 VPPN，PPN0≠PPN1，访问偶数页和奇数页验证不同 PPN |
| 5 | `test_tlb_4kb_asid` | ASID 不同则不命中 | ASID=0xBB 建项 → ASID=0xAA 时访问触发 TLBR |

### 组3: TLB 4MB 页翻译

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 6 | `test_tlb_4mb_basic` | VA 0xA000_0000 → PA 的 st/ld 往返 | tlbwr 建 PS=21 项 → st.w → ld.w → bne 比较 |
| 7 | `test_tlb_4mb_odd_even` | 4MB 页 VA[21] 选奇偶 | 同 VPPN[18:9]，VA[21]=0 走 PPN0，VA[21]=1 走 PPN1 |

### 组4: TLB 异常

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 8 | `test_tlb_refill` | 访问未映射 VA → TLBR → handler → TLBFILL → ERTN | 不预建 TLB 项，直接 ld.w，验证 handler 执行后结果正确 |
| 9 | `test_tlb_pil` | V=0 页的 load 触发 PIL | 建 V=0 项 → ld.w → 预期 PIL 异常 → handler 验证 ECODE=1 |
| 10 | `test_tlb_pme` | D=0 页的 store 触发 PME | 建 V=1,D=0 项 → st.w → 预期 PME 异常 → handler 验证 ECODE=4 |
| 11 | `test_tlb_ppl` | CRMD.PLV > TLB.PLV 触发 PPI | tlbwr 建 PLV=3 项 → (测试在 PLV=0 下) 访问 → 预期 PPI |

### 组5: TLB 指令

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 12 | `test_tlbsrch` | TLBSRCH 查找命中/未命中 | tlbwr 建项 → tlbsrch → 读 TLBIDX → 验证 found/index |

注: TLBWR/TLBRD/TLBFILL/INVTLB 的测试已在现有 func 测试 (n59-n69) 中覆盖，此处省略。需要时可通过 `tlbwr` → `tlbrd` 读回比较验证一致性。

### 组6: 综合场景

| # | 函数 | 测试内容 | 验证方法 |
|---|------|----------|----------|
| 13 | `test_mmu_integration` | 代码取指走 TLB: 切换到 PG=1 后 bl 调用位于 TLB 映射区的函数 | 函数返回预期值到 r12 |

## 主程序流程

```
_start (0x1c000000):
    1. 设置 CRMD: DA=1, PG=0, PLV=0, IE=0 (直接翻译模式)
    2. 设置 EENTRY → tlb_exc_handler
    3. 设置 TLBRENTRY → tlb_refill_handler
    4. 设置 DMW0 恒等映射
    5. 设置 SAVE 寄存器备用
    6. 切换 CRMD: DA=0, PG=1 (进入页表翻译模式)
    7. bl test_dmw_translation
    8. bl test_dmw_priority
    9. bl test_tlb_4kb_basic
    10. bl test_tlb_4kb_odd_even
    11. bl test_tlb_4kb_asid
    12. bl test_tlb_4mb_basic
    13. bl test_tlb_4mb_odd_even
    14. bl test_tlb_refill
    15. bl test_tlb_pil
    16. bl test_tlb_pme
    17. bl test_tlb_ppl
    18. bl test_tlbsrch
    19. bl test_mmu_integration
    20. 切换 CRMD: DA=1, PG=0
    21. test_pass 死循环 (所有测试通过)
```

## 寄存器约定

| 寄存器 | 用途 |
|--------|------|
| r1 | 返回地址 (bl/jirl) |
| r12-r15 | 测试临时寄存器 |
| r16 | 测试编号 (0x52开始, n82=0x52) |
| r17 | SAVE 备份 (ERTN 异常返回用) |
| r21 | TLB 项索引 |
| r22 | 测试用基地址 |
| r23 | 测试通过计数 |
| r25 | 异常码记录 |
| r30 | 比较期望值 / SAVE0 备份 |
| r31 | 零寄存器（不用） |

## 硬件 CSR 字段参考

```
CRMD:   [4]=PG [3]=DA [2]=IE [1:0]=PLV
PRMD:   [2]=PIE [1:0]=PPLV
ESTAT:  [21:16]=ECODE [12:0]=IS (IS[11]=定时器, IS[12]=IPI)
ECFG:   [12:0]=LIE
ERA:    [31:0]=异常返回PC
BADV:   [31:0]=异常地址
EENTRY: [31:6]=异常入口PA(与0x1c000000对齐)
TLBRENTRY: [31:6]=TLB重填入口PA

TLBEHI:  [31:13]=VPPN
TLBELO0/1: [31:8]=PPN(20bit) [6]=G [5:4]=MAT [3:2]=PLV [1]=D [0]=V
TLBIDX:  [31]=NE [29:24]=PS [4:0]=INDEX
ASID:    [31:16]=ASIDBITS [9:0]=ASID

DMW:    [31:29]=VSEG [27:25]=PSEG [5:4]=MAT [3]=PLV3 [0]=PLV0

ECODE:  TLBR=0x3F PIL=1 PIS=2 PIF=3 PME=4 PPI=7
```

## 测试文件输出

- `mmu_test.S` — 汇编源文件
- 使用 LoongArch32 汇编器编译, 生成 `inst_ram.mif`
- 可在 Verilator 仿真或 Vivado 综合中加载运行
