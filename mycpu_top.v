`include "mycpu.h"

module mycpu_top(
    // ========== 系统时钟和复位 ==========
    input clk,                           // 系统时钟
    input resetn,                        // 低电平有效复位信号

    // ========== 指令存储器接口 ==========
    output        inst_sram_req,        // 指令SRAM使能
    output        inst_sram_wr,         // 指令SRAM写使能
    output [1:0]  inst_sram_size,       // 指令SRAM访问长度
    output [3:0]  inst_sram_wstrb,      // 指令SRAM写掩码
    output [31:0] inst_sram_addr,       // 指令SRAM地址
    output [31:0] inst_sram_wdata,      // 指令SRAM写数据（未使用）
    input         inst_sram_addr_ok,    // 地址握手成功
    input         inst_sram_data_ok,    // 数据握手成功
    input  [31:0] inst_sram_rdata,      // 指令SRAM读数据
    
    // ========== 数据存储器接口 ==========
    output        data_sram_req,        // 数据SRAM使能
    output        data_sram_wr,         // 数据SRAM写使能
    output [1:0]  data_sram_size,       // 数据SRAM访问长度
    output [3:0]  data_sram_wstrb,      // 数据SRAM写掩码
    output [31:0] data_sram_addr,       // 数据SRAM地址
    output [31:0] data_sram_wdata,      // 数据SRAM写数据（未使用）
    input         data_sram_addr_ok,    // 地址握手成功
    input         data_sram_data_ok,    // 数据握手成功
    input  [31:0] data_sram_rdata,      // 数据SRAM读数据
    
    // ========== 调试接口（波形追踪） ==========
    output [31:0] debug_wb_pc,           // WB阶段PC值
    output [3:0] debug_wb_rf_we,         // 寄存器写使能（调试用）
    output [4:0] debug_wb_rf_wnum,       // 写回的寄存器号
    output [31:0] debug_wb_rf_wdata      // 写回的数据
);

    // ========== 复位信号处理（将低有效转换为高有效）==========
    reg reset;
    always @(posedge clk) reset <= ~resetn;

    // ========== 流水线控制信号（各级之间的握手信号） ==========
    wire id_allowin;                     // ID阶段允许接收（来自ID）
    wire ex_allowin;                     // EX阶段允许接收（来自EX）
    wire mem_allowin;                    // MEM阶段允许接收（来自MEM）
    wire wb_allowin;                     // WB阶段允许接收（来自WB）

    // 各级流水线有效标志
    wire if_to_id_valid;                 // IF -> ID 有效
    wire id_to_ex_valid;                 // ID -> EX 有效
    wire ex_to_mem_valid;                // EX -> MEM 有效
    wire mem_to_wb_valid;                // MEM -> WB 有效

    // ========== 流水线总线（各级之间的数据传递） ==========
    wire [`IF_TO_ID_BUS_WD -1:0]  if_to_id_bus;   // IF -> ID 总线
    wire [`ID_TO_EX_BUS_WD -1:0]  id_to_ex_bus;   // ID -> EX 总线
    wire [`EX_TO_MEM_BUS_WD -1:0] ex_to_mem_bus;  // EX -> MEM 总线
    wire [`MEM_TO_WB_BUS_WD -1:0] mem_to_wb_bus;  // MEM -> WB 总线
    wire [`WB_TO_RF_BUS_WD -1:0]  wb_to_rf_bus;   // WB -> 寄存器文件
    wire [`WB_TO_CSR_BUS_WD -1:0] wb_to_csr_bus;  // WB -> CSR总线
    wire [`BR_BUS_WD -1:0] br_bus;                // 分支总线

    // ========== 数据前递信号（解决RAW数据冒险） ==========
    // 前递控制：各级的目的寄存器号
    wire [4:0] ex_to_id_dest;            // EX阶段写回的寄存器号
    wire [4:0] mem_to_id_dest;           // MEM阶段写回的寄存器号
    wire [4:0] wb_to_id_dest;            // WB阶段写回的寄存器号
    
    // 前递数据：各级的计算结果
    wire [31:0] ex_to_id_result;         // EX阶段计算结果
    wire [31:0] mem_to_id_result;        // MEM阶段计算结果
    wire [31:0] wb_to_id_result;         // WB阶段计算结果
    wire        ex_to_id_load_op;        // EX阶段是否为加载指令（用于load-use检测）
    wire        mem_to_id_data_ok;       // MEM前递给id的数据是否准备好
    // ========== 异常信号与ertn ==========
    wire ex_exc_valid;       // EX阶段异常有效
    wire wb_exc_valid;       // WB阶段异常有效
    wire wb_ertn_flush;      // WB阶段有ertn指令
    wire mem_exc_valid;      // MEM阶段异常有效
    wire mem_ertn_flush;     // MEM阶段有ertn指令
    
    // ========== csr有关信号 ========== 
    wire [31:0] exc_entry;          // 异常入口地址，CSR输出给IF阶段，用于异常发生时PC跳转
    wire [31:0] exc_back_pc;        // 异常返回地址，CSR输出给IF阶段，用于ERTN指令恢复PC
    wire [31:0] csr_rvalue;         // CSR读数据，CSR输出给ID阶段，用于csrrd指令读取CSR值
    wire [13:0] csr_id_num;         // CSR读号码，ID阶段输出给CSR，用于指定要读取的CSR寄存器
    wire        has_int;            // 中断有效标志，CSR输出给ID阶段，表示有待处理的中断
    wire [31:0] coreid_in;          // 核心ID输入，来自顶层，用于初始化TID寄存器
    wire        hw_inter;           // 硬件中断有效标志，来自顶层，表示有外部硬件中断
    wire [7:0]  hw_inter_num;       // 硬件中断号，来自顶层，对应ESTAT寄存器的bit2-9
    wire        ipi_inter;          // 核间中断，来自顶层，对应ESTAT寄存器的bit12
    wire [13:0] ex_csr_num;         // ex阶段写csr寄存器号
    wire        ex_csr_we;          // ex阶段写csr使能
    wire [13:0] mem_csr_num;        // meme阶段写csr寄存器号
    wire        mem_csr_we;         // mem阶段写csr使能
    wire [13:0] wb_csr_num;         // wb阶段写csr寄存器号
    wire        wb_csr_we;          // wb阶段写csr使能

    // ========== 计数器数值 ==========
    wire [63:0] timer_value;        // 计数器输出

    // ============================================================
    // 第一阶段：取指阶段 (IF - Instruction Fetch)
    // ============================================================
    if_stage if_stage(
    .clk(clk),
    .reset(reset),
    .id_allowin(id_allowin),
    .br_bus(br_bus),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_bus(if_to_id_bus),
    .inst_sram_req(inst_sram_req),
    .inst_sram_wr(inst_sram_wr),
    .inst_sram_size(inst_sram_size),
    .inst_sram_wstrb(inst_sram_wstrb),
    .inst_sram_addr(inst_sram_addr),
    .inst_sram_wdata(inst_sram_wdata),
    .inst_sram_addr_ok(inst_sram_addr_ok),
    .inst_sram_data_ok(inst_sram_data_ok),
    .inst_sram_rdata(inst_sram_rdata),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .exc_entry(exc_entry),
    .exc_back_pc(exc_back_pc)
    );

    // ============================================================
    // 第二阶段：译码阶段 (ID - Instruction Decode)
    // ============================================================
    id_stage id_stage(
    .clk(clk),
    .reset(reset),
    .ex_allowin(ex_allowin),
    .id_allowin(id_allowin),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_bus(if_to_id_bus),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_bus(id_to_ex_bus),
    .br_bus(br_bus),
    .wb_to_rf_bus(wb_to_rf_bus),
    .ex_to_id_dest(ex_to_id_dest),
    .mem_to_id_dest(mem_to_id_dest),
    .wb_to_id_dest(wb_to_id_dest),
    .ex_to_id_load_op(ex_to_id_load_op),
    .ex_to_id_result(ex_to_id_result),
    .mem_to_id_result(mem_to_id_result),
    .wb_to_id_result(wb_to_id_result),
    .mem_to_id_data_ok(mem_to_id_data_ok),
    .mem_exc_valid(mem_exc_valid),
    .ex_csr_we(ex_csr_we),
    .ex_csr_num(ex_csr_num),
    .ex_ertn_flush(ex_ertn_flush),
    .mem_csr_we(mem_csr_we),
    .mem_csr_num(mem_csr_num),
    .mem_ertn_flush(mem_ertn_flush),
    .ex_exc_valid(ex_exc_valid),
    .wb_csr_we(wb_csr_we),
    .wb_csr_num(wb_csr_num),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .csr_rvalue(csr_rvalue),
    .csr_id_num(csr_id_num),
    .has_int(has_int)
    );
    
    // ============================================================
    // 第三阶段：执行阶段 (EX - Execute)
    // ============================================================
    exe_stage exe_stage(
    .clk(clk),
    .reset(reset),
    .mem_allowin(mem_allowin),
    .ex_allowin(ex_allowin),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_bus(id_to_ex_bus),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_bus(ex_to_mem_bus),
    .data_sram_req(data_sram_req),
    .data_sram_wr(data_sram_wr),
    .data_sram_size(data_sram_size),
    .data_sram_wstrb(data_sram_wstrb),
    .data_sram_addr(data_sram_addr),
    .data_sram_wdata(data_sram_wdata),
    .data_sram_addr_ok(data_sram_addr_ok),
    .ex_to_id_dest(ex_to_id_dest),
    .ex_to_id_result(ex_to_id_result),
    .ex_to_id_load_op(ex_to_id_load_op),
    .ex_exc_valid(ex_exc_valid),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .mem_exc_valid(mem_exc_valid),
    .mem_ertn_flush(mem_ertn_flush),
    .ex_csr_we(ex_csr_we),
    .ex_csr_num(ex_csr_num),
    .ex_ertn_flush(ex_ertn_flush),
    .timer_value(timer_value)
    );
    
    // ============================================================
    // 第四阶段：访存阶段 (MEM - Memory Access)
    // ============================================================
     mem_stage mem_stage(
    .clk(clk),
    .reset(reset),
    .wb_allowin(wb_allowin),
    .mem_allowin(mem_allowin),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_bus(ex_to_mem_bus),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_bus(mem_to_wb_bus),
    .data_sram_rdata(data_sram_rdata),
    .data_sram_data_ok(data_sram_data_ok),
    .mem_to_id_dest(mem_to_id_dest),
    .mem_to_id_result(mem_to_id_result),
    .mem_to_id_data_ok(mem_to_id_data_ok),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .mem_exc_valid(mem_exc_valid),
    .mem_ertn_flush(mem_ertn_flush),
    .mem_csr_we(mem_csr_we),
    .mem_csr_num(mem_csr_num)
    );   
    // ============================================================
    // 第五阶段：写回阶段 (WB - Write Back)
    // ============================================================
    wb_stage wb_stage(
    .clk(clk),
    .reset(reset),
    .wb_allowin(wb_allowin),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_bus(mem_to_wb_bus),
    .wb_to_rf_bus(wb_to_rf_bus),
    .debug_wb_pc(debug_wb_pc),
    .debug_wb_rf_we(debug_wb_rf_we),
    .debug_wb_rf_wnum(debug_wb_rf_wnum),
    .debug_wb_rf_wdata(debug_wb_rf_wdata),
    .wb_to_id_dest(wb_to_id_dest),
    .wb_to_id_result(wb_to_id_result),
    .wb_ertn_flush(wb_ertn_flush),
    .wb_exc_valid(wb_exc_valid),
    .wb_csr_we(wb_csr_we),
    .wb_csr_num(wb_csr_num),
    .wb_to_csr_bus(wb_to_csr_bus)
    );
   // ============================================================ 
   // csr寄存器堆
   // ============================================================
    csr_regfile csr_regfile(
        .clk(clk),
        .reset(reset),
        .exc_entry(exc_entry),
        .exc_back_pc(exc_back_pc),
        .csr_id_num(csr_id_num),
        .csr_rvalue(csr_rvalue),
        .has_int(has_int),
        .wb_to_csr_bus(wb_to_csr_bus),
        .coreid_in(32'd0),
    // 中断输入暂时全部接0
        .hw_inter_num(8'b0),
        .ipi_inter(1'b0)
    );
   // ============================================================ 
   // 计数器 
   // ============================================================
   timer_64bit timer_64bit(
        .clk(clk),
        .reset(reset),
        .timer_value(timer_value)
    );
endmodule