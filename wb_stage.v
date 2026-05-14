`include "mycpu.h"

module wb_stage (
    // 时钟和复位信号
    input  wire                         clk,
    input  wire                         reset,
    // allowin
    output wire                         wb_allowin,           // 写回级是否允许接收新指令
    // 来自mem阶段
    input  wire                         mem_to_wb_valid,       // 执行级到写回级的有效标志
    input  wire [`MEM_TO_WB_BUS_WD-1:0] mem_to_wb_bus,         // 执行级传递的总线数据
    // 输出给寄存器文件
    output wire [`WB_TO_RF_BUS_WD-1:0]  wb_to_rf_bus,          // 写回级到寄存器文件的总线
    // 调试接口（用于波形追踪）
    output wire [31:0]                  debug_wb_pc,           // 写回级的PC值
    output wire [ 3:0]                  debug_wb_rf_we,        // 寄存器写使能（4位，用于调试）
    output wire [ 4:0]                  debug_wb_rf_wnum,      // 写回的寄存器号
    output wire [31:0]                  debug_wb_rf_wdata,     // 写回的数据
    // 前递控制
    output wire [ 4:0]                  wb_to_id_dest,         // 转发给译码级的目的寄存器号
    output wire [31:0]                  wb_to_id_result,       // 转发给译码级的计算结果
    // 异常与ertn信号
    output wire                         wb_ertn_flush,         // 发给流水线每个阶段（也在总线中送给csr）
    output wire                         wb_exc_valid,          // 发给流水线除IF每个阶段
    // csr与ertn冒险
    output wire                         wb_csr_we,             // wb阶段确定写csr
    output wire [13:0]                  wb_csr_num,            // wb阶段写csr的寄存器号
    // 输出给csr寄存器堆（包含异常处理和写交互信号）
    output wire [`WB_TO_CSR_BUS_WD-1:0] wb_to_csr_bus,         // 写回级到csr寄存器的总线
    // 重取指相关控制
    output wire                         exc_no_rf,             // 异常和重取指同时出现时，除中断外，避免进入异常处理程序，发IF和CSR
    output wire                         rf_valid,              // 重取指信号，发IF
    output wire [31:0]                  wb_pc_back,            // 重取指指令PC，发IF
    // MMU读写控制
    output wire [ 2:0]                  tlbrwf_valid           // {tlbrd_en, tlbwr_en, tlbfill_en}
);

    reg  wb_valid;                                    // 写回级有效标志
    wire wb_ready_go;                                 // 写回级是否准备好前进（数据已稳定）
    reg  [`MEM_TO_WB_BUS_WD-1:0] mem_to_wb_bus_r;     // 锁存的访存级数据

    // ========== 异常信号 ==========
    wire ale;
    wire syscall;
    wire brk;
    wire ine;
    wire intr;
    wire adef;
    wire tlbr, pif, ppi, ipe, fpd, fpe, adem, pil, pis, pme;
    wire [15:0] wb_exc;
    wire        mem_to_wb_rf_valid;
    wire        wb_rf_valid;               // wb阶段重取指标志

    // ========== 控制信号解析 ==========
    wire        tlbrd_en;                  // WB读tlb并写csr
    wire        tlbwr_en;                  // tlbwrWB写tlb
    wire        tlbfill_en;
    wire        gr_we;                     // 通用寄存器写使能
    wire [ 4:0] dest;                      // 目的寄存器号
    wire [31:0] final_result;              // 最终计算结果
    wire [31:0] wb_pc;                     // 程序计数器值
    wire [31:0] mem_addr;                  // 访存地址
    wire        ertn_flush;                // 异常返回冲刷信号
    wire        rf_we;                     // 寄存器写使能
    wire [ 4:0] rf_waddr;                  // 写地址（寄存器号）
    wire [31:0] rf_wdata;                  // 写数据
    wire [ 5:0] wb_exc_ecode;              // 6位 WB阶段异常一级码
    wire [ 8:0] wb_exc_esubcode;           // 9位 WB阶段异常二级码
    wire [31:0] wb_exc_pc;                 // 32位 WB阶段异常PC
    wire [31:0] wb_exc_badv;               // 32位 WB阶段异常地址
    wire        csr_we;                    // 1位 最终csr寄存器写使能
    wire [31:0] csr_wmask;                 // 32位 csr寄存器写掩码
    wire [31:0] csr_wvalue;                // 32位 csr寄存器写数据

    // ========== 解析来自MEM阶段的总线 ==========
    // 从锁存的执行级总线中提取各个字段
    assign {
        tlbrd_en,              // 201     tlbrd使能
        tlbwr_en,              // 200     tlbwf使能
        tlbfill_en,            // 199
        mem_to_wb_rf_valid,    // 198     重取指标志
        wb_csr_num,            // 197:184 csr号码
        csr_we,                // 183     csr写使能
        csr_wmask,             // 182:151 csr写掩码
        csr_wvalue,            // 150:119 csr写数据
        ertn_flush,            // 118：   异常返回冲刷信号
        wb_exc,                // 117：   异常类型
        mem_addr,              // 101-70：访存地址（32位）
        gr_we,                 // 69：    寄存器写使能
        dest,                  // 68-64： 目的寄存器号（5位）
        final_result,          // 63-32： 最终计算结果（32位）
        wb_pc                  // 31-0：  PC值（32位）
    } = mem_to_wb_bus_r;

    // ========== 输出给csr寄存器堆的总线 ==========
    assign wb_to_csr_bus = {
        wb_csr_num,         // [159:146] 14位 CSR号码
        wb_csr_we,          // [145]     1位  CSR写使能
        csr_wmask,          // [144:113] 32位 CSR写掩码
        csr_wvalue,         // [112:81]  32位 CSR写数据
        wb_ertn_flush,      // [80]      1位  异常返回冲刷信号
        exc_no_rf,          // [79]      1位  异常有效标志
        wb_exc_ecode,       // [78:73]   6位  异常码
        wb_exc_esubcode,    // [72:64]   9位  异常子码
        mem_addr,           // [63:32]   32位 异常地址（BADV）
        wb_pc               // [31:0]    32位 异常PC（ERA）
    };

    // ========== 输出给寄存器文件的总线 ==========
    assign wb_to_rf_bus = {
        rf_we,              // 位37：   寄存器写使能
        rf_waddr,           // 位36-32：写寄存器号
        rf_wdata            // 位31-0： 写数据
    };

    // ========== 流水线控制 ==========
    assign wb_ready_go = 1'b1;
    assign wb_allowin  = !wb_valid || wb_ready_go;

    // 写回级有效标志更新
    always @(posedge clk) begin
        if (reset || wb_ertn_flush || wb_exc_valid) begin
            wb_valid <= 1'b0;
        end
        else if (wb_allowin) begin
            wb_valid <= mem_to_wb_valid;
        end
    end
    // 写回级数据传递
    always @(posedge clk) begin
        if (mem_to_wb_valid && wb_allowin) begin
            mem_to_wb_bus_r <= mem_to_wb_bus;
        end
    end

    // ========== 寄存器文件写回控制 ==========
    // 只有当写回级有效且指令需要写寄存器时，才使能寄存器写操作
    assign rf_we    = gr_we && wb_valid && !wb_exc_valid;
    assign rf_waddr = dest;
    assign rf_wdata = final_result;

    // ========== csr写文件写回控制 ==========
    assign wb_csr_we = csr_we && wb_valid && !wb_exc_valid;  // 异常或者失效指令不能发出写使能

    // ========== 调试信息输出 ==========
    assign debug_wb_pc       = wb_pc;                        // 当前写回的PC值
    assign debug_wb_rf_we    = {4{rf_we}};                   // 扩展为4位（用于调试显示）
    assign debug_wb_rf_wnum  = dest;                         // 写回的寄存器号
    assign debug_wb_rf_wdata = final_result;                 // 写回的数据

    // ========== 前递输出 ==========
    assign wb_to_id_dest   = dest & {5{wb_valid}} & {5{gr_we}};
    assign wb_to_id_result = final_result;

    // ========== MMU读写控制 ==========
    assign tlbrwf_valid = {tlbrd_en, tlbwr_en, tlbfill_en} & {3{!wb_exc_valid}};

    // ========== 重取指控制 ==========
    assign wb_pc_back  = wb_pc;
    assign wb_rf_valid = mem_to_wb_rf_valid && wb_valid;
    assign exc_no_rf   = (wb_rf_valid ? (intr ? 1'b1 : 1'b0) : |wb_exc) && wb_valid;
    assign rf_valid    = wb_rf_valid;

    // ========== 异常信号解析 ==========
    assign {intr, adef, tlbr, pif, ppi, syscall, brk, ine, ipe, fpd, fpe, adem, ale, pil, pis, pme} = wb_exc;
    assign wb_exc_badv = mem_addr;
    assign wb_exc_pc   = wb_pc;
    assign wb_exc_ecode =
    intr     ? `ECODE_INT   :  // 最高：中断
    adef     ? `ECODE_ADE   :  // 第二：取指阶段
    tlbr     ? `ECODE_TLBR  :  // IF tlb相关
    pif      ? `ECODE_PIF   :
    ppi      ? `ECODE_PPI   :
    syscall  ? `ECODE_SYS   :  // 第三：译码阶段
    brk      ? `ECODE_BRK   :  // id例外互斥
    ine      ? `ECODE_INE   :  // id例外互斥
    ipe      ? `ECODE_IPE   :
    fpd      ? `ECODE_FPD   :
    fpe      ? `ECODE_FPE   :  // 第四：执行阶段
    adem     ? `ECODE_ADE   :
    ale      ? `ECODE_ALE   :
    pil      ? `ECODE_PIL   :  // MEM tlb相关
    pis      ? `ECODE_PIS   :
    pme      ? `ECODE_PME   :
    `ECODE_NO_EXC;
    assign wb_exc_esubcode = adem ? `ESUBCODE_ADEM : `ESUBCODE_ADEF;

    // ========== 冲刷信号生成 ==========
    assign wb_ertn_flush = ertn_flush && wb_valid;
    assign wb_exc_valid  = (|wb_exc || wb_rf_valid) && wb_valid;
    //冲刷指令刚进入wb，valid必为1，发出冲刷信号，下一个上跳让除了if的valid都为0，因而无法再次发冲刷信号
endmodule