`ifndef MYCPU_H
`define MYCPU_H

// ============================================================================
// 常数定义
// ============================================================================
`define TLB_INDEX_WD        5                            // TLB索引位宽
`define MTLB_ENTRIES        16                           // MTLB项数
`define STLB_ENTRIES        16                           // STLB项数
`define PALEN               32                           // 物理地址长度
`define VALEN               32                           // 虚拟地址长度

// ============================================================================
// 流水线宽度定义
// ============================================================================
`define BR_BUS_WD           33                            // 分支总线宽度
`define IF_TO_ID_BUS_WD     68                            // IF到ID总线
`define ID_TO_EX_BUS_WD        413                           // ID到EX总线（+6 cacop, +114 difftest）
`define EX_TO_PRE_MEM_BUS_WD   628                           // EX到PRE_MEM总线（525 + 1 bp_en + 102 bp_bus）
`define PRE_MEM_TO_MEM_BUS_WD  485                           // PRE_MEM到MEM总线（= EX_TO_MEM_BUS_WD +32 dift_paddr）
`define EX_TO_MEM_BUS_WD       485                           // EX到MEM总线（保留兼容）
`define MEM_TO_WB_BUS_WD    476                           // MEM到WB总线（+274 difftest）
`define WB_TO_RF_BUS_WD     38                            // WB到寄存器文件
`define WB_TO_CSR_BUS_WD    160                           // WB到CSR总线
`define TLBCSR_BUS_WD       160                           // tlb相关CSR数据总线
`define TLBRD_BUS_WD        101                           // WB到CSR TLB读数据总线
`define BP_BUS_WD           102                           // 分支预测器更新数据总线（不含使能和计数）
`define PRE_IF_BUS_WD       74                            // pre_if 数据总线 {pc[32], pred[42]}
`define IF_BUS_WD           78                            // IF 数据总线 {pc[32], pred[42], exc[4]}

// ============================================================================
// 分支预测器参数
// ============================================================================
`define BTB_ENTRIES          32                            // BTB 表项数
`define BTB_TAG_WD           30                            // BTB tag 位宽 (PC[31:2])
`define RAS_CAM_ENTRIES      16                            // RAS CAM 表项数
`define RAS_STACK_DEPTH      8                             // RAS 栈深度
`define RAS_PTR_WD           4                             // RAS 栈指针位宽 (ceil(log2(8+1))=4)

// ============================================================================
// 分支预测器传递给流水线的预测信息位宽
// ============================================================================
`define PRED_INFO_WD         42                            // 预测信息总位宽
// 字段分解：{pred_valid[1], pred_taken[1], pred_target[30], pred_is_ras[1], pred_btb_index[5], pred_ras_index[4]}
// 总计 = 1+1+30+1+5+4 = 42

// ============================================================================
// 流水线总线宽度更新（扩展 IF→ID, ID→EX 以携带预测信息）
// ============================================================================
// IF→ID 总线：原 68 + 预测信息 42 = 110 + static_taken 1 = 111
`undef  IF_TO_ID_BUS_WD
`define IF_TO_ID_BUS_WD      111

// ID→EX 总线：原 413 + 预测透传 42 + br_type 2 + cond_cmp 3 + br_offs 32 + is_branch 1 = 493 + static_taken 1 = 494
`undef  ID_TO_EX_BUS_WD
`define ID_TO_EX_BUS_WD      494

// EX→PRE_MEM 总线：保持原 523（预测信息在 EX 消耗，不继续传）
// PRE_MEM→MEM 总线：保持原 453
// MEM→WB 总线：保持原 444

// ============================================================================
// 误预测纠正总线（EX → IF，仅 EX 级驱动）
// ============================================================================
`define MISPRED_BUS_WD       33                            // 误预测总线宽度
// {ex_mispredict[1], ex_corr_target[32]} = 33
// ID 不参与 mispredict，所有分支纠正统一由 EX 发出

