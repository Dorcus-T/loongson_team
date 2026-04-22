`include "mycpu.h"

module if_stage(
    input clk,                          // 时钟信号
    input reset,                        // 复位信号（高有效）
    // allowin
    input id_allowin,                   // ID阶段允许接收数据
    // 来自id阶段的分支总线
    input [`BR_BUS_WD -1:0] br_bus,     // 分支总线：{br_taken, br_target}
    // 输出给id阶段
    output if_to_id_valid,                        // IF到ID有效标志
    output [`IF_TO_ID_BUS_WD -1:0] if_to_id_bus,  // IF到ID总线
    // 与指令存储器的数据交互
    output inst_sram_en,                // 指令SRAM使能
    output [3:0] inst_sram_we,          // 指令SRAM写使能（始终为0，只读）
    output [31:0] inst_sram_addr,       // 指令SRAM地址
    output [31:0] inst_sram_wdata,      // 指令SRAM写数据（未使用）
    input  [31:0] inst_sram_rdata,      // 指令SRAM读数据
    // 异常冲刷
    input wb_exc_valid,                 // wb阶段有异常则冲刷流水线
    input wb_ertn_flush,                // wb阶段有ertn指令则冲刷流水线
    // 来自csr寄存器堆
    input [31:0]exc_entry,              // 异常处理地址
    input [31:0]exc_back_pc             // 异常返回地址
);

    reg if_valid;                       // IF阶段有效标志
    wire if_ready_go;                   // IF阶段就绪标志
    wire if_allowin;                    // IF阶段允许接收新指令
    wire to_if_valid;                   // 预取指阶段有效标志

    // ========== 控制信号解析 ==========
    wire [31:0] seq_pc;                 // 顺序下一条PC（当前PC+4）
    wire [31:0] nextpc;                 // 下一周期PC（顺序或分支）
    wire br_taken;                      // 分支/跳转是否发生
    wire [31:0] br_target;              // 分支/跳转目标地址
    
    // ========== 异常信号 ==========
    wire to_if_adef;
    reg if_adef;
    wire if_exc;

    // ========== 指令信息 ==========
    wire [31:0] if_inst;                // 当前取到的指令
    reg  [31:0] if_pc;                  // 当前指令的PC

    //========== 分支总线解析 ==========
    assign {br_taken, br_target} = br_bus;
    
    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {if_exc, if_inst, if_pc};

    // ========== 流水线控制 ========== 
    assign to_if_valid = ~reset;                                              // 预取指阶段：只要不复位就一直有效
    assign seq_pc = if_pc + 32'h4;                                            // 顺序PC = 当前PC + 4（指令长度4字节）
    assign nextpc = wb_exc_valid  ? exc_entry   :                             // WB阶段有异常就进入异常处理地址，WB为ertn则返回原来地址，此两种之后再考虑跳转
                    wb_ertn_flush ? exc_back_pc :
                    br_taken      ? br_target   :
                                    seq_pc      ;
    // nextpc逻辑中异常和ertn的优先级高于brtaken，如果id和wb同时发来信号，优先处理wb的信号
    assign if_ready_go = ~br_taken;                                           //分支会阻塞if指令
    assign if_allowin = !if_valid || (if_ready_go && id_allowin)|| br_taken || (wb_ertn_flush||wb_exc_valid);  //分支让if不走但能进，让if被替换；冲刷则是让正确指令能进就行
    assign if_to_id_valid = if_valid && if_ready_go;
    
    // 取值阶段有效标志更新
    always @(posedge clk ) begin
        if (reset) begin
            if_valid <= 1'b0;
        end
        else if (if_allowin) begin
            if_valid <= to_if_valid;
        end
    end
    //只有if的valid不受wb冲刷信号影响，preif中的正确指令进入if不会失效
    // ========== PC更新 ==========
    always @(posedge clk) begin
        if (reset) begin
            // 复位时设置一个特殊值，使下一周期PC为0x1c000000（内存起始）
            if_pc <= 32'h1bfffffc;
            if_adef <= 1'b0;
        end
        else if (to_if_valid && if_allowin) begin
            // 当有分支跳转时，跳过延迟槽指令，直接跳转到目标
            if_pc <= nextpc;
            if_adef <= to_if_adef;
        end
    end

    // ========== 指令存储器控制 ==========
    assign inst_sram_en    = to_if_valid && if_allowin && !to_if_adef;  // 欲取值阶段有效且无异常，取值阶段可进入才可发出请求
    assign inst_sram_we = 4'h0;                                         // 指令SRAM只读，写使能为0
    assign inst_sram_addr = nextpc;                                     // 使用下一周期PC作为取指地址
    assign inst_sram_wdata = 32'b0;                                     // 不写入数据
    assign if_inst = inst_sram_rdata;     

    // ========== 检测异常 ==========
    assign to_if_adef = nextpc[1:0] != 2'b00 && to_if_valid;
    // preif阶段产生的异常就得跟着preif，不能标记到if中去
    assign if_exc = if_adef;
endmodule