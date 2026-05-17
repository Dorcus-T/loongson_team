`include "mycpu.h"

module if_stage (
    input  wire        clk,                          // 时钟信号
    input  wire        reset,                        // 复位信号（高有效）
    // allowin
    input  wire        id_allowin,                   // ID阶段允许接收数据
    // 来自id阶段的分支总线
    input  wire [`BR_BUS_WD-1:0] br_bus,             // 分支总线：{br_taken, br_target}
    // 输出给id阶段
    output wire        if_to_id_valid,               // IF到ID有效标志
    output wire [`IF_TO_ID_BUS_WD-1:0] if_to_id_bus, // IF到ID总线
    // 与指令存储器的数据交互
    output wire        inst_sram_req,        // 指令SRAM使能
    output wire        inst_sram_wr,         // 指令SRAM写使能
    output wire [ 1:0] inst_sram_size,       // 指令SRAM访问长度
    output wire [ 3:0] inst_sram_wstrb,      // 指令SRAM写掩码
    output wire [31:0] inst_sram_addr,       // 指令SRAM地址
    output wire [31:0] inst_sram_wdata,      // 指令SRAM写数据（未使用）
    input  wire        inst_sram_addr_ok,    // 地址握手成功
    input  wire        inst_sram_data_ok,    // 数据握手成功
    input  wire [31:0] inst_sram_rdata,      // 指令SRAM读数据
    // 与MMU交互
    output wire [31:0] if_to_mmu_vaddr,      // if发mmu虚地址
    input  wire [31:0] padd,                 // MMU返回物理地址
    input  wire [ 2:0] if_tlb_exc,           // MMU返回tlb异常
    // 异常冲刷
    input  wire        exc_no_rf,            // wb阶段有异常则冲刷流水线
    input  wire        wb_ertn_flush,        // wb阶段有ertn指令则冲刷流水线
    // 来自csr寄存器堆
    input  wire [31:0] exc_entry,            // 异常处理地址
    input  wire [31:0] exc_back_pc,          // 异常返回地址
    // 重取指相关
    input  wire        rf_valid,             // 重取指信号
    input  wire [31:0] rf_pc,                // 重取指地址
    // cpu可接受数据
    output wire        inst_cpu_accept       // IF可接受指令数据
);

    reg         if_valid;                    // IF阶段有效标志
    wire        if_ready_go;                 // IF阶段就绪标志
    wire        if_allowin;                  // IF阶段允许接收新指令
    wire        pre_if_valid;                // 预取指阶段有效标志
    wire        pre_if_ready_go;             // 预取值阶段就绪标志
    wire        pre_if_to_if_valid;          // 预取指到取值有效
    reg         pre_if_ready_go_r;           // 预取值阶段上周期的指令是否发送过请求，用于脏指令判断
    reg         pre_if_exc_r;                // 预取值阶段上周期的指令是否有异常，用于脏指令判断
    // ========== 控制信号解析 ==========
    wire [31:0] seq_pc;                 // 顺序下一条PC（当前PC+4）
    wire [31:0] nextpc;                 // 下一周期PC（顺序或分支）
    reg  [31:0] nextpc_r;               // nextpc的寄存，用于判断preif是否阻塞
    wire        br_taken;               // 分支/跳转是否发生
    reg         fork_r;                 // 分叉寄存
    wire [31:0] br_target;              // 分支/跳转目标地址
    wire        br_ld_stall;            // 跳转指令没得到正确数据不能发起取值请求
    // brtaken和冲刷信号的任务：让if中的错误指令不动，让preif输入特定的取值请求且preif可以前进
    // 冲刷通过inst_dirty机制丢弃桥FIFO中的旧数据，确保新指令进入if时拿到的是新读出的数据
    // brtaken_r和两个冲刷寄存信号会让nextpc一直指向跳转地址，且不会让if中的错误指令往前走，也会让preif可以前进

    // ========== 异常信号 ==========
    wire        pre_if_adef;
    wire [ 3:0] pre_if_exc;
    wire        pre_if_exc_valid;
    reg  [ 3:0] if_exc;

    // ========== 指令信息 ==========
    wire [31:0] if_inst;                // 当前取到的指令（直连桥的数据）
    reg  [31:0] if_pc;                  // 当前指令的PC
    reg         new_in;                 // 表明if中是否是新进入的指令
    reg         req_already;            // 表明preif的指令已经发出过访存请求
    wire        req_already_final;      // 考虑冲刷和分支后，表明preif的指令已经发出过访存请求
    reg  [ 1:0] inst_dirty;             // 不为0就代表下一次存储器的dataok数据无效

    // ========== 分支总线解析 ==========
    assign {br_ld_stall, br_taken, br_target} = br_bus;

    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {if_exc, if_inst, if_pc};

    // ========== 流水线控制 ==========
    assign pre_if_to_if_valid = pre_if_ready_go && pre_if_valid;              // 预取指有效逻辑
    assign pre_if_valid       = ~reset;                                       // 预取指阶段：只要不复位就一直有效
    assign pre_if_ready_go    = (inst_sram_req && inst_sram_addr_ok) || req_already_final || (pre_if_exc_valid);
    // 如果下一次上跳能够握手发请求或者已经发送过请求，那么下一次上跳就可以前进
    assign seq_pc  = if_pc + 32'h4;                                            // 顺序PC = 当前PC + 4（指令长度4字节）
    assign nextpc  = exc_no_rf     ? exc_entry   :                             // WB阶段有异常就进入异常处理地址，WB为ertn则返回原来地址，此两种之后再考虑跳转
                     rf_valid      ? rf_pc       :                             // 重取指地址
                     wb_ertn_flush ? exc_back_pc :
                     br_taken      ? br_target   :
                                     seq_pc      ;
    // nextpc逻辑中异常和ertn的优先级高于brtaken，如果id和wb同时发来信号，优先处理wb的信号
    assign if_ready_go    = !(br_taken || exc_no_rf || wb_ertn_flush || rf_valid || fork_r) && (inst_sram_data_ok || (|if_exc)) && !inst_dirty;
    // 分支/跳转会阻塞if指令前进；数据从桥直连进入if，不再经if_inst_r暂存
    assign if_allowin     = !if_valid || (if_ready_go && id_allowin) || br_taken || wb_ertn_flush || rf_valid || exc_no_rf || fork_r;
    // 分支让if不走但能进，让if被替换；冲刷则是让正确指令能进就行
    assign if_to_id_valid = if_valid && if_ready_go;

    // ========== CPU可接受数据 ==========
    // IF指令可进入ID时拉高，有脏数据时也拉高（数据需被消耗以清空桥中FIFO）
    assign inst_cpu_accept = (if_to_id_valid && id_allowin) || (|inst_dirty);

    // 取值阶段有效标志更新
    // 只有if的valid不受wb冲刷信号影响，preif中的正确指令进入if不会失效
    always @(posedge clk) begin
        if (reset) begin
            if_valid <= 1'b0;
        end
        else if (if_allowin) begin
            if_valid <= pre_if_to_if_valid;
        end
    end

    // ========== PC更新 ==========
    always @(posedge clk) begin
        if (reset) begin
            // 复位时设置一个特殊值，使下一周期PC为0x1c000000（内存起始）
            if_pc  <= 32'h1bfffffc;
            if_exc <= 4'b0;
        end
        else if (pre_if_to_if_valid && if_allowin) begin
            // 当有分支跳转时，跳过延迟槽指令，直接跳转到目标
            if_pc  <= fork_r ? nextpc_r : nextpc;
            if_exc <= pre_if_exc;
        end
    end

    // ========== 实现类sram总线 ==========
    always @(posedge clk) begin
        if (reset || (pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b0;
        end
        else if ((inst_sram_req && inst_sram_addr_ok) && !(pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b1;
        end
    end
    assign req_already_final = req_already && !(br_taken || (wb_ertn_flush || exc_no_rf || rf_valid));
    // 表明preif指令是否发送过访存请求的逻辑生成
    // 如果preif的指令进入if则preif一定维护新的指令，新指令没发送过访存请求
    // 如果preif的访存请求为1但是不能往后走就说明发送过请求
    // 如果有冲刷或者brtaken信号会瞬间改变nextpc让他变成新指令也就不算发出过请求
    // 寄存的跳转或者冲刷信号不应该在此发挥作用，如果有寄存信号，其代表收到信号但是还没发出请求

    // 表明if该阶段指令是否是新进入的逻辑实现
    always @(posedge clk) begin
        if (reset || !(if_allowin && pre_if_to_if_valid)) begin
            new_in <= 1'b0;
        end
        else if (if_allowin && pre_if_to_if_valid) begin
            new_in <= 1'b1;
        end
    end

    // 如果收到跳转或者冲刷信号但是握手不成功，下一次访存依然需要访存这些特定指令的数据，所以需要寄存
    // 如果有寄存信号，代表收到了跳转或者冲刷信号但是还没发出访存请求，需要持续更改访存地址
    // 尤其是对于跳转信号，还需要一直保证if的指令不忘后面走
    always @(posedge clk) begin
        if (reset || (inst_sram_req && inst_sram_addr_ok)) begin
            fork_r   <= 1'b0;
            nextpc_r <= 32'b0;
        end
        else if (!(inst_sram_req && inst_sram_addr_ok) && !(pre_if_exc_valid)) begin
            if (br_taken || exc_no_rf || wb_ertn_flush || rf_valid) begin
                fork_r   <= 1'b1;
                nextpc_r <= nextpc;
            end
        end
    end

    always @(posedge clk) pre_if_ready_go_r <= pre_if_ready_go; // 表明上周期preif维护的指令是否发送过访存请求
    always @(posedge clk) pre_if_exc_r <= pre_if_exc_valid;    // 表明上周期preif是不是异常指令

    // 冲刷和跳转会立马改变nextpc，假设第一到第二周期的上跳产生冲刷或者跳转信号，第三周期会得到脏数据信号
    // 第一周期如果preif可以发请求但是不能进入if，那么一定是if中有一条有效指令但是不能往后走
    // 所以pre_if_ready_go_r && !new_in的时候if第二周期中的一定是第一周期中的那一条指令
    // 如果if中没有有效数据那么就要废2条，如果刚返回或者早就有数据存在if_inst_r中那么就只废一次
    // 注意：现在指令数据存于桥的FIFO中，if_inst_r已移除，inst_sram_data_ok直接反映数据可用性
    always @(posedge clk) begin
        if (reset) begin
            inst_dirty <= 2'b0;
        end
        else if (wb_ertn_flush || exc_no_rf || br_taken || rf_valid) begin
            if (!if_exc && !inst_sram_data_ok && !new_in && !pre_if_exc_r && pre_if_ready_go_r)
                inst_dirty <= 2'b10;
            else if (!if_exc && (!inst_sram_data_ok || (!new_in && !pre_if_exc_r && pre_if_ready_go_r)))
                inst_dirty <= 2'b01;
            else
                inst_dirty <= 2'b00;
        end
        else if (inst_sram_data_ok && (inst_dirty != 2'b00))
            inst_dirty <= inst_dirty - 1'b1;
    end

    // ========== 指令存储器控制 ==========
    assign inst_sram_req   = pre_if_valid && !req_already_final && !br_ld_stall && !(pre_if_exc_valid);
    // preif有效才能发请求；已经发过的话不能重复发请求；跳转指令遇上lduse冒险未取得正确数据时也不能访存
    assign if_to_mmu_vaddr = fork_r ? nextpc_r : nextpc;                               // 发mmu虚地址
    assign inst_sram_wr    = 1'b0;                                                     // 不写指令存储器
    assign inst_sram_size  = 2'b10;                                                    // 读指令读一个字
    assign inst_sram_wstrb = 4'h0;                                                     // 不写指令存储器
    assign inst_sram_addr  = padd;                                                     // padd为访存地址
    assign inst_sram_wdata = 32'b0;                                                    // 不写指令存储器
    assign if_inst         = inst_sram_rdata;                                          // 指令数据直连桥输出，不再经if_inst_r暂存

    // ========== 检测异常 ==========
    assign pre_if_adef = (fork_r ? nextpc_r[1:0] : nextpc[1:0]) != 2'b00 && pre_if_valid;
    assign pre_if_exc = {pre_if_adef, if_tlb_exc};
    assign pre_if_exc_valid = |pre_if_exc && pre_if_valid;
endmodule
