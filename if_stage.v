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
    output        cpu_inst_req,        // 指令SRAM使能
    output        cpu_inst_wr,         // 指令SRAM写使能
    output [1:0]  cpu_inst_size,       // 指令SRAM访问长度
    output [3:0]  cpu_inst_wstrb,      // 指令SRAM写掩码
    output [31:0] cpu_inst_addr,       // 指令SRAM地址
    output [31:0] cpu_inst_wdata,      // 指令SRAM写数据（未使用）
    input         cpu_inst_addr_ok,    // 地址握手成功
    input         cpu_inst_data_ok,    // 数据握手成功
    input  [31:0] cpu_inst_rdata,      // 指令SRAM读数据
    // 异常冲刷
    input wb_exc_valid,                 // wb阶段有异常则冲刷流水线
    input wb_ertn_flush,                // wb阶段有ertn指令则冲刷流水线
    // 来自csr寄存器堆
    input [31:0]exc_entry,              // 异常处理地址
    input [31:0]exc_back_pc             // 异常返回地址
);

    reg  if_valid;                      // IF阶段有效标志
    wire if_ready_go;                   // IF阶段就绪标志
    wire if_allowin;                    // IF阶段允许接收新指令
    wire pre_if_valid;                  // 预取指阶段有效标志
    wire pre_if_ready_go;               // 预取值阶段就绪标志
    wire pre_if_to_if_valid;            // 预取指到取值有效
    // ========== 控制信号解析 ==========
    wire [31:0] seq_pc;                 // 顺序下一条PC（当前PC+4）
    wire [31:0] nextpc;                 // 下一周期PC（顺序或分支）
    reg  [31:0] nextpc_r;               // nextpc的寄存，用于判断preif是否阻塞
    wire br_taken;                      // 分支/跳转是否发生
    wire [31:0] br_target;              // 分支/跳转目标地址
    wire br_ld_stall;                   // 跳转指令没得到正确数据不能发起取值请求

    // ========== 异常信号 ==========
    wire pre_if_adef;
    reg  if_adef;
    wire if_exc;

    // ========== 指令信息 ==========
    wire [31:0] if_inst;                // 当前取到的指令
    reg  [31:0] if_pc;                  // 当前指令的PC
    reg  [31:0] if_inst_r;              // 寄存if阶段的指令
    reg         if_inst_r_valid;        // 寄存指令是否有效
    reg  [31:0] pre_if_inst_r;          // 新读出的指令，若无新pc进入if就把它存起来
    reg         pre_if_inst_r_valid;    // 存的新指令有效
    reg         new_in;                 // 表明if中是否是新进入的指令
    reg         req_already;            // 表明preif的指令已经发出过访存请求
    wire        req_already_final;      // 考虑冲刷和分支后，表明preif的指令已经发出过访存请求

    //========== 分支总线解析 ==========
    assign {br_ld_stall, br_taken, br_target} = br_bus;
    
    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {if_exc, if_inst_r_valid ? if_inst_r : if_inst, if_pc};

    // ========== 流水线控制 ========== 
    assign pre_if_to_if_valid = pre_if_ready_go && pre_if_valid;              // 预取指有效逻辑
    assign pre_if_valid = ~reset;                                             // 预取指阶段：只要不复位就一直有效
    assign pre_if_ready_go = (cpu_inst_req && cpu_inst_addr_ok) || req_already_final;          
    //如果发出了请求就让preif可前进，被阻塞的时候请求已发送不会再发，nextpc_r为nextpc寄存一拍，二者相等代表阻塞一次；
    //被阻塞的指令一定是发送过请求的，因为新指令进入nextpc，sram总线中缓存一定是不满的。分析新指令上一条，如果缓存满，上一条指令不发送请求阻塞在preif，只是读出一次数据给if，读出一次缓存空闲，下一次上跳同时发请求，同时读出给if，缓存依然有空闲。所以新指令进入preif一定可以发请求。
   
    assign seq_pc = if_pc + 32'h4;                                            // 顺序PC = 当前PC + 4（指令长度4字节）
    assign nextpc = wb_exc_valid  ? exc_entry   :                             // WB阶段有异常就进入异常处理地址，WB为ertn则返回原来地址，此两种之后再考虑跳转
                    wb_ertn_flush ? exc_back_pc :
                    br_taken      ? br_target   :
                                    seq_pc      ;
    // nextpc逻辑中异常和ertn的优先级高于brtaken，如果id和wb同时发来信号，优先处理wb的信号
    always @(posedge clk) nextpc_r <= nextpc;

    assign if_ready_go = ~br_taken && (if_inst_r_valid || (cpu_inst_data_ok || pre_if_inst_r_valid));            
    //if的inst可以来源于if_inst_reg或者if_inst，前者有效就直接把数据送给id总线，后者的数据又可能来源于存储器（dataok表示有数据）或者preif_inst_reg
    assign if_allowin = !ifvalid || (if_ready_go && id_allowin)|| br_taken || (wb_ertn_flush||wb_exc_valid);  //分支让if不走但能进，让if被替换；冲刷则是让正确指令能进就行
    assign if_to_id_valid = if_valid && if_ready_go;
    
    // 取值阶段有效标志更新
    always @(posedge clk ) begin
        if (reset) begin
            if_valid <= 1'b0;
        end
        else if (if_allowin) begin
            if_valid <= pre_if_to_if_valid;
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
        else if (if_allowin && pre_if_to_if_valid) begin
            // 当有分支跳转时，跳过延迟槽指令，直接跳转到目标
            if_pc <= nextpc;
            if_adef <= pre_if_adef;
        end
    end

    // ========== 实现类sram总线 ==========
    always @(posedge clk ) begin
        if (reset || (pre_if_ready_go && if_allowin) ) begin
            req_already <= 1'b0;
        end
        else if (cpu_inst_req && !(pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b1;
        end
    end
    //表明preif指令是否发送过访存请求的逻辑生成
    //如果preif的指令进入if则preif一定维护新的指令，新指令没发送过访存请求
    //如果preif的访存请求为1但是不能往后走就说明发送过请求
    assign req_already_final = req_already && !(br_taken || (wb_ertn_flush || wb_exc_valid))
    //如果有冲刷或者brtaken信号会瞬间改变nextpc让他变成新指令也就不算发出过请求

    always @(posedge clk ) begin
        if (reset) begin
            new_in <= 1'b0;
        end
        else if (if_allowin && pre_if_to_if_valid) begin
            new_in <= 1'b1;
        end
    end
    //表明if是否有新指令的逻辑实现
    
    always @(posedge clk ) begin
        if (reset || (id_allowin && if_to_id_valid) || (wb_ertn_flush || wb_exc_valid) || br_taken) begin
            if_inst_r_valid <= 1'b0;
            if_inst_r <= 32'b0;
        end
        else if ((if_inst_r_valid || (cpu_inst_data_ok || pre_if_inst_r_valid)) && !id_allowin) begin
            if_inst_r_valid <= 1'b1;
            if_inst_r <= if_inst;
        end
    end
    //如果if有数据但是id不让进，下一次上跳if_inst又会响应preif发出的指令读出新的数据，所以就需要把这次的数据存起来
    //当指令进入id的时候就把指令和有效信号清空,如果有跳转就要清空让preif成功覆盖

    always @(posedge clk ) begin
        if (reset || new_in || (wb_ertn_flush || wb_exc_valid) || br_taken) begin
            pre_if_inst_r_valid <= 1'b0;
            pre_if_inst_r <= 32'b0;
        end
        else if (cpu_inst_data_ok && !new_in) begin
            pre_if_inst_r_valid <= 1'b1;
            pre_if_inst_r <= cpu_inst_rdata;
        end
    end
    //如果preif上周期发出请求但是不能进入if，就把读出的数据存起来
    //如果if中的是新指令，要是pre_if_reg中有数据，那么if_inst读出来的就是它，下一周期，要么写入if_reg要么进入id流水寄存器，所以可以清除掉
    //冲刷信号和brtaken信号都是要让下一周期if中进入特别的指令（跳转和异常处理指令），所以就得清空这两个寄存器让if的指令对应存储器新输出的数据
     
    // ========== 指令存储器控制 ==========
    assign cpu_inst_req = pre_if_valid && !to_if_adef && !req_already_final && !br_ld_stall ; 
    // preif有效且无异常才能发请求；并且已经发过的话不能重复发请求；如果跳转指令遇上lduse冒险未取得正确数据，此时访存会得到错误指令数据
    assign cpu_inst_wr = 1'b0;                                                // 不写指令存储器               
    assign cpu_inst_size = 2'b10;                                             // 读指令读一个字
    assign cpu_inst_wstrb = 4'h0;                                             // 不写指令存储器
    assign cpu_inst_addr = nextpc;                                            // nextpc为访存地址
    assign cpu_inst_wdata = 32'b0;                                            // 不写指令存储器
    assign if_inst = pre_if_inst_r_valid ? pre_if_inst_r : cpu_inst_rdata;    // 读出数据给if,如果之前有存的读出数据就给之前的

    // ========== 检测异常 ==========
    assign pre_if_adef = nextpc[1:0] != 2'b00 && pre_if_valid;
    // preif阶段产生的异常就得跟着preif，不能标记到if中去
    assign if_exc = if_adef;
endmodule

