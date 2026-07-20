`include "mycpu.h"

module exe_stage (
    // 时钟与复位
    input  wire                     clk,                // 时钟信号
    input  wire                     reset,              // 复位信号（高有效）
    // allowin
    input  wire                     pre_mem_allowin,    // PRE_MEM阶段允许接收
    output wire                     ex_allowin,         // EX阶段允许接收
    // 来自ID阶段
    input  wire                     id_to_ex_valid,     // ID到EX有效
    input  wire [`ID_TO_EX_BUS_WD-1:0] id_to_ex_bus,    // 来自ID的控制信号和操作数
    input  wire                     id_ready_go,         // ID阶段就绪标志
    // 输出给PRE_MEM阶段
    output wire                     ex_to_pre_mem_valid, // EX到PRE_MEM有效
    output wire [`EX_TO_PRE_MEM_BUS_WD-1:0] ex_to_pre_mem_bus, // EX到PRE_MEM总线
    output wire                     ex_ready_go,         // EX阶段就绪标志
    // 前递控制
    output wire [ 4:0]              ex_to_id_dest,      // EX阶段写回寄存器号
    output wire [31:0]              ex_to_id_result,    // EX阶段计算结果
    output wire                     ex_to_id_load_op,   // EX阶段是否是加载指令
    output wire                     ex_exc_valid,       // EX阶段存在异常（不含TLB）
    // 异常冲刷
    input  wire                     wb_exc_valid,       // WB阶段存在异常，冲刷流水线
    input  wire                     wb_ertn_flush,      // WB阶段有ertn指令则冲刷流水线
    input  wire                     mem_exc_valid,      // MEM阶段存在异常
    input  wire                     mem_ertn_flush,     // MEM阶段有ertn指令
    input  wire                     pre_mem_exc_valid,  // PRE_MEM阶段存在异常（用于除/乘法放行）
    // CSR与ERTN冒险
    output wire                     ex_csr_we,          // ex阶段确定要写csr
    output wire [13:0]              ex_csr_num,         // ex阶段写csr的号码
    output wire                     ex_ertn_flush,      // ex阶段为ertn指令
    // 读取计数器
    input  wire [63:0]              timer_value,        // 计数器数值
    // PRE_MEM 级 ertn（用于 div/mul 放行）
    input  wire                     pre_mem_ertn_flush,  // PRE_MEM阶段有ertn指令
    // 预测器更新接口（输出 → branch_predict，由 EX 统一驱动）
    output wire                     bp_update_en,
    output wire [29:0]              bp_update_pc,
    output wire                     bp_update_is_branch,
    output wire [ 1:0]              bp_update_br_type,
    output wire                     bp_update_taken,
    output wire [29:0]              bp_update_target,
    output wire [ 4:0]              bp_update_btb_index,
    output wire                     bp_update_push_ras,
    output wire [29:0]              bp_update_ras_data,
    output wire                     bp_update_pop_ras,
    output wire                     bp_update_delete_entry,
    // 误预测输出
    output wire                     ex_mispredict,
    output wire [31:0]              ex_corr_target,
    // 性能计数
    output wire                     pred_event,         // 预测事件（一拍脉冲）
    output wire                     mispred_event       // 预测错误事件（一拍脉冲）
    );

    reg  ex_valid;                               // EX阶段有效标志
    reg  [`ID_TO_EX_BUS_WD-1:0] id_to_ex_bus_r;  // 锁存的译码级数据

    // ========== 异常信号 ==========
    wire [12:0] ex_exc;
    wire        ex_rf_valid;     // EX阶段重取指标志

    // ========== 控制信号解析 ==========
    wire tlbsrch_en;                    // 透传
    wire invtlb_en;                     // 透传
    wire tlbrd_en;                      // WB读tlb并写csr
    wire tlbwr_en;                      // tlbwrWB写tlb
    wire tlbfill_en;                    // tlbfillWB写tlb
    wire [18:0] alu_op;                 // ALU操作码
    wire ex_load_op;                    // 加载指令标志
    wire src1_is_pc;                    // 源操作数1是否来自PC
    wire src2_is_imm;                   // 源操作数2是否立即数
    wire res_from_mem;                  // 结果是否来自存储器
    wire timer_high;                    // 使用计数器高32位
    wire gr_we;                         // 通用寄存器写使能
    wire mem_we;                        // 存储器写使能
    wire [4:0] dest;                    // 目标寄存器号
    wire [31:0] rj_value;               // 源操作数1（来自寄存器）
    wire [31:0] rkd_value;              // 源操作数2（来自寄存器或立即数）
    wire [31:0] imm;                    // 立即数
    wire [31:0] ex_pc;                  // 当前指令PC
    wire ertn_flush;                    // 异常返回冲刷信号
    wire div_ready;                     // 除法器就绪脉冲信号
    reg  div_ready_r;                   // 寄存除法结果就绪脉冲信号
    wire mul_ready;                     // 乘法器就绪脉冲信号
    reg  mul_ready_r;                   // 寄存乘法结果就绪脉冲信号
    wire [2:0] mem_size;                // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                  // 符号扩展标志
    wire is_div_inst;                   // 判断是否为除法指令，控制流水线前进
    wire is_mul_inst;                   // 判断是否为乘法指令，控制流水线前进
    // ALU操作数
    wire [31:0] alu_src1;
    wire [31:0] alu_src2;
    wire [31:0] alu_result;
    // CSR交互信号
    wire        res_from_csr;           // 结果来自csr寄存器堆
    wire [31:0] csr_rvalue;             // csr读数据
    wire        csr_we;                 // csr写使能
    wire [31:0] csr_wmask;              // csr写掩码
    wire [31:0] csr_wvalue;             // csr写数据
    // 计数器数值筛选
    wire        res_from_timer;         // 结果来自计数器
    wire [31:0] timer_finalval;         // 筛选后的计数器读取数据
    // cacop 透传信号
    wire [4:0]  cacop_code;             // cache操作类型
    wire        cacop_en;               // cache操作使能
    // 预测透传信号（从ID→EX总线解析）
    wire        ex_pred_valid;          // 预测有效
    wire        ex_pred_taken;          // 预测方向
    wire [29:0] ex_pred_target;         // 预测目标 PC[31:2]
    wire        ex_pred_is_ras;         // RAS预测
    wire [ 4:0] ex_pred_btb_index;      // BTB命中索引
    wire [ 3:0] ex_pred_ras_index;      // RAS命中索引
    wire [ 1:0] ex_br_type;             // 分支类型
    wire [ 2:0] ex_cond_cmp;            // 条件分支比较码
    wire [31:0] ex_br_offs;             // 分支偏移量（已符号扩展+左移2位，直接可用）
    wire        ex_is_branch;           // 是否为分支指令

    `ifdef DIFFTEST_EN
    // difftest 信号
    wire        dift_csr_rstat_en;
    wire [ 7:0] dift_inst_st_en;
    wire [ 7:0] dift_inst_ld_en;
    wire        dift_cnt_inst;
    wire [63:0] dift_timer_64;
    wire [31:0] dift_id_inst;
    `else
    // 占位 dummy wire（保持总线位宽不变）
    wire [113:0] _unused_diff_pad;
    `endif

    // ========== 解析来自ID阶段的总线（493 bit）==========
    assign {
        `ifdef DIFFTEST_EN
        dift_csr_rstat_en,  // 476     csr estat读使能 for difftest
        dift_inst_st_en,    // 475:468 store使能 for difftest
        dift_inst_ld_en,    // 467:460 load使能 for difftest
        dift_cnt_inst,      // 459     计数器指令 for difftest
        dift_timer_64,      // 458:395 定时器值 for difftest
        dift_id_inst,       // 394:363 指令编码 for difftest
        `else
        _unused_diff_pad,   // 占位：保持非difftest字段bit位置不变
        `endif
        cacop_code,     // 362:358 cache操作类型
        cacop_en,       // 357     cache操作使能
        tlbsrch_en,     // 356     tlbsrch使能
        invtlb_en,      // 355     invtlb使能
        tlbrd_en,       // 354     tlbrd使能
        tlbwr_en,       // 353     tlbwf使能
        tlbfill_en,     // 352
        ex_rf_valid,    // 351     重取指标志
        timer_high,     // 350     使用计数器高32位
        res_from_timer, // 349     结果来自计数器
        res_from_csr,   // 348     结果来自csr寄存器堆
        ex_csr_num,     // 347:334 csr号码
        csr_rvalue,     // 333:302 csr读数据
        csr_we,         // 301     csr写使能
        csr_wmask,      // 300:269 csr写掩码
        csr_wvalue,     // 268:237 csr写数据
        ertn_flush,     // 236     异常返回冲刷信号
        ex_exc[12:3],   // 235:226 异常类型
        res_from_mem,   // 225     结果来源（存储器/ALU）
        ex_pc,          // 224:193 指令PC
        rkd_value,      // 192:161 源操作数2（寄存器或立即数）
        rj_value,       // 160:129 源操作数1（寄存器值）
        imm,            // 128:97  立即数
        dest,           // 96:92   目标寄存器号
        mem_sign_ext,   // 91      符号扩展标志
        mem_size,       // 90:88   访存大小
        mem_we,         // 87      存储器写使能
        gr_we,          // 86      寄存器写使能
        src2_is_imm,    // 85      操作数2来源（立即数/寄存器）
        src1_is_pc,     // 84      操作数1来源（PC/寄存器）
        ex_load_op,     // 83      加载指令标志
        alu_op,         // 82:64   ALU操作码
        // 预测透传
        ex_pred_valid,      // 63      预测有效
        ex_pred_taken,      // 62      预测方向
        ex_pred_target,     // 61:32   预测目标 PC[31:2]
        ex_pred_is_ras,     // 31      RAS预测
        ex_pred_btb_index,  // 30:26   BTB命中索引
        ex_pred_ras_index,  // 25:22   RAS命中索引
        ex_br_type,         // 37:36   分支类型
        ex_cond_cmp,        // 35:33   条件分支比较码
        ex_br_offs,         // 32:1    分支偏移量（已符号扩展+左移2位）
        ex_is_branch        // 0       是否为分支指令
    } = id_to_ex_bus_r;

    // ============================================================
    // EX 级统一分支验证与预测器训练
    // ============================================================
    // ex_br_offs 已由 ID 计算好（符号扩展+左移2位），覆盖 B/BL 的 26 位 offs 和条件/JIRL 的 16 位 offs

    // -------- 条件分支：用 rj_value / rkd_value 重算比较结果 --------
    wire ex_rj_eq_rd;
    assign ex_rj_eq_rd = (rj_value == rkd_value);

    wire [31:0] ex_adder_result;
    wire        ex_adder_cout;
    assign {ex_adder_cout, ex_adder_result} = {1'b0, rj_value} + {1'b0, ~rkd_value} + 1'b1;
    wire ex_rj_lt_rd_s;
    assign ex_rj_lt_rd_s = (rj_value[31] && ~rkd_value[31])
                         | ((rj_value[31] ~^ rkd_value[31]) && ex_adder_result[31]);
    wire ex_rj_lt_rd_u;
    assign ex_rj_lt_rd_u = !ex_adder_cout;

    wire ex_cond_taken;
    assign ex_cond_taken = (ex_cond_cmp == 3'b000) ?  ex_rj_eq_rd     // BEQ
                         : (ex_cond_cmp == 3'b001) ? !ex_rj_eq_rd     // BNE
                         : (ex_cond_cmp == 3'b010) ?  ex_rj_lt_rd_s   // BLT
                         : (ex_cond_cmp == 3'b011) ? !ex_rj_lt_rd_s   // BGE
                         : (ex_cond_cmp == 3'b100) ?  ex_rj_lt_rd_u   // BLTU
                         : (ex_cond_cmp == 3'b101) ? !ex_rj_lt_rd_u   // BGEU
                         : 1'b0;

    // -------- 实际分支方向（按 br_type 决定）--------
    wire ex_br_taken_actual;
    assign ex_br_taken_actual = (ex_br_type == 2'b10) ? 1'b1 :           // BL/call 一定跳
                                (ex_br_type == 2'b11) ? 1'b1 :           // ret 一定跳
                                (ex_br_type == 2'b00) ? 1'b1 :           // B/JIRL call 一定跳
                                (ex_br_type == 2'b01) ? ex_cond_taken :  // 条件分支
                                1'b0;

    // -------- 实际分支目标 --------
    // JIRL 是唯一的寄存器相对分支（rj + offset），其余全是 PC 相对
    // JIRL call: br_type=00 且 src1_is_pc=1（B 的 src1_is_pc=0，可区分）
    // JIRL ret:  br_type=11
    wire ex_is_jirl;
    assign ex_is_jirl = (ex_br_type == 2'b11) || (ex_br_type == 2'b00 && src1_is_pc);

    wire [31:0] ex_br_target_actual;
    assign ex_br_target_actual = ex_is_jirl ? (rj_value + ex_br_offs)   // JIRL
                                           : (ex_pc + ex_br_offs);      // B/BL/条件分支

    // -------- 原始误预测检测（覆盖冷启动 + 方向错 + 目标错）--------
    // 有效预测 = pred_valid && pred_taken；无预测时视为"不跳"（顺序取指）
    // 方向错 = 实际方向 ≠ (预测有效且预测跳转)
    wire ex_mispredict_raw;
    assign ex_mispredict_raw = ex_is_branch && ex_valid && (
        (ex_br_taken_actual != (ex_pred_valid && ex_pred_taken))           // 方向错（含冷启动：无预测→视为不跳）
        || (ex_br_taken_actual && ex_pred_valid
            && (ex_pred_target != ex_br_target_actual[31:2]))              // 目标错（仅预测为跳时才检查）
    );

    // -------- 原始预测器训练使能 --------
    wire bp_update_en_raw;
    assign bp_update_en_raw = ex_is_branch && ex_valid;

    // ============================================================
    // One-shot：防止分支指令在 EX 停顿时重复发出 mispredict/update
    //   类似原 ID 级 new_br：新指令进 EX 时清零，分支信号发出后置位
    //   对外输出 = raw && !ex_branch_fired
    //   内部保护门控（ex_valid / id_to_ex_bus_r）用 raw 信号
    // ============================================================
    reg ex_branch_fired;

    always @(posedge clk) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            ex_branch_fired <= 1'b0;
        end
        else if (ex_allowin) begin
            // 新指令进入 EX → 复位 one-shot
            ex_branch_fired <= 1'b0;
        end
        else if (ex_mispredict_raw) begin
            // 误预测分支本拍发出了信号 → 置位，阻止后续重复
            ex_branch_fired <= 1'b1;
        end
    end

    // 对外输出（经过 one-shot 门控）
    assign ex_mispredict  = ex_mispredict_raw && !ex_branch_fired;
    assign ex_corr_target = ex_br_taken_actual ? ex_br_target_actual
                                               : (ex_pc + 32'h4);

    assign bp_update_en   = bp_update_en_raw && !ex_branch_fired;

    // 预测事件：无条件分支 + 预测有效（已通过 bp_update_en 的 one-shot 保证只计一次）
    assign pred_event   = bp_update_en && ex_pred_valid;// && (ex_br_type != 2'b01);
    // 预测错误事件：仅统计无条件分支中有预测的误预测，排除冷启动和条件分支
    assign mispred_event = ex_mispredict && ex_pred_valid;// && (ex_br_type != 2'b01);

    // 以下 bp_update 数据信号无需单独门控——bp_update_en=0 时 branch_predict 忽略全部
    assign bp_update_pc      = ex_pc[31:2];
    assign bp_update_is_branch = ex_is_branch;
    assign bp_update_br_type = ex_br_type;
    assign bp_update_taken   = ex_br_taken_actual;
    assign bp_update_target  = ex_br_target_actual[31:2];

    // BTB 更新索引：命中时用命中索引，miss 时由 branch_predict 内部 PLRU 决定
    assign bp_update_btb_index = ex_pred_valid ? ex_pred_btb_index : 5'd0;

    // RAS 操作
    assign bp_update_push_ras    = (ex_br_type == 2'b10) && ex_br_taken_actual;  // BL 跳转时 push
    assign bp_update_ras_data    = (ex_pc[31:2] + 30'd1);  // 返回地址 = BL_PC+4 的 [31:2]
    assign bp_update_pop_ras     = (ex_br_type == 2'b11);  // JIRL ret 时 pop

    // 预测跳转但实际不是分支 → 删除脏 BTB 项
    wire ex_not_branch_mispredict;
    assign ex_not_branch_mispredict = ex_pred_valid && ex_pred_taken && !ex_is_branch && ex_valid;
    assign bp_update_delete_entry = ex_not_branch_mispredict;

    `ifdef DIFFTEST_EN
    wire [31:0] diff_vaddr;         // load/store虚地址 for difftest
    wire [31:0] diff_st_data;       // store数据 for difftest
    assign diff_vaddr  = alu_result;
    assign diff_st_data = rkd_value;
    `endif

    // ========== 输出到PRE_MEM阶段的总线 ==========
    // 比 EX→MEM 多 6 bit（cacop_code + cacop_en）；PRE_MEM 负责 TLB 异常合并 + CSR 字段最终化
    assign ex_to_pre_mem_bus = {
        cacop_code,            // 489:485 cache操作类型（PRE_MEM 消费）
        cacop_en,              // 484     cache操作使能（PRE_MEM 消费）
        rj_value,              // 521:490 源操作数1（PRE_MEM 用于 vtlb_enop ASID）
        rkd_value,             // 490:459 源操作数2（PRE_MEM 用于 dcache_wdata / vtlb_enop VPPN）
        ex_load_op,            // 458     加载指令标志（PRE_MEM 用于 ALE 检测 / ld_and_str）
        `ifdef DIFFTEST_EN
        csr_rvalue,            // 451:420 csr读数据 for difftest
        dift_csr_rstat_en,     // 420     csr estat读使能 for difftest
        dift_inst_st_en,       // 419:412 store使能 for difftest
        dift_inst_ld_en,       // 411:404 load使能 for difftest
        dift_cnt_inst,         // 403     计数器指令 for difftest
        dift_timer_64,         // 402:339 定时器值 for difftest
        dift_id_inst,          // 338:307 指令编码 for difftest
        diff_vaddr,            // 306:275 load/store虚地址 for difftest
        diff_st_data,          // 274:243 store数据 for difftest
        `else
        210'd0,                // 占位：保持非difftest字段bit位置不变
        `endif
        tlbsrch_en,            // 244     tlbsrch使能（PRE_MEM 用于 vtlb_enop + tlb_wait）
        invtlb_en,             // 243     invtlb使能（PRE_MEM 用于 vtlb_enop）
        tlbrd_en,              // 242     tlbrd使能
        tlbwr_en,              // 241     tlbwf使能
        tlbfill_en,            // 240
        ex_rf_valid,           // 239     重取指标志
        mem_we,                // 238     存储器写使能（is_mem_inst 由 PRE_MEM 计算，不再占位）
        timer_finalval,        // 236:205 筛选后的计数器数据
        res_from_timer,        // 204     结果来自计数器
        res_from_csr,          // 203     结果来自csr寄存器堆
        ex_csr_num,            // 202:189 csr号码
        csr_rvalue,            // 188:157 csr读数据
        csr_we,                // 156     csr写使能
        csr_wmask,             // 155:124 csr写掩码（原值，PRE_MEM 负责 tlbsrch 改写）
        csr_wvalue,            // 123:92  csr写数据（原值，PRE_MEM 负责 tlbsrch 改写）
        ertn_flush,            // 91      异常返回冲刷信号
        {3'b0, ex_exc[12:0]},  // 90:75   异常类型（EX 自身异常，PRE_MEM 负责 TLB 合并）
        res_from_mem,          // 74      结果来源
        mem_sign_ext,          // 73      符号扩展标志
        mem_size,              // 72:70   访存大小
        gr_we,                 // 69      寄存器写使能
        dest,                  // 68:64   目标寄存器号
        alu_result,            // 63:32   ALU计算结果（PRE_MEM 负责 result_or_badv 替换）
        ex_pc                  // 31:0    PC
    };

    // ========== 流水线控制 ==========
    assign is_div_inst   = |alu_op[18:15];                    // 判断是否是除法/取模指令（ALU操作码15-18位非零）
    assign is_mul_inst   = |alu_op[14:12];                    // 判断是否是乘法指令（ALU操作码12-14位非零）
    // 下游异常/flush 时放行 EX：否则 EX 等 div/mul 但 div/mul 已终止 → 死锁
    wire ex_flush_pending;
    assign ex_flush_pending = ex_exc_valid || pre_mem_exc_valid || pre_mem_ertn_flush || mem_exc_valid || mem_ertn_flush || wb_ertn_flush || wb_exc_valid || ex_rf_valid;

    // 仅 div/mul 需等待；其余指令一拍过（访存/CACOP 握手已移至 PRE_MEM）
    assign ex_ready_go   = is_mul_inst ? mul_ready || mul_ready_r || !ex_valid || ex_flush_pending :
                           is_div_inst ? div_ready || div_ready_r || !ex_valid || ex_flush_pending :
                           1'b1;
    assign ex_allowin    = id_ready_go && ex_ready_go && (pre_mem_allowin || !ex_valid);
    assign ex_to_pre_mem_valid = ex_valid;

    // 执行级有效标志更新
    always @(posedge clk) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            ex_valid <= 1'b0;
        end
        else if (ex_allowin) begin
            ex_valid <= id_to_ex_valid && !ex_mispredict_raw;
        end
        else if (ex_ready_go && pre_mem_allowin) begin
            ex_valid <= 1'b0;
        end
    end
    // 执行级数据传递
    always @(posedge clk) begin
        if (ex_allowin) begin
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end


    // ========== csr写文件写回控制 ==========
    assign ex_csr_we = csr_we && ex_valid && !ex_exc_valid; //用于csr_stall判断

    // ========== 计数器筛选数据生成 ==========
    assign timer_finalval = timer_high ? timer_value[63:32] : timer_value[31:0];

    // ========== ALU操作数选择 ==========
    assign alu_src1 = src1_is_pc ? ex_pc : rj_value;    // 操作数1：PC或寄存器
    assign alu_src2 = src2_is_imm ? imm : rkd_value;    // 操作数2：立即数或寄存器

    // ALU实例化
    alu u_alu (
        .alu_op         (alu_op),
        .alu_src1       (alu_src1),
        .alu_src2       (alu_src2),
        .alu_result     (alu_result),
        .clk            (clk),
        .reset          (reset),
        .div_ready      (div_ready),
        .mul_ready      (mul_ready),
        .ex_valid       (ex_valid),
        .ex_exc         (ex_exc[12:3]),
        .mem_exc_valid  (mem_exc_valid),
        .mem_ertn_flush (mem_ertn_flush),
        .wb_ertn_flush  (wb_ertn_flush),
        .wb_exc_valid   (wb_exc_valid)
    );

    // 除法就绪信号需要寄存
    always @(posedge clk) begin
        if (reset || ex_allowin || wb_ertn_flush || wb_exc_valid) begin
            div_ready_r <= 1'b0;
        end
        else if (div_ready) begin
            div_ready_r <= 1'b1;
        end
    end

    // 乘法就绪信号需要寄存（复用除法器模式）
    always @(posedge clk) begin
        if (reset || ex_allowin || wb_ertn_flush || wb_exc_valid) begin
            mul_ready_r <= 1'b0;
        end
        else if (mul_ready) begin
            mul_ready_r <= 1'b1;
        end
    end

    // ========== 前递输出 ==========
    assign ex_to_id_dest    = dest & {5{ex_valid}} & {5{gr_we}};
    assign ex_to_id_result  = res_from_csr ? csr_rvalue :
                              alu_result;                  // 计算结果
    assign ex_to_id_load_op = ex_load_op & ex_valid;       // 加载指令标志

    // ========== 检测异常与ertn（EX 只透传 ID 异常，ALE 由 PRE_MEM 检测） ==========
    assign ex_exc[2:0]       = 3'b0;                               // ALE 移至 PRE_MEM
    assign ex_exc_valid  = (|ex_exc || ex_rf_valid) && ex_valid;
    assign ex_ertn_flush     = ertn_flush && ex_valid;            // ex阶段的ertn要在指令有效的时候才能发挥作用
endmodule