// ============================================================================
// CSR 寄存器地址
// ============================================================================
`define CSR_CRMD            14'h0                         // 当前模式寄存器
`define CSR_PRMD            14'h1                         // 前任模式寄存器
`define CSR_EUEN            14'h2                         // 扩展部件使能
`define CSR_ECFG            14'h4                         // 中断使能配置寄存器
`define CSR_ESTAT           14'h5                         // 异常状态寄存器
`define CSR_ERA             14'h6                         // 异常返回地址寄存器
`define CSR_BADV            14'h7                         // 错误地址寄存器
`define CSR_EENTRY          14'hc                         // 异常入口地址寄存器
`define CSR_TLBIDX          14'h10                        // TLB索引寄存器
`define CSR_TLBEHI          14'h11                        // TLB表项高位
`define CSR_TLBELO0         14'h12                        // TLB表项低位0
`define CSR_TLBELO1         14'h13                        // TLB表项低位1
`define CSR_ASID            14'h18                        // 地址空间标识符
`define CSR_PGDL            14'h19                        // 低半地址空间全局目录基址
`define CSR_PGDH            14'h1a                        // 高半地址空间全局目录基址
`define CSR_PGD             14'h1b                        // 全局目录基址
`define CSR_CPUID           14'h20                        // 处理器编号
`define CSR_SAVE0           14'h30                        // 通用保存寄存器0
`define CSR_SAVE1           14'h31                        // 通用保存寄存器1
`define CSR_SAVE2           14'h32                        // 通用保存寄存器2
`define CSR_SAVE3           14'h33                        // 通用保存寄存器3
`define CSR_TID             14'h40                        // 定时器ID寄存器
`define CSR_TCFG            14'h41                        // 定时器配置寄存器
`define CSR_TVAL            14'h42                        // 定时器当前值寄存器
`define CSR_TICLR           14'h44                        // 定时器中断清除寄存器
`define CSR_LLBCTL          14'h60                        // LLBit控制
`define CSR_TLBRENTRY       14'h88                        // TLB充填例外入口地址
`define CSR_CTAG            14'h98                        // 高速缓存标签
`define CSR_DMW0            14'h180                       // 直接映射配置窗口0
`define CSR_DMW1            14'h181                       // 直接映射配置窗口1

// CRMD
`define CSR_CRMD_PLV        1:0                           // 特权级
`define CSR_CRMD_IE         2                             // 中断使能
`define CSR_CRMD_DA         3                             // 直接翻译使能
`define CSR_CRMD_PG         4                             // 映射翻译使能
`define CSR_CRMD_DATF       6:5                           // 直翻时取指存储访问类型
`define CSR_CRMD_DATM       8:7                           // 直翻时ls存储访问类型
// PRMD
`define CSR_PRMD_PPLV       1:0                           // 前任特权级
`define CSR_PRMD_PIE        2                             // 前任中断使能
// EUEN
`define CSR_EUEN_FPE        0                             // 基础浮点指令使能控制位
// ECFG
`define CSR_ECFG_LIE        12:0                          // 局部中断使能
// ESTAT
`define CSR_ESTAT_IS        12:0                          // 中断状态位
`define CSR_ESTAT_ECODE     21:16                         // 异常码
`define CSR_ESTAT_ESUBCODE  30:22                         // 异常子码
`define CSR_ESTAT_IS10      1:0                           // 软件中断
`define CSR_ESTAT_IS92      9:2                           // 硬件中断
`define CSR_ESTAT_IS_TI     11                            // 定时器中断
`define CSR_ESTAT_IS_IPI    12                            // 核间中断
// ERA
`define CSR_ERA_PC          31:0                          // 异常返回地址
// BADV
`define CSR_BADV_VADDR      31:0                          // 错误虚拟地址
// EENTRY
`define CSR_EENTRY_VA       31:6                          // 异常入口地址
// CPUID
`define CSR_CPUID_COREID    8:0                           // 处理器编号
// SAVE
`define CSR_SAVE_DATA       31:0                          // 保存寄存器数据
// LLBCTL
`define CSR_LLBTCL_ROLLB    0                             // 只读，返回当前LLBit值
`define CSR_LLBCTL_WCLLB    1                             // 软件写1将LLBit清零，写0忽略
`define CSR_LLBCTL_KLO      2                             // 为1时ERTN指令执行时不将LLBit清零，后自动清0
// TLBIDX
`define CSR_TLBIDX_INDEX    4:0                           // 记录TLBSRCH命中的索引值
`define CSR_TLBIDX_PS       29:24                         // 记录操作TLB表项的PS域的值
`define CSR_TLBIDX_NE       31                            // 记录TLB表项有效与否
// TLBEHI
`define CSR_TLBEHI_VPPN     31:13                         // 记录操作TLB表项的VPPN域的值
// TLBELO
`define CSR_TLBELO_V        0                             // 页表项的有效位V
`define CSR_TLBELO_D        1                             // 页表项的脏位D
`define CSR_TLBELO_PLV      3:2                           // 页表项的特权等级PLV
`define CSR_TLBELO_MAT      5:4                           // 页表项的存储访问类型MAT
`define CSR_TLBELO_G        6                             // 页表项的全局标志位G
`define CSR_TLBELO_PPN      27:8                          // 页表的物理页号
// ASID
`define CSR_ASID_ASID       9:0                           // 当前执行程序所对应的地址空间标识符
`define CSR_ASID_ASIDBITS   23:16                         // ASID域的位宽
// PGDL
`define CSR_PGDL_BASE       31:12                         // 低半地址空间的全局目录的基址
// PGDH
`define CSR_PGDH_BASE       31:12                         // 高半地址空间的全局目录的基址
// PGD
`define CSR_PGD_BASE        31:12                         // 当前上下文中出错虚地址所对应的全局目录基址
// TLBRENTRY
`define CSR_TLBRENTRY_PA    31:6                          // TLB重填例外入口地址，为物理地址
// DMW
`define CSR_DMW_PLV0        0                             // 为1表示在PLV0可用该窗口的配置直接映射翻译
`define CSR_DMW_PLV3        3                             // 为1表示在PLV3可用该窗口的配置直接映射翻译
`define CSR_DMW_MAT         5:4                           // 虚地址落在该映射窗口下访存操作的存储访问类型
`define CSR_DMW_PSEG        27:25                         // 直接映射窗口的物理地址的[31:29]位
`define CSR_DMW_VSEG        31:29                         // 直接映射窗口的虚地址的[31:29]位
// TID
`define CSR_TID_TID         31:0                          // 定时器ID
// TCFG
`define CSR_TCFG_EN         0                             // 定时器使能
`define CSR_TCFG_PERIODIC   1                             // 周期模式
`define CSR_TCFG_INITVAL    31:2                          // 计数初始值
// TVAL
`define CSR_TVAL_VALUE      31:0                          // 定时器当前值
// TICLR
`define CSR_TICLR_CLR       0                             // 中断清除位

