`include "mycpu.h"

module wb_stage (
    // 时钟和复位信号
    input  wire                         clk,
    input  wire                         reset,
    // 来自mem阶段
    input  wire                         mem_to_wb_valid,       // MEM到WB有效
    input  wire [`MEM_TO_WB_BUS_WD-1:0] mem_to_wb_bus,         // MEM传递的总线数据
    // 输出给寄存器文件
    output wire [`WB_TO_RF_BUS_WD-1:0]  wb_to_rf_bus,          // 写回级到寄存器文件的总线
    // 调试接口（用于波形追踪）
    output wire [31:0]                  debug_wb_pc,           // 写回级的PC值
    output wire [ 3:0]                  debug_wb_rf_we,        // 寄存器写使能（4位，用于调试）
    output wire [ 4:0]                  debug_wb_rf_wnum,      // 写回的寄存器号
    output wire [31:0]                  debug_wb_rf_wdata,     // 写回的数据
    output wire [31:0]                  debug_wb_inst,         // 写回指令编码（用于difftest）
    // 前递控制
    output wire [ 4:0]                  wb_to_id_dest,         // 转发给译码级的目的寄存器号
    output wire [31:0]                  wb_to_id_result,       // 转发给译码级的计算结果
    // csr与ertn冒险
    output wire                         wb_csr_we,             // wb阶段确定写csr
    output wire [13:0]                  wb_csr_num,            // wb阶段写csr的寄存器号
    // 输出给csr寄存器堆（包含异常处理和写交互信号）
    output wire [`WB_TO_CSR_BUS_WD-1:0] wb_to_csr_bus,         // 写回级到csr寄存器的总线
    // 冲刷相关控制
    output wire                         wb_ertn_flush,         // ertn 冲刷，不经过 linectrl
    output wire                         exc_no_rf,             // 异常和重取指同时出现时，除中断外，避免进入异常处理程序，发IF和CSR
    output wire                         rf_valid,              // 重取指信号，发IF
    output wire [31:0]                  wb_pc_back,            // 重取指指令PC，发IF
    // MMU读写控制
    output wire [ 2:0]                  tlbrwf_valid,          // {tlbrd_en, tlbwr_en, tlbfill_en}

    // ── linectrl 接口 ──
    input  wire                         ldata,                 // 0=用旧寄存器, 1=用新寄存器
    input  wire                         lvalid,                // 本拍可呈现数据
    input  wire                         lpower,                // 本拍有权发请求
    input  wire                         lready,                // 维持就绪
    input  wire                         upd,                   // 上级已准备且有权力 → 更新 data_n

    output wire                         wb_valid_o,            // → linectrl valid_i
    output wire                         wb_ready_go            // → linectrl readygo_i
    `ifdef DIFFTEST_EN
    ,
    output wire        ws_valid_diff                    ,
    output wire        ws_cnt_inst_diff                 ,
    output wire [63:0] ws_timer_64_diff                 ,
    output wire [ 7:0] ws_inst_ld_en_diff               ,
    output wire [31:0] ws_ld_paddr_diff                 ,
    output wire [31:0] ws_ld_vaddr_diff                 ,
    output wire [ 7:0] ws_inst_st_en_diff               ,
    output wire [31:0] ws_st_paddr_diff                 ,
    output wire [31:0] ws_st_vaddr_diff                 ,
    output wire [31:0] ws_st_data_diff                  ,
    output wire        ws_csr_rstat_en_diff             ,
    output wire [31:0] ws_csr_data_diff
`endif
);

    wire wb_valid;                                    // 本拍有效 = (ldata? valid_n : valid_o) & lvalid
    wire wb_exc_valid;                                // 异常有效 = (|wb_exc || wb_rf_valid) && wb_valid
    wire can_req;                                      // 可发请求 = wb_valid && !wb_exc_valid && lpower

    // ========== 双寄存器结构 ==========
    reg  [`MEM_TO_WB_BUS_WD-1:0] data_n;              // 新数据寄存器（upd 时捕获）
    reg                          valid_n;             // 新 valid
    reg  [`MEM_TO_WB_BUS_WD-1:0] data_o;              // 旧数据寄存器
    reg                          valid_o;             // 旧 valid

    // ── data_n: upd 时从上游捕获 ──
    always @(posedge clk) begin
        if (reset) begin
            data_n  <= `MEM_TO_WB_BUS_WD'd0;
            valid_n <= 1'b0;
        end
        else if (upd) begin
            data_n  <= mem_to_wb_bus;
            valid_n <= mem_to_wb_valid;
        end
    end

    // ── data_o: ldata=1 且未准备时从 data_n 拷贝 ──
    always @(posedge clk) begin
        if (reset) begin
            data_o  <= `MEM_TO_WB_BUS_WD'd0;
            valid_o <= 1'b0;
        end
        else begin
            if (ldata)  data_o  <= current_bus;
            valid_o <= (ldata ? valid_n : valid_o) & lvalid;
        end
    end

    // ── ldata 选通 ──
    wire [`MEM_TO_WB_BUS_WD-1:0] current_bus;
    assign current_bus = ldata ? data_n : data_o;
    assign wb_valid    = (ldata ? valid_n : valid_o) & lvalid;
    assign can_req     = wb_valid && !wb_exc_valid && lpower;

    // ── ready_go = work_done || !valid || lready,  wb: work_done ≡ 1 ──
    assign wb_ready_go = 1'b1;

    // ── → linectrl ──
    assign wb_valid_o = wb_valid;

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
    wire [31:0] mem_final_result;          // 总线上的最终结果（load 时为地址，无意义）
    wire [31:0] final_result;              // 最终计算结果（load 时由 mem_rdata 扩展）
    wire [31:0] wb_pc;                     // 程序计数器值
    wire [31:0] mem_addr;                  // 访存地址
    wire        res_from_mem;              // 结果来自存储器（load 数据扩展使能）
    wire        mem_sign_ext;              // 符号扩展标志
    wire [ 2:0] mem_size;                  // 访存大小
    wire [31:0] mem_rdata;                 // 原始读数据（dcache 直通）
    // 访存数据控制信号
    wire [ 1:0] offset;                    // 偏移量，地址低两位
    wire [31:0] shift_data;                // 偏移后的数据
    wire [31:0] data_result;               // 最终读的数据
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

    `ifdef DIFFTEST_EN
    // ========== difftest 信号 ==========
    wire [31:0] dift_csr_data;
    wire        dift_csr_rstat_en;
    wire [ 7:0] dift_inst_st_en;
    wire [ 7:0] dift_inst_ld_en;
    wire        dift_cnt_inst;
    wire [63:0] dift_timer_64;
    wire [31:0] dift_id_inst;
    wire [31:0] dift_vaddr;
    wire [31:0] dift_st_data;
    wire [31:0] dift_paddr;
    `else
    // 占位 dummy wire（保持总线位宽不变）
    wire [241:0] _unused_diff_pad;
    `endif

    // ========== 解析来自MEM阶段的总线 ==========
    // 从锁存的执行级总线中提取各个字段
    assign {
        res_from_mem,          // 480     结果来自存储器（load 数据扩展使能）
        mem_sign_ext,          // 479     符号扩展标志
        mem_size,              // 478:476 访存大小
        mem_rdata,             // 475:444 原始读数据（dcache 直通）
        `ifdef DIFFTEST_EN
        dift_csr_data,         // 443:412 csr读数据 for difftest
        dift_csr_rstat_en,     // 411     csr estat读使能 for difftest
        dift_inst_st_en,       // 410:403 store使能 for difftest
        dift_inst_ld_en,       // 402:395 load使能 for difftest
        dift_cnt_inst,         // 394     计数器指令 for difftest
        dift_timer_64,         // 393:330 定时器值 for difftest
        dift_id_inst,          // 329:298 指令编码 for difftest
        dift_vaddr,            // 297:266 load/store虚地址 for difftest
        dift_st_data,          // 265:234 store数据 for difftest
        dift_paddr,            // 233:202 load/store物理地址 for difftest
        `else
        _unused_diff_pad,      // 占位：保持非difftest字段bit位置不变
        `endif
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
        mem_final_result,      // 63-32： 总线最终结果（load 时为地址，无意义）
        wb_pc                  // 31-0：  PC值（32位）
    } = current_bus;

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

    // ========== 存储器读数据处理（字节/半字/字，支持符号扩展） ==========
    // load 原始数据经总线直通到本级，在此做移位对齐与扩展（MEM 级不再处理）
    assign offset = mem_addr[1:0];

    // 移位对齐（将目标数据移到最低位）
    assign shift_data = mem_rdata >> (offset * 8);

    // 根据访存大小提取并扩展
    assign data_result = mem_size[2] ? mem_rdata :                                             // 字
                         mem_size[1] ? {{16{mem_sign_ext & shift_data[15]}}, shift_data[15:0]} :  // 半字
                         mem_size[0] ? {{24{mem_sign_ext & shift_data[7]}}, shift_data[7:0]} :    // 字节
                         32'b0;

    // 最终结果：load 由原始数据扩展，其余直接使用总线值
    assign final_result = res_from_mem ? data_result : mem_final_result;

    // ========== 寄存器文件写回控制 ==========
    // 只有当写回级有效且指令需要写寄存器时，才使能寄存器写操作
    assign rf_we    = gr_we && can_req; 
    assign rf_waddr = dest;
    assign rf_wdata = final_result;

    // ========== csr写文件写回控制 ==========
    assign wb_csr_we = csr_we && can_req;  // 异常或者失效指令不能发出写使能

    // ========== 调试信息输出 ==========
    assign debug_wb_pc       = wb_pc;                        // 当前写回的PC值
    assign debug_wb_rf_we    = {4{rf_we}};                   // 扩展为4位（用于调试显示）
    assign debug_wb_rf_wnum  = dest;                         // 写回的寄存器号
    assign debug_wb_rf_wdata = final_result;                 // 写回的数据
    `ifdef DIFFTEST_EN
    assign debug_wb_inst     = dift_id_inst;                 // 写回指令编码
    `else
    assign debug_wb_inst     = wb_pc;
    `endif

    // ========== 前递输出 ==========
    assign wb_to_id_dest   = dest & {5{wb_valid}} & {5{gr_we}};
    assign wb_to_id_result = final_result;

    // ========== MMU读写控制 ==========
    assign tlbrwf_valid = {tlbrd_en, tlbwr_en, tlbfill_en} & {3{can_req}};  // 只有在wb_valid且无异常且有权时才允许发出tlb操作请求

    // ========== 重取指控制 ==========
    assign wb_pc_back  = wb_pc;
    assign wb_rf_valid = mem_to_wb_rf_valid && wb_valid;
    assign exc_no_rf   = (wb_rf_valid ? (intr ? 1'b1 : 1'b0) : |wb_exc) && wb_valid;  // 异常和重取指同时出现时，除中断外，避免进入异常处理程序，发IF和CSR
    assign rf_valid    = wb_rf_valid && wb_valid;

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
    assign wb_ertn_flush = ertn_flush && can_req; 
    assign wb_exc_valid  = (|wb_exc || wb_rf_valid) && wb_valid;
    //冲刷指令刚进入wb，valid必为1，发出冲刷信号，下一个上跳让除了if的valid都为0，因而无法再次发冲刷信号

    `ifdef DIFFTEST_EN
    // INT 不提交（只走 ExcpEvent→raise_intr），其余均提交
    wire real_valid = wb_valid && (!wb_exc_valid || syscall || brk);
    assign ws_valid_diff        = real_valid        ;
    assign ws_timer_64_diff     = dift_timer_64     ;
    assign ws_cnt_inst_diff     = dift_cnt_inst     ;

    assign ws_inst_ld_en_diff   = dift_inst_ld_en   ;
    assign ws_ld_paddr_diff     = dift_paddr        ;
    assign ws_ld_vaddr_diff     = dift_vaddr        ;

    assign ws_inst_st_en_diff   = dift_inst_st_en   ;
    assign ws_st_paddr_diff     = dift_paddr        ;
    assign ws_st_vaddr_diff     = dift_vaddr        ;
    assign ws_st_data_diff      = dift_st_data      ;

    assign ws_csr_rstat_en_diff = dift_csr_rstat_en ;
    assign ws_csr_data_diff     = dift_csr_data     ;
    `endif
endmodule