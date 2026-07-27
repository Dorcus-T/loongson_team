`include "mycpu.h"

module exe_stage (
    // 时钟与复位
    input  wire                     clk,                // 时钟信号
    input  wire                     reset,              // 复位信号（高有效）
    // 来自ID阶段
    input  wire                     id_to_ex_valid,     // ID到EX有效
    input  wire [`ID_TO_EX_BUS_WD-1:0] id_to_ex_bus,    // 来自ID的控制信号和操作数
    // 输出给PRE_MEM阶段
    output wire                     ex_to_pre_mem_valid, // EX到PRE_MEM有效
    output wire [`EX_TO_PRE_MEM_BUS_WD-1:0] ex_to_pre_mem_bus, // EX到PRE_MEM总线
    output wire                     ex_to_pre_mem_upd,  // EX→PRE_MEM 更新 data_n
    output wire                     ex_ready_go,         // EX阶段就绪标志
    // 前递控制
    output wire [ 4:0]              ex_to_id_dest,      // EX阶段写回寄存器号
    output wire [31:0]              ex_to_id_result,    // EX阶段计算结果
    output wire                     ex_to_id_load_op,   // EX阶段是否是加载指令
    // CSR与ERTN冒险
    output wire                     ex_csr_we,          // ex阶段确定要写csr
    output wire [13:0]              ex_csr_num,         // ex阶段写csr的号码
    // 读取计数器
    input  wire [63:0]              timer_value,        // 计数器数值
    // 误预测输出
    output wire                     ex_mispredict,
    output wire [31:0]              ex_corr_target,
    // 性能计数
    output wire                     pred_event,         // 预测事件（一拍脉冲）
    output wire                     mispred_event,      // 预测错误事件（一拍脉冲）

    // ── linectrl 接口 ──
    input  wire                     ldata,              // 0=用旧寄存器, 1=用新寄存器
    input  wire                     lvalid,             // 本拍可呈现数据
    input  wire                     lpower,             // 本拍有权发请求
    input  wire                     lready,             // 维持就绪
    input  wire                     upd,                // 上级已准备且有权力 → 更新 data_n

    output wire                     ex_valid_o,         // → linectrl valid_i
    output wire                     ex_exc_o,           // → linectrl exc_i
    output wire                     ex_ertn_o,          // → linectrl ertn_i
    output wire                     ex_mispred_o,       // → linectrl mispred_i

    // ── → ID：mul/div 未完成 ──
    output wire                     calc_not_ready      // ex 有效且为乘除且结果未就绪
    );

    wire ex_valid;                                  // 本拍有效 = (ldata? valid_n : valid_o) & lvalid
    wire ex_exc_valid;                              // 异常有效
    wire ex_ertn_flush;                             // ertn 冲刷

    // ========== 双寄存器结构 ==========
    reg  [`ID_TO_EX_BUS_WD-1:0] data_n;            // 新数据寄存器（upd 时捕获）
    reg                      valid_n;               // 新 valid
    reg  [`ID_TO_EX_BUS_WD-1:0] data_o;             // 旧数据寄存器
    reg                      valid_o;               // 旧 valid

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
    } = current_bus;

    // ========== 双寄存器逻辑 ==========

    // ── data_n: upd 时从上游捕获 ──
    always @(posedge clk) begin
        if (reset) begin
            data_n  <= `ID_TO_EX_BUS_WD'd0;
            valid_n <= 1'b0;
        end
        else if (upd) begin
            data_n  <= id_to_ex_bus;
            valid_n <= id_to_ex_valid;
        end
    end

    // ── data_o: ldata=1 且未准备时从 data_n 拷贝 ──
    always @(posedge clk) begin
        if (reset) begin
            data_o  <= `ID_TO_EX_BUS_WD'd0;
            valid_o <= 1'b0;
        end
        else begin
            if (ldata)  data_o  <= current_bus;
            valid_o <= (ldata ? valid_n : valid_o) & lvalid;
        end
    end

    // ── ldata 选通 ──
    wire [`ID_TO_EX_BUS_WD-1:0] current_bus;
    assign current_bus = ldata ? data_n : data_o;
    assign ex_valid    = (ldata ? valid_n : valid_o) & lvalid;

    wire can_req = ex_valid && lpower;

    // ── ready_go = work_done || !valid || lready ──
    wire work_done;

    // ── → linectrl ──
    assign ex_valid_o   = ex_valid;
    assign ex_exc_o     = ex_exc_valid;
    assign ex_ertn_o    = ex_ertn_flush;
    assign ex_mispred_o = ex_mispredict;

    // ── → PRE_MEM ──
    assign ex_to_pre_mem_valid = ex_valid;
    assign ex_to_pre_mem_upd   = (ex_ready_go && lpower) || !ex_valid;

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
    assign ex_mispredict_raw = ex_is_branch&& (
        (ex_br_taken_actual != (ex_pred_valid && ex_pred_taken))           // 方向错（含冷启动：无预测→视为不跳）
        || (ex_br_taken_actual && ex_pred_valid
            && (ex_pred_target != ex_br_target_actual[31:2]))              // 目标错（仅预测为跳时才检查）
    );

    // 对外输出（can_req 门控）
    assign ex_mispredict  = ex_mispredict_raw && can_req;
    assign ex_corr_target = ex_br_taken_actual ? ex_br_target_actual
                                               : (ex_pc + 32'h4);

    // ========== 分支预测器更新数据（组合逻辑，保留不动） ==========
    wire [29:0] bp_pc        = ex_pc[31:2];
    wire        bp_is_branch = ex_is_branch;
    wire [ 1:0] bp_br_type   = ex_br_type;
    wire        bp_taken     = ex_br_taken_actual;
    wire [29:0] bp_target    = ex_br_target_actual[31:2];
    wire [ 4:0] bp_btb_idx   = ex_pred_valid ? ex_pred_btb_index : 5'd0;
    wire        bp_push      = (ex_br_type == 2'b10) && ex_br_taken_actual;
    wire [29:0] bp_ras       = (ex_pc[31:2] + 30'd1);
    wire        bp_pop       = (ex_br_type == 2'b11);
    wire        bp_del       = ex_pred_valid && ex_pred_taken && !ex_is_branch && ex_valid;
    wire        bp_en_comb   = (ex_is_branch || bp_del) && can_req;

    wire pred_comb    = bp_en_comb && ex_pred_valid;
    wire mispred_comb = ex_mispredict && ex_pred_valid;

    // ========== 性能计数（组合输出） ==========
    assign pred_event    = pred_comb;
    assign mispred_event = mispred_comb;

    wire [`BP_BUS_WD-1:0] bp_bus_next;

    assign bp_bus_next = {
        bp_pc,          // 103:74
        bp_is_branch,   // 73
        bp_br_type,     // 72:71
        bp_taken,       // 70
        bp_target,      // 69:40
        bp_btb_idx,     // 39:35
        bp_push,        // 34
        bp_ras,         // 33:4
        bp_pop,         // 3
        bp_del          // 2
    };

    `ifdef DIFFTEST_EN
    wire [31:0] diff_vaddr;         // load/store虚地址 for difftest
    wire [31:0] diff_st_data;       // store数据 for difftest
    assign diff_vaddr  = alu_result;
    assign diff_st_data = rkd_value;
    `endif

    // ========== 输出到PRE_MEM阶段的总线 ==========
    assign ex_to_pre_mem_bus = {
        bp_en_comb,            // 627     分支预测更新使能（PRE_MEM 消费）
        bp_bus_next,           // 626:525 分支预测更新数据（PRE_MEM 消费）
        cacop_code,            // 524:520 cache操作类型（PRE_MEM 消费）
        cacop_en,              // 519     cache操作使能（PRE_MEM 消费）
        rj_value,              // 521:490 源操作数1（PRE_MEM 用于 vtlb_enop ASID）
        rkd_value,             // 490:459 源操作数2（PRE_MEM 用于 dcache_wdata / vtlb_enop VPPN）
        ex_load_op,            // 458     加载指令标志（PRE_MEM 用于 ALE 检测 / ld_and_str）
        `ifdef DIFFTEST_EN
        csr_rvalue,            // 451:420 csr读数据 for difftest
        dift_csr_rstat_en,     // 420     csr estat读使能 for difftest
        dift_inst_st_en,       // 419:412 store使能 for difftest
        dift_inst_ld_en,       // 411:404 load使能 for difftest
        dift_cnt_inst,         // 403     计数器指令 for difftest
        timer_value,           // 402:339 定时器值 for difftest（EX 直接提供）
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
        csr_rvalue_actual,     // 188:157 csr读数据（cpucfg用本地生成值）
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
    assign is_div_inst   = |alu_op[18:15];
    assign is_mul_inst   = |alu_op[14:12];

    assign work_done       = ex_exc_valid ? 1'b1                       :
                             is_mul_inst  ? (mul_ready || mul_already) :
                             is_div_inst  ? (div_ready || div_already) :
                             1'b1;
    assign ex_ready_go     = work_done || !ex_valid || lready;

    // ========== csr写文件写回控制 ==========
    assign ex_csr_we = csr_we && ex_valid;

    // ========== 计数器筛选数据生成 ==========
    assign timer_finalval = timer_high ? timer_value[63:32] : timer_value[31:0];

    // ========== ALU操作数选择 ==========
    assign alu_src1 = src1_is_pc ? ex_pc : rj_value;    // 操作数1：PC或寄存器
    assign alu_src2 = src2_is_imm ? imm : rkd_value;    // 操作数2：立即数或寄存器

    // ALU实例化
    alu u_alu (
        .alu_op     (alu_op),
        .alu_src1   (alu_src1),
        .alu_src2   (alu_src2),
        .alu_result (alu_result),
        .clk        (clk),
        .reset      (reset),
        .div_ready_o(div_ready),
        .mul_ready_o(mul_ready),
        .can_req    (can_req),
        .ldata      (ldata)
    );

    // 除法就绪信号需要寄存
    always @(posedge clk) begin
        if (reset || ldata)           div_ready_r <= 1'b0;
        else if (div_ready)           div_ready_r <= 1'b1;
    end

    wire div_already = div_ready_r & !ldata;

    // 乘法就绪信号需要寄存
    always @(posedge clk) begin
        if (reset || ldata)           mul_ready_r <= 1'b0;
        else if (mul_ready)           mul_ready_r <= 1'b1;
    end

    wire mul_already = mul_ready_r & !ldata;

    assign calc_not_ready = ex_valid && (is_mul_inst && !(mul_ready || mul_already) ||
                            is_div_inst && !(div_ready || div_already));

    // ========== cpucfg 数据通路（EX 本地计算，不走 CSR 模块） ==========
    wire       is_cpucfg  = res_from_csr && (ex_csr_num == 14'h00b1);
    wire [7:0] cfg_valen  = `VALEN - 1;
    wire [7:0] cfg_palen  = `PALEN - 1;
    wire [3:0] cfg_off    = `OFFSET_WIDTH;
    wire [7:0] cfg_idx    = `INDEX_WIDTH;
    wire [15:0] cfg_ways  = `WAY_NUM - 1;
    wire [31:0] cpucfg_rvalue =
        (rj_value[5:0] == 6'd1)  ? {12'd0, cfg_valen, cfg_palen, 1'b0, 1'b1, 2'd0} :
        (rj_value[5:0] == 6'd2)  ? 32'h0 :
        (rj_value[5:0] == 6'd16) ? {25'd0, 1'b0, 1'b0, 2'd0, 1'b1, 1'b0, 1'b1} :
        (rj_value[5:0] == 6'd17) ? {1'b0, 3'd0, cfg_off, cfg_idx, cfg_ways} :
        (rj_value[5:0] == 6'd18) ? {1'b0, 3'd0, cfg_off, cfg_idx, cfg_ways} :
        (rj_value[5:0] == 6'd19) ? 32'h0 : 32'h0;
    wire [31:0] csr_rvalue_actual = is_cpucfg ? cpucfg_rvalue : csr_rvalue;

    // ========== 前递输出 ==========
    assign ex_to_id_dest    = dest & {5{ex_valid}} & {5{gr_we}};
    assign ex_to_id_result  = res_from_csr ? csr_rvalue_actual :
                              res_from_timer ? timer_finalval :
                              alu_result;                  // 计算结果
    assign ex_to_id_load_op = ex_load_op & ex_valid;       // 加载指令标志

    // ========== 检测异常与ertn（EX 只透传 ID 异常，ALE 由 PRE_MEM 检测） ==========
    assign ex_exc[2:0]       = 3'b0;                               // ALE 移至 PRE_MEM
    assign ex_exc_valid  = (|ex_exc || ex_rf_valid) && ex_valid;
    assign ex_ertn_flush     = ertn_flush && ex_valid;            // ex阶段的ertn要在指令有效的时候才能发挥作用
endmodule