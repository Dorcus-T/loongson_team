`include "mycpu.h"

module if_stage (
    input  wire                     clk,                 // 时钟信号
    input  wire                     reset,               // 复位信号（高有效）
    // allowin
    input  wire                     id_allowin,          // ID阶段允许接收数据
    // 输出给id阶段
    output wire                     if_to_id_valid,      // IF到ID有效标志
    output wire [`IF_TO_ID_BUS_WD-1:0] if_to_id_bus,     // IF到ID总线
    // 与 ICache 的接口
    output wire                     icache_cpu_req,      // ICache 请求有效
    output wire                     icache_cpu_op,       // ICache 操作类型（0读）
    output wire [`INDEX_WIDTH-1:0]   icache_cpu_index,    // ICache 组索引
    output wire [`TAG_WIDTH-1:0]     icache_cpu_tag,      // ICache 标签
    output wire [`OFFSET_WIDTH-1:0]  icache_cpu_offset,   // ICache 块内偏移
    output wire [ 3:0]              icache_cpu_wstrb,    // ICache 写掩码（未使用）
    output wire [31:0]              icache_cpu_wdata,    // ICache 写数据（未使用）
    input  wire                     icache_cpu_addr_ok,  // ICache 地址就绪
    input  wire                     icache_cpu_data_ok,  // ICache 数据就绪
    input  wire [31:0]              icache_cpu_rdata,    // ICache 读数据
    output wire                     icache_cpu_accept,   // IF 可接受 cache 数据
    output wire                     icache_cpu_cached,   // IF 访问可缓存
    // 与MMU交互
    output wire [31:0]              if_to_mmu_vaddr,     // IF发MMU虚地址
    input  wire [31:0]              padd,                // MMU返回物理地址
    input  wire [ 2:0]              if_tlb_exc,          // MMU返回TLB异常
    input  wire                     if_cached,           // MMU返回是否可缓存
    // 异常冲刷
    input  wire                     exc_no_rf,           // WB阶段有异常则冲刷流水线
    input  wire                     wb_ertn_flush,       // WB阶段有ertn指令则冲刷流水线
    // 来自csr寄存器堆
    input  wire [31:0]              exc_entry,           // 异常处理地址
    input  wire [31:0]              exc_back_pc,         // 异常返回地址
    // 重取指相关
    input  wire                     rf_valid,            // 重取指信号
    input  wire [31:0]              rf_pc,               // 重取指地址
    // 来自分支预测器
    input  wire                     bp_btb_hit,          // BTB 命中
    input  wire [29:0]              bp_btb_target,       // BTB 目标
    input  wire [ 1:0]              bp_btb_counter,      // BTB 计数器
    input  wire [ 4:0]              bp_btb_index,        // BTB 索引
    input  wire                     bp_ras_hit,          // RAS 命中
    input  wire [29:0]              bp_ras_target,       // RAS 目标
    input  wire [ 3:0]              bp_ras_index,        // RAS 索引
    // 来自 EX 的误预测纠正总线
    input  wire [`MISPRED_BUS_WD-1:0] mispred_bus       // 误预测纠正总线
);

    reg         if_valid;                    // IF阶段有效标志
    wire        if_ready_go;                 // IF阶段就绪标志
    wire        if_allowin;                  // IF阶段允许接收新指令
    wire        pre_if_valid;                // 预取指阶段有效标志
    wire        pre_if_ready_go;             // 预取值阶段就绪标志
    wire        pre_if_to_if_valid;          // 预取指到取值有效
    // ========== 控制信号解析 ==========
    reg  [31:0] pre_if_pc_r;            // pre_if 级 PC 寄存器（驱动取指地址）
    wire [31:0] seq_pc;                 // 顺序下一条PC（当前PC+4）
    wire [31:0] nextpc;                 // 下一周期PC（顺序或分支）
    reg  [31:0] nextpc_r;               // nextpc的寄存，用于判断preif是否阻塞
    reg         fork_r;                 // 分叉寄存

    // ========== 异常信号 ==========
    wire        pre_if_adef;
    wire [ 3:0] pre_if_exc;
    wire        pre_if_exc_valid;
    reg  [ 3:0] if_exc;

    // ========== 指令信息 ==========
    wire [31:0] if_inst;                // 当前取到的指令（直连桥的数据）
    reg  [31:0] if_pc;                  // 当前指令的PC
    reg         req_already;            // 表明preif的指令已经发出过访存请求
    reg  [ 2:0] inst_dirty;             // 不为0就代表下一次 cache 的 data_ok 数据无效

    // ========== 预测信息寄存器（随指令流传给 ID） ==========
    reg         pred_valid_r;
    reg         pred_taken_r;
    reg  [29:0] pred_target_r;
    reg         pred_is_ras_r;
    reg  [ 4:0] pred_btb_index_r;
    reg  [ 3:0] pred_ras_index_r;

    // ========== 误预测总线解析 ==========
    wire        ex_mispredict;
    wire [31:0] ex_corr_target;
    assign {ex_mispredict, ex_corr_target} = mispred_bus;

    // ========== 预测信号（纯组合，0气泡关键路径）==========
    wire btb_pred_taken;
    wire ras_pred_taken;
    assign btb_pred_taken = bp_btb_hit && bp_btb_counter[1] && !bp_ras_hit;
    assign ras_pred_taken = bp_ras_hit;

    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {
        if_exc,              // 4
        if_inst,             // 32
        if_pc,               // 32
        pred_valid_r,        // 1   (新增)
        pred_taken_r,        // 1   (新增)
        pred_target_r,       // 30  (新增)
        pred_is_ras_r,       // 1   (新增)
        pred_btb_index_r,    // 5   (新增)
        pred_ras_index_r     // 4   (新增)
    };  // 总计 4+32+32+42 = 110 bit

    // ========== 流水线控制 ==========
    assign pre_if_to_if_valid = pre_if_ready_go && pre_if_valid;              // 预取指有效逻辑
    assign pre_if_valid       = ~reset;                                       // 预取指阶段：只要不复位就一直有效
    assign pre_if_ready_go    = (icache_cpu_req && icache_cpu_addr_ok) || req_already || pre_if_exc_valid || flush_active;
    // 如果下一次上跳能够握手发请求或者已经发送过请求，那么下一次上跳就可以前进
    assign seq_pc  = (fork_r ? nextpc_r : pre_if_pc_r) + 32'h4;                 // 顺序PC = pre_if PC + 4（指令长度4字节）
    assign nextpc  = exc_no_rf     ? exc_entry      :                             // WB阶段有异常就进入异常处理地址，WB为ertn则返回原来地址，此两种之后再考虑跳转
                     rf_valid      ? rf_pc          :                             // 重取指地址
                     wb_ertn_flush ? exc_back_pc    :                             // WB阶段有ertn则返回原来地址
                     ex_mispredict ? ex_corr_target :                          // EX 级统一误预测纠正
                                     seq_pc      ;
    // nextpc逻辑中异常和ertn的优先级高于brtaken，如果id和wb同时发来信号，优先处理wb的信号
    wire flush_active; // 外部冲刷脉冲（不含 fork_r 的粘性维持），用于区分"正常异常"和"冲刷中的异常"
    assign flush_active = ex_mispredict || exc_no_rf || wb_ertn_flush || rf_valid;
    wire pipe_redirect;
    assign pipe_redirect = flush_active || fork_r;
    assign if_ready_go    = !pipe_redirect && (icache_cpu_data_ok || (|if_exc)) && !inst_dirty;
    // 分支/跳转会阻塞if指令前进；数据从桥直连进入if，不再经if_inst_r暂存
    assign if_allowin     = !if_valid || (if_ready_go && id_allowin) || pipe_redirect;
    // 分支让if不走但能进，让if被替换；冲刷则是让正确指令能进就行
    assign if_to_id_valid = if_valid && if_ready_go;

    // 取值阶段有效标志更新
    // flush_active 期间禁止 pre_if 废指令进入 IF（此时 pre_if_ready_go 反映的是旧握手状态）
    always @(posedge clk) begin
        if (reset) begin
            if_valid <= 1'b0;
        end
        else if (if_allowin) begin
            if_valid <= pre_if_to_if_valid && !flush_active;
        end
    end

    // ========== pre_if 级 PC 更新（0 气泡关键路径）==========
    always @(posedge clk) begin
        if (reset) begin
            pre_if_pc_r <= 32'h1c000000;  // 直接指向启动地址，避免 0x1bfffffc 的虚假取指
        end
        else if (pre_if_ready_go && if_allowin) begin
            // 冲刷/重定向期间禁止预测：预测基于旧 pre_if_pc_r 不可靠，且优先级低于 flush
            if (flush_active)
                pre_if_pc_r <= nextpc;
            else if (ras_pred_taken)
                pre_if_pc_r <= {bp_ras_target, 2'b00};
            else if (btb_pred_taken)
                pre_if_pc_r <= {bp_btb_target, 2'b00};
            else
                pre_if_pc_r <= nextpc;
        end
    end

    // ========== 预测信息寄存器更新 ==========
    always @(posedge clk) begin
        if (reset) begin
            pred_valid_r      <= 1'b0;
            pred_taken_r      <= 1'b0;
            pred_target_r     <= 30'd0;
            pred_is_ras_r     <= 1'b0;
            pred_btb_index_r  <= 5'd0;
            pred_ras_index_r  <= 4'd0;
        end
        else if (pre_if_ready_go && if_allowin) begin
            pred_valid_r      <= bp_btb_hit || bp_ras_hit;
            pred_taken_r      <= btb_pred_taken || ras_pred_taken;
            pred_target_r     <= ras_pred_taken ? bp_ras_target : bp_btb_target;
            pred_is_ras_r     <= bp_ras_hit;
            pred_btb_index_r  <= bp_btb_index;
            pred_ras_index_r  <= bp_ras_index;
        end
    end

    // ========== PC更新 ==========
    always @(posedge clk) begin
        if (reset) begin
            if_pc  <= 32'h1c000000;
            if_exc <= 4'b0;
        end
        else if (pre_if_to_if_valid && if_allowin && !flush_active) begin
            // 当有分支跳转时，跳过延迟槽指令，直接跳转到目标
            if_pc  <= fork_r ? nextpc_r : pre_if_pc_r;
            if_exc <= pre_if_exc;
        end
    end

    // ========== ICache 请求控制 ==========
    always @(posedge clk) begin
        if (reset || (pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b0;
        end
        else if ((icache_cpu_req && icache_cpu_addr_ok) && !(pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b1;
        end
    end

    // 如果收到跳转或者冲刷信号但是握手不成功，下一次访存依然需要访存这些特定指令的数据，所以需要寄存
    // 如果有寄存信号，代表收到了跳转或者冲刷信号但是还没发出访存请求，需要持续更改访存地址
    // 尤其是对于跳转信号，还需要一直保证if的指令不忘后面走
    // fork_r 清除条件：正常握手 || 非冲刷期的异常指令（冲刷期的异常不让 fork_r 清除）
    always @(posedge clk) begin
        if (reset || (icache_cpu_req && icache_cpu_addr_ok) || (pre_if_exc_valid && !flush_active)) begin
            fork_r   <= 1'b0;
            nextpc_r <= 32'b0;
        end
        else if (!(icache_cpu_req && icache_cpu_addr_ok)) begin
            if (flush_active) begin
                fork_r   <= 1'b1;
                nextpc_r <= nextpc;
            end
        end
    end

    // ========== 脏指令控制 ==========
    wire [2:0] inst_dirty_control;
    assign inst_dirty_control = ((!if_exc && if_valid && !icache_cpu_data_ok) && req_already) ? 3'b010 :
                                ((!if_exc && if_valid && !icache_cpu_data_ok) || req_already) ? 3'b001 :
                                                                                                3'b000 ;
    always @(posedge clk) begin
        if (reset) begin
            inst_dirty <= 3'b0;
        end
        else if (flush_active) begin
            inst_dirty <= inst_dirty + inst_dirty_control; 
        end
        else if (icache_cpu_data_ok && (inst_dirty != 3'b0)) begin
            inst_dirty <= inst_dirty - 1'b1;
        end
    end

    // ========== ICache 输出信号 ==========
    assign if_to_mmu_vaddr = fork_r ? nextpc_r : pre_if_pc_r;                              // 发mmu虚地址
    assign icache_cpu_req   = pre_if_valid && !req_already && !(pre_if_exc_valid) && !flush_active;
    // preif有效才能发请求；已经发过的话不能重复发请求；跳转指令遇上lduse冒险未取得正确数据时也不能访存
    assign icache_cpu_op    = 1'b0;                                                       // ICache 只读
    assign icache_cpu_index  = (fork_r ? nextpc_r[`OFFSET_WIDTH +: `INDEX_WIDTH] : pre_if_pc_r[`OFFSET_WIDTH +: `INDEX_WIDTH]); // 虚地址中的index部分
    assign icache_cpu_tag    = padd[`OFFSET_WIDTH + `INDEX_WIDTH +: `TAG_WIDTH];             // 实地址中的tag部分
    assign icache_cpu_offset = (fork_r ? nextpc_r[0 +: `OFFSET_WIDTH] : pre_if_pc_r[0 +: `OFFSET_WIDTH]);           // 虚地址中的offset部分
    assign icache_cpu_wstrb  = 4'h0;                                                      // ICache 只读
    assign icache_cpu_wdata  = 32'b0;                                                     // ICache 只读
    assign icache_cpu_cached = if_cached;                                                 // 来自 MMU 的缓存判断
    assign icache_cpu_accept = (if_to_id_valid && id_allowin) || (|inst_dirty) || flush_active;           // IF阶段能接受数据的条件：1. IF到ID的总线有效且ID允许接收；2. 当前指令是脏指令（需要被冲刷掉）
    assign if_inst           = icache_cpu_rdata;                                          // 指令数据直连 cache 输出

    // ========== 检测异常 ==========
    assign pre_if_adef = (fork_r ? nextpc_r[1:0] : pre_if_pc_r[1:0]) != 2'b00 && pre_if_valid;
    assign pre_if_exc = {pre_if_adef, if_tlb_exc};
    assign pre_if_exc_valid = |pre_if_exc && pre_if_valid;
endmodule
