`include "mycpu.h"

module if_stage (
    input  wire                     clk,                 // 时钟信号
    input  wire                     reset,               // 复位信号（高有效）
    // 输出给id阶段
    output wire                     if_to_id_valid,      // IF到ID有效标志
    output wire [`IF_TO_ID_BUS_WD-1:0] if_to_id_bus,     // IF到ID总线
    (* max_fanout = 64 *) output wire if_to_id_upd,         // IF→ID 更新 data_n
    // 与 ICache 的接口
    output wire                     icache_cpu_req,      // ICache 请求有效
    output wire [`I_INDEX_WIDTH-1:0]  icache_cpu_index,    // ICache 组索引
    output wire [`I_OFFSET_WIDTH-1:0] icache_cpu_offset,   // ICache 块内偏移
    input  wire                     icache_cpu_addr_ok,  // ICache 地址就绪
    input  wire                     icache_cpu_data_ok,  // ICache 数据就绪
    input  wire [31:0]              icache_cpu_rdata,    // ICache 读数据
    output wire                     icache_cpu_accept,   // IF 可接受 cache 数据
    // 与MMU交互
    output wire [31:0]              if_to_mmu_vaddr,     // IF发MMU虚地址
    output wire                     s0_need_mmu,         // IF 需要 MMU 翻译
    input  wire [ 2:0]              if_tlb_exc,          // MMU TLB 异常（合并到 if_exc）
    input  wire                     s0_need_mmu_r,       // s0_need_mmu 寄存一拍 → 本拍 TLB 结果有效
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
    input  wire [`MISPRED_BUS_WD-1:0] mispred_bus,       // 误预测纠正总线

    // ── linectrl 接口（pre_if = 0, if = 1）──
    input  wire [1:0]  ldata,           // 0=用旧寄存器, 1=用新寄存器
    input  wire [1:0]  lvalid,          // 本拍可呈现数据
    input  wire [1:0]  lpower,          // 本拍有权发请求
    input  wire [1:0]  lready,          // 维持就绪
    output wire [1:0]  if_valid_o,      // → linectrl valid_i
    output wire [1:0]  if_ready_o,      // → linectrl readygo_i
    output wire [1:0]  if_exc_o,        // → linectrl exc_i
    output wire [1:0]  if_ertn_o,       // → linectrl ertn_i

    // ── inst_dirty计算 ──
    input  wire         s0_flush,        // pre_if 之后有冲刷 → inst_dirty
    input  wire         s0_cancel,       // MMU TLB 异常 → 取消 pre_if 请求
    // ── 分支预测器 lookup_pc_i ──
    output wire [31:0]  if_pre_if_pc_next, // pre_if_pc_next 给 branch_predict 做查表地址
    // ── 静态分支预测（→ linectrl）──
    output wire         if_mispred_o
);

    reg  [`IF_BUS_WD-1:0] if_data_n;
    reg                  if_valid_n;
    reg  [`IF_BUS_WD-1:0] if_data_o;
    reg                  if_valid_old;
    wire                 if_valid = (ldata[1] ? if_valid_n : if_valid_old) & lvalid[1];

    wire pre_if_upd = lpower[0] || !pre_if_valid;

    // TLB 异常合并：if_data_n[3:0] = {ADEF, 3'b0}，OR 上 if_tlb_exc
    wire [3:0] if_exc_raw       = if_data_n[3:0];
    wire [3:0] if_exc_with_tlb  = {if_exc_raw[3], if_tlb_exc};

    always @(posedge clk) begin
        if (reset) begin
            if_data_n  <= `IF_BUS_WD'd0;
            if_valid_n <= 1'b0;
        end
        else if (pre_if_upd) begin
            if_data_n  <= {pre_if_current, pre_if_exc};
            if_valid_n <= pre_if_valid;
        end
        else if (s0_need_mmu_r) begin
            if_data_n[3:0] <= if_exc_with_tlb;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            if_data_o  <= `IF_BUS_WD'd0;
            if_valid_old <= 1'b0;
        end
        else begin
            if (ldata[1])  if_data_o  <= if_current;
            if_valid_old <= (ldata[1] ? if_valid_n : if_valid_old) & lvalid[1];
        end
    end

    wire [`IF_BUS_WD-1:0] if_current;
    assign if_current = ldata[1] ? (s0_need_mmu_r ? {if_data_n[`IF_BUS_WD-1:4], if_exc_with_tlb} : if_data_n)
                                  : if_data_o;

    wire [31:0] if_pc_r;
    wire        if_pred_valid, if_pred_taken, if_pred_is_ras;
    wire [29:0] if_pred_target;
    wire [ 4:0] if_pred_btb_index;
    wire [ 3:0] if_pred_ras_index;
    wire [ 3:0] if_exc_r;
    assign {
        if_pc_r, 
        if_pred_valid,
        if_pred_taken, 
        if_pred_target,
        if_pred_is_ras, 
        if_pred_btb_index, 
        if_pred_ras_index,
        if_exc_r
    } = if_current;

    wire        pre_if_ready_go;             // 预取值阶段就绪标志
    wire        if_ready_go;                 // IF 阶段就绪标志
    // ========== 控制信号解析 ==========
    wire [31:0] seq_pc;                 // 顺序下一条PC（当前PC+4）
    wire [31:0] nextpc;                 // 下一周期PC（顺序或分支）

    // ========== pre_if 双寄存器 ==========
    reg  [31:0]               pre_if_pc_n;             // 新 PC（寄存器）
    reg  [`PRE_IF_BUS_WD-1:0] pre_if_data_o;           // 旧数据（全寄存器）
    reg                       pre_if_valid_o;           // 旧有效

    always @(posedge clk) begin
        if (reset) pre_if_pc_n <= 32'h1c000000;
        else       pre_if_pc_n <= pre_if_pc_next;
    end
    always @(posedge clk) begin
        if (reset) begin
            pre_if_data_o  <= {32'h1c000000, {`PRE_IF_BUS_WD-32{1'b0}}};
            pre_if_valid_o <= 1'b0;
        end
        else begin
            if (ldata[0])  pre_if_data_o  <= pre_if_new;
            pre_if_valid_o <= (ldata[0] ? pre_if_valid_n : pre_if_valid_o) & lvalid[0];
        end
    end

    wire [`PRE_IF_BUS_WD-1:0] pre_if_new;
    assign pre_if_new = {pre_if_pc_n,
                         bp_btb_hit || bp_ras_hit,
                         btb_pred_taken || ras_pred_taken,
                         ras_pred_taken ? bp_ras_target : bp_btb_target,
                         bp_ras_hit,
                         bp_btb_index,
                         bp_ras_index};

    wire [`PRE_IF_BUS_WD-1:0] pre_if_current;
    assign pre_if_current  = ldata[0] ? pre_if_new : pre_if_data_o;
    wire   pre_if_valid_n  = ~reset;
    wire   pre_if_valid    = (ldata[0] ? pre_if_valid_n : pre_if_valid_o) & lvalid[0];

    // ── → linectrl ──
    assign if_valid_o[0] = pre_if_valid;
    assign if_valid_o[1] = if_valid;
    assign if_ready_o[0] = pre_if_ready_go;
    assign if_ready_o[1] = if_ready_go;
    assign if_exc_o[0]   = pre_if_exc_valid;
    assign if_exc_o[1]   = if_exc_valid;
    assign if_ertn_o[0]  = 1'b0;
    assign if_ertn_o[1]  = 1'b0;

    wire [31:0] pre_if_pc_r;
    wire        pred_valid_r;
    wire        pred_taken_r;
    wire [29:0] pred_target_r;
    wire        pred_is_ras_r;
    wire [ 4:0] pred_btb_index_r;
    wire [ 3:0] pred_ras_index_r;
    assign {
        pre_if_pc_r,
        pred_valid_r,
        pred_taken_r,
        pred_target_r,
        pred_is_ras_r,
        pred_btb_index_r,
        pred_ras_index_r
    } = pre_if_current;

    // ========== 异常信号（仅 ADEF，TLB 异常由 IF 级合并） ==========
    wire        pre_if_adef;
    wire [ 3:0] pre_if_exc;
    wire        pre_if_exc_valid;
    wire        if_exc_valid;

    assign s0_need_mmu = can_req;

    wire can_req = pre_if_valid && !pre_if_adef && lpower[0] && !reset;

    // ========== 指令信息 ==========
    wire [31:0] if_inst;
    reg         req_state;
    wire        req_already;
    assign req_already = req_state && !ldata[0];

    // ========== 误预测总线解析 ==========
    wire        ex_mispredict;
    wire [31:0] ex_corr_target;
    assign {ex_mispredict, ex_corr_target} = mispred_bus;

    // ========== 预测信号 ==========
    wire btb_pred_taken;
    wire ras_pred_taken;
    assign btb_pred_taken = bp_btb_hit && bp_btb_counter[1] && !bp_ras_hit;
    assign ras_pred_taken = bp_ras_hit;

    // ============================================================
    // 静态分支预测（pred_valid == 0 时生效）
    // ============================================================
    wire [ 5:0] if_opcode           = if_inst[31:26];
    wire        if_is_b_static      = (if_opcode == 6'h14);
    wire        if_is_bl_static     = (if_opcode == 6'h15);

    // b/bl: 26bit 偏移（sign = inst[9]）
    wire [25:0] if_br_offs_26       = {if_inst[9:0], if_inst[25:10]};
    wire [31:0] if_br_target_26     = if_pc_r + {{4{if_inst[9]}}, if_br_offs_26, 2'b00};

    wire [31:0] static_target       = if_br_target_26;

    wire        static_decode_taken = if_is_b_static || if_is_bl_static;

    wire        if_static_taken     = !if_pred_valid && static_decode_taken;

    wire        static_taken        = if_ready_go && if_static_taken && if_valid && !if_exc_valid && lpower[1];

    // ============================================================
    // 静态预测 mispred（→ linectrl 寄存）
    // ============================================================
    assign if_mispred_o = static_taken;

    // ========== 输出到ID阶段的总线 ==========
    assign if_to_id_bus = {
        if_exc_r, 
        if_inst, 
        if_pc_r,
        if_pred_valid, 
        if_pred_taken, 
        if_pred_target,
        if_pred_is_ras, 
        if_pred_btb_index, 
        if_pred_ras_index,
        if_static_taken
    };

    // ========== 流水线控制 ==========
    wire cache_sent     = (icache_cpu_req && icache_cpu_addr_ok) || req_already;
    wire pre_if_work_done = pre_if_exc_valid ? 1'b1 : cache_sent;
    assign pre_if_ready_go = pre_if_work_done || !pre_if_valid || lready[0];

    // ========== pre_if 下一拍 PC ==========
    wire [31:0] pre_if_pc_next;
    assign pre_if_pc_next = nextpc;

    // ========== IF 级 ==========
    assign seq_pc  = pre_if_pc_r + 32'h4;
    assign nextpc  = exc_no_rf     ? exc_entry      :
                     rf_valid      ? rf_pc          :
                     wb_ertn_flush ? exc_back_pc    :
                     ex_mispredict ? ex_corr_target :
                     static_taken  ? static_target  :
                     pred_taken_r  ? {pred_target_r, 2'b00} :
                                     seq_pc      ;
                                     
    wire if_work_done = (icache_cpu_data_ok || if_exc_valid) && (inst_dirty == 3'b0);
    assign if_ready_go    = if_work_done || !if_valid || lready[1];
    assign if_to_id_valid = if_valid;
    assign if_to_id_upd   = lpower[1] || !if_valid;

    // ========== ICache 请求控制（仿 MEM 模式） ==========
    wire req_set = icache_cpu_req && icache_cpu_addr_ok;
    always @(posedge clk) begin
        if (reset)                              req_state <= 1'b0;
        else if (ldata[0] && !req_set)          req_state <= 1'b0;
        else if (req_set)                       req_state <= 1'b1;
    end

    // ========== 脏指令控制 ==========
    // 条件 A：IF 级阻塞
    // 条件 B：pre_if 请求 — 拆为 req_already（已发起）和 req_set（本拍握手）
    wire        cond_if       = !if_exc_valid && if_valid && !if_ready_go;
    wire [ 2:0] inst_dirty_control;
    wire [ 2:0] inst_dirty;
    reg  [ 2:0] inst_dirty_ctrl_r;   // {cond_if, req_already, req_set}
    reg  [ 2:0] inst_dirty_r;

    // req_valid：追踪 pre_if 握手是否有效
    //   req_set     → 置 0（新握手，下拍检查 cancel）
    //   !req_set && req_already && !s0_cancel → 置 1（确认有效）
    //   s0_cancel   → 保持/复位 0（被取消）
    reg  [ 1:0] req_valid;
    always @(posedge clk) begin
        if (reset)                      req_valid <= 2'b00;
        else if (req_set)               req_valid <= 2'b10;
        else if (req_valid == 2'b10) begin
            if (s0_cancel)              req_valid <= 2'b01;
            else                        req_valid <= 2'b00;
        end
    end

    // inst_dirty_control：从上一拍记录的条件计算
    //   req_set_r  → 与 s0_cancel（本拍 cancel 可使旧握手无效）
    //   req_already_r → 与 req_valid（状态机确认有效）
    wire pre_if_dirty_valid;
    assign pre_if_dirty_valid = (inst_dirty_ctrl_r[1] && !req_valid[0])
                        | (inst_dirty_ctrl_r[0] && !s0_cancel);
    assign inst_dirty_control = (inst_dirty_ctrl_r[2] && pre_if_dirty_valid) ? 3'b010 :
                                (inst_dirty_ctrl_r[2] || pre_if_dirty_valid) ? 3'b001 : 3'b000;

    always @(posedge clk) begin
        if (reset) begin
            inst_dirty_r <= 3'b0;
        end
        else if (icache_cpu_data_ok && (inst_dirty != 3'b0)) begin
            inst_dirty_r <= inst_dirty - 1'b1;
        end
        else begin
            inst_dirty_r <= inst_dirty;
        end

        if (reset) begin
            inst_dirty_ctrl_r <= 3'b0;
        end
        else begin
            inst_dirty_ctrl_r <= {cond_if, req_already, req_set};
        end
    end

    assign inst_dirty = s0_flush ? (inst_dirty_r + inst_dirty_control) : inst_dirty_r;

    // ========== ICache 输出信号 ==========
    assign if_to_mmu_vaddr = pre_if_pc_r;
    assign icache_cpu_req   = can_req && !req_already;
    assign icache_cpu_index  = pre_if_pc_r[`I_OFFSET_WIDTH +: `I_INDEX_WIDTH];
    assign icache_cpu_offset = pre_if_pc_r[0 +: `I_OFFSET_WIDTH];
    assign icache_cpu_accept = if_ready_go && lpower[1] || inst_dirty != 3'b0;
    assign if_inst           = icache_cpu_rdata;

    // ========== 检测异常（pre_if 仅 ADEF，TLB 异常在 IF 级合并） ==========
    assign pre_if_adef     = pre_if_pc_r[1:0] != 2'b00 && pre_if_valid;
    assign pre_if_exc      = {pre_if_adef, 3'b0};
    assign pre_if_exc_valid = pre_if_adef && pre_if_valid;

    assign if_exc_valid = |if_exc_r && if_valid;

    // ========== 输出给分支预测器 ==========
    assign if_pre_if_pc_next = pre_if_pc_next;

endmodule
