`ifndef MYCPU_H
`define MYCPU_H
// ============================================================================
// 流水线宽度定义
// ===========================================================================
`define BR_BUS_WD           34      // 分支总线宽度
`define IF_TO_ID_BUS_WD     65      // IF到ID总线
`define ID_TO_EX_BUS_WD     282     // ID到EX总线
`define EX_TO_MEM_BUS_WD    228     // EX到MEM总线
`define MEM_TO_WB_BUS_WD    188     // MEM到WB总线
`define WB_TO_RF_BUS_WD     38      // WB到寄存器文件
`define WB_TO_CSR_BUS_WD    160     // WB到CSR总线

// ============================================================================
// CSR 寄存器地址
// ============================================================================
`define CSR_CRMD            14'h0   // 当前模式寄存器
`define CSR_PRMD            14'h1   // 前任模式寄存器
`define CSR_ECFG            14'h4   // 中断使能配置寄存器
`define CSR_ESTAT           14'h5   // 异常状态寄存器
`define CSR_ERA             14'h6   // 异常返回地址寄存器
`define CSR_BADV            14'h7   // 错误地址寄存器
`define CSR_EENTRY          14'hc   // 异常入口地址寄存器
`define CSR_SAVE0           14'h30  // 通用保存寄存器0
`define CSR_SAVE1           14'h31  // 通用保存寄存器1
`define CSR_SAVE2           14'h32  // 通用保存寄存器2
`define CSR_SAVE3           14'h33  // 通用保存寄存器3
`define CSR_TID             14'h40  // 定时器ID寄存器
`define CSR_TCFG            14'h41  // 定时器配置寄存器
`define CSR_TVAL            14'h42  // 定时器当前值寄存器
`define CSR_TICLR           14'h44  // 定时器中断清除寄存器

// CRMD
`define CSR_CRMD_PLV        1:0     // 特权级
`define CSR_CRMD_IE         2       // 中断使能
`define CSR_CRMD_DA         3       // 地址对齐检查
`define CSR_CRMD_PG         4       // 页表使能
`define CSR_CRMD_DATF       6:5     // 数据访存失效
`define CSR_CRMD_DATM       8:7     // 数据访存修改
// PRMD
`define CSR_PRMD_PPLV       1:0     // 前任特权级
`define CSR_PRMD_PIE        2       // 前任中断使能
// ECFG
`define CSR_ECFG_LIE        12:0    // 局部中断使能
// ESTAT
`define CSR_ESTAT_IS        12:0    // 中断状态位
`define CSR_ESTAT_ECODE     21:16   // 异常码
`define CSR_ESTAT_ESUBCODE  30:22   // 异常子码
`define CSR_ESTAT_IS10      1:0     // 软件中断
`define CSR_ESTAT_IS92      9:2     // 硬件中断
`define CSR_ESTAT_IS_TI     11      // 定时器中断
`define CSR_ESTAT_IS_IPI    12      // 核间中断
// ERA
`define CSR_ERA_PC          31:0    // 异常返回地址
// BADV
`define CSR_BADV_VADDR      31:0    // 错误虚拟地址
// EENTRY
`define CSR_EENTRY_VA       31:6    // 异常入口地址
// SAVE
`define CSR_SAVE_DATA       31:0    // 保存寄存器数据
// TID
`define CSR_TID_TID         31:0    // 定时器ID
// TCFG
`define CSR_TCFG_EN         0       // 定时器使能
`define CSR_TCFG_PERIODIC   1       // 周期模式
`define CSR_TCFG_INITVAL    31:2    // 计数初始值
// TVAL
`define CSR_TVAL_VALUE      31:0    // 定时器当前值
// TICLR
`define CSR_TICLR_CLR       0       // 中断清除位

// ==================================================
// 异常码定义 (ECODE)
// ==================================================
`define ECODE_INT      6'd0    // 中断。
`define ECODE_PIL      6'd1    // load操作页无效例外
`define ECODE_PIS      6'd2    // store操作页无效例外
`define ECODE_PIF      6'd3    // 取指操作页无效例外
`define ECODE_PME      6'd4    // 页修改例外
`define ECODE_PPI      6'd7    // 页特权等级不合规例外
`define ECODE_ADE     6'd8     // 访存指令地址错例外
`define ECODE_ALE      6'd9    // 地址非对齐例外
`define ECODE_SYS      6'd11   // 系统调用例外
`define ECODE_BRK      6'd12   // 断点例外
`define ECODE_INE      6'd13   // 指令不存在例外
`define ECODE_IPE      6'd14   // 指令特权等级错例外
`define ECODE_FPD      6'd15   // 浮点指令未使能例外
`define ECODE_FPE      6'd18   // 基础浮点指令例外
`define ECODE_TLBR     6'd63   // TLB重填例外（对应0x3F=63）
`define ECODE_NO_EXC   6'd20   // 无异常，保留编码
// ==================================================
// 异常子码定义 (ESUBCODE)
// ==================================================
`define ESUBCODE_ADEF  9'd0    // 取指地址错例外
`define ESUBCODE_ADEM  9'd1    // 访存指令地址错例外
`endif