// ============================================================================
// 异常码定义 (ECODE)
// ============================================================================
`define ECODE_INT           6'd0                          // 中断。
`define ECODE_PIL           6'd1                          // load操作页无效例外
`define ECODE_PIS           6'd2                          // store操作页无效例外
`define ECODE_PIF           6'd3                          // 取指操作页无效例外
`define ECODE_PME           6'd4                          // 页修改例外
`define ECODE_PPI           6'd7                          // 页特权等级不合规例外
`define ECODE_ADE           6'd8                          // 取值/访存指令地址错例外
`define ECODE_ALE           6'd9                          // 地址非对齐例外
`define ECODE_SYS           6'd11                         // 系统调用例外
`define ECODE_BRK           6'd12                         // 断点例外
`define ECODE_INE           6'd13                         // 指令不存在例外
`define ECODE_IPE           6'd14                         // 指令特权等级错例外
`define ECODE_FPD           6'd15                         // 浮点指令未使能例外
`define ECODE_FPE           6'd18                         // 基础浮点指令例外
`define ECODE_TLBR          6'd63                         // TLB重填例外（对应0x3F=63）
`define ECODE_NO_EXC        6'd20                         // 无异常，保留编码
// ============================================================================
// 异常子码定义 (ESUBCODE)
// ============================================================================
`define ESUBCODE_ADEF       9'd0                          // 取指地址错例外
`define ESUBCODE_ADEM       9'd1                          // 访存指令地址错例外
// ============================================================================
// ICache 参数定义
// ============================================================================
`define I_WAY_NUM       2
`define I_INDEX_WIDTH   8
`define I_TAG_WIDTH     20
`define I_OFFSET_WIDTH  4

// ============================================================================
// DCache 参数定义
// ============================================================================
`define D_WAY_NUM       2
`define D_INDEX_WIDTH   8
`define D_TAG_WIDTH     20
`define D_OFFSET_WIDTH  4
`endif