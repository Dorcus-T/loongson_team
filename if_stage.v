`include "mycpu.h"

module if_stage (
    input  wire                     clk,                 // 时钟信号
    input  wire                     reset,               // 复位信号（高有效）
    // allowin
    input  wire                     id_allowin,          // ID阶段允许接收数据
    // 来自id阶段的分支总线
    input  wire [`BR_BUS_WD-1:0]   br_bus,              // 分支总线：{br_taken, br_target}
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
    // 缓存冲刷
    output wire                     icache_flush,        // 重定向时清空 ICache cpu_fifo
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
    // 来自 ICache
    input  wire                     icache_pipeline_active  // IF 读请求在途（不含 cacop）
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
    reg  [ 1:0] inst_dirty;             // 不为0就代表下一次 cache 的 data_ok 数据无效
    reg         redirect_r;             // 重定向信号寄存（边沿检测 + 延迟阻塞）
    wire        redirect_rising;        // 重定向上升沿（单周期脉冲）
    wire        if_blocked;             // 综合阻塞信号

    // ========== 分支总线解析 ==========
    assign {br_taken, br_target} = br_bus;

    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {if_exc, if_inst, if_pc};

    // ========== 流水线控制 ==========
    assign pre_if_to_if_valid = pre_if_ready_go && pre_if_valid;              // 预取指有效逻辑
    assign pre_if_valid       = ~reset;                                       // 预取指阶段：只要不复位就一直有效
    assign pre_if_ready_go    = (icache_cpu_req && icache_cpu_addr_ok) || req_already_final || (pre_if_exc_valid);
    // 如果下一次上跳能够握手发请求或者已经发送过请求，那么下一次上跳就可以前进
    assign seq_pc  = if_pc + 32'h4;                                            // 顺序PC = 当前PC + 4（指令长度4字节）
    assign nextpc  = exc_no_rf     ? exc_entry   :                             // WB阶段有异常就进入异常处理地址，WB为ertn则返回原来地址，此两种之后再考虑跳转
                     rf_valid      ? rf_pc       :                             // 重取指地址
                     wb_ertn_flush ? exc_back_pc :
                     br_taken      ? br_target   :
                                     seq_pc      ;
    // nextpc逻辑中异常和ertn的优先级高于brtaken，如果id和wb同时发来信号，优先处理wb的信号
    assign redirect_rising = (wb_ertn_flush || exc_no_rf || br_taken || rf_valid) && !redirect_r;
    assign if_blocked      = br_taken || exc_no_rf || wb_ertn_flush || rf_valid || fork_r || (redirect_r && !(|if_exc));
    assign if_ready_go     = !if_blocked && (icache_cpu_data_ok || (|if_exc)) && !inst_dirty;
    assign if_allowin      = !if_valid || (if_ready_go && id_allowin) || br_taken || wb_ertn_flush || rf_valid || exc_no_rf || fork_r || (redirect_r && !(|if_exc));
    // 分支让if不走但能进，让if被替换；冲刷则是让正确指令能进就行
    assign if_to_id_valid  = if_valid && if_ready_go;

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

    // ========== ICache 请求控制 ==========
    always @(posedge clk) begin
        if (reset || (pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b0;
        end
        else if ((icache_cpu_req && icache_cpu_addr_ok) && !(pre_if_ready_go && if_allowin)) begin
            req_already <= 1'b1;
        end
    end
    assign req_already_final = req_already && !(br_taken || wb_ertn_flush || exc_no_rf || rf_valid || redirect_r);
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
        if (reset || (icache_cpu_req && icache_cpu_addr_ok)) begin
            fork_r   <= 1'b0;
            nextpc_r <= 32'b0;
        end
        else if (!(icache_cpu_req && icache_cpu_addr_ok) && !(pre_if_exc_valid)) begin
            if (br_taken || exc_no_rf || wb_ertn_flush || rf_valid) begin
                fork_r   <= 1'b1;
                nextpc_r <= nextpc;
            end
        end
    end

    always @(posedge clk) pre_if_ready_go_r <= pre_if_ready_go; // 表明上周期preif维护的指令是否发送过访存请求
    always @(posedge clk) pre_if_exc_r <= pre_if_exc_valid;     // 表明上周期preif是不是异常指令
    // 冲刷和跳转会立马改变nextpc，假设第一到第二周期的上跳产生冲刷或者跳转信号，第三周期会得到脏数据信号
    // 第一周期如果preif可以发请求但是不能进入if，那么一定是if中有一条有效指令但是不能往后走
    // 所以pre_if_ready_go_r && !new_in的时候if第二周期中的一定是第一周期中的那一条指令
    // 如果if中没有有效数据那么就要废2条，如果刚返回或者早就有数据存在if_inst_r中那么就只废一次
    // 注意：现在指令数据存于桥的FIFO中，if_inst_r已移除。
    // IF 数据是否已被消耗用 if_to_id_valid && id_allowin 判断，
    // 同时覆盖 data_ok=0（未到）和 data_ok=1 但 IF 阻塞（到了未接）
    // redirect_r: 延迟 1 周期 → flush 在上升沿发单脉冲; inst_dirty 在延迟后取值
    always @(posedge clk) begin
        if (reset) begin
            redirect_r <= 1'b0;
        end
        else begin
            redirect_r <= wb_ertn_flush || exc_no_rf || br_taken || rf_valid;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            inst_dirty <= 2'b0;
        end
        else if (redirect_r && (inst_dirty == 2'b0)) begin
            // 重定向后 1 周期：cpu_fifo 已由 icache_flush 清空（0~4条）
            // pipeline_active=1 → cache 正在处理旧 IF 请求（非 cacop）→ 有 1 条在途 → inst_dirty=1
            // pipeline_active=0 → 无旧在途（cache 空闲 / 忙 cacop）→ inst_dirty=0
            inst_dirty <= {1'b0, icache_pipeline_active};
        end
        else if (icache_cpu_data_ok && (inst_dirty != 2'b0))
            inst_dirty <= inst_dirty - 1'b1;
    end

    // ========== ICache 输出信号 ==========
    assign if_to_mmu_vaddr = fork_r ? nextpc_r : nextpc;                                  // 发mmu虚地址
    assign icache_cpu_req   = pre_if_valid && !req_already_final && !(pre_if_exc_valid) && !redirect_rising;
    // preif有效才能发请求；已经发过不能重复；跳转遇上lduse冒险未取得正确数据不能访存
    // redirect_rising 门控：重定向首周期不发请求，等 flush 完成后再发新地址
    assign icache_cpu_op    = 1'b0;                                                       // ICache 只读
    assign icache_cpu_index  = (fork_r ? nextpc_r[`OFFSET_WIDTH +: `INDEX_WIDTH] : nextpc[`OFFSET_WIDTH +: `INDEX_WIDTH]); // 虚地址中的index部分
    assign icache_cpu_tag    = padd[`OFFSET_WIDTH + `INDEX_WIDTH +: `TAG_WIDTH];             // 实地址中的tag部分
    assign icache_cpu_offset = (fork_r ? nextpc_r[0 +: `OFFSET_WIDTH] : nextpc[0 +: `OFFSET_WIDTH]);           // 虚地址中的offset部分
    assign icache_cpu_wstrb  = 4'h0;                                                      // ICache 只读
    assign icache_cpu_wdata  = 32'b0;                                                     // ICache 只读
    assign icache_cpu_cached = if_cached;                                                 // 来自 MMU 的缓存判断
    assign icache_flush      = redirect_rising;                                          // 重定向上升沿：单周期脉冲清空 cache cpu_fifo
    assign icache_cpu_accept = (if_to_id_valid && id_allowin) || (|inst_dirty);           // IF阶段能接受数据的条件：1. IF到ID的总线有效且ID允许接收；2. 当前指令是脏指令（需要被冲刷掉）
    assign if_inst           = icache_cpu_rdata;                                          // 指令数据直连 cache 输出

    // ========== 检测异常 ==========
    assign pre_if_adef = (fork_r ? nextpc_r[1:0] : nextpc[1:0]) != 2'b00 && pre_if_valid;
    assign pre_if_exc = {pre_if_adef, if_tlb_exc};
    assign pre_if_exc_valid = |pre_if_exc && pre_if_valid;
endmodule
