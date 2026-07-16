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
    // 输出给PRE_MEM阶段
    output wire                     ex_to_pre_mem_valid, // EX到PRE_MEM有效
    output wire [`EX_TO_PRE_MEM_BUS_WD-1:0] ex_to_pre_mem_bus, // EX到PRE_MEM总线
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
    input  wire                     pre_mem_ertn_flush  // PRE_MEM阶段有ertn指令
    );

    reg  ex_valid;                               // EX阶段有效标志
    wire ex_ready_go;                            // EX阶段就绪标志（除法指令需等待）
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

    // ========== 解析来自ID阶段的总线 ==========
    assign {
        `ifdef DIFFTEST_EN
        dift_csr_rstat_en,  // 412     csr estat读使能 for difftest
        dift_inst_st_en,    // 411:404 store使能 for difftest
        dift_inst_ld_en,    // 403:396 load使能 for difftest
        dift_cnt_inst,      // 395     计数器指令 for difftest
        dift_timer_64,      // 394:331 定时器值 for difftest
        dift_id_inst,       // 330:299 指令编码 for difftest
        `else
        _unused_diff_pad,   // 占位：保持非difftest字段bit位置不变
        `endif
        cacop_code,     // 298:294 cache操作类型
        cacop_en,       // 293     cache操作使能
        tlbsrch_en,     // 292     tlbsrch使能
        invtlb_en,      // 291     invtlb使能
        tlbrd_en,       // 290     tlbrd使能
        tlbwr_en,       // 289     tlbwf使能
        tlbfill_en,     // 288
        ex_rf_valid,    // 287     重取指标志
        timer_high,     // 286     使用计数器高32位
        res_from_timer, // 285     结果来自计数器
        res_from_csr,   // 284:    结果来自csr寄存器堆
        ex_csr_num,     // 283:270 csr号码
        csr_rvalue,     // 269:238 csr读数据
        csr_we,         // 237     csr写使能
        csr_wmask,      // 236:205 csr写掩码
        csr_wvalue,     // 204:173 csr写数据
        ertn_flush,     // 172    异常返回冲刷信号
        ex_exc[12:3],   // 171:162 异常类型
        res_from_mem,   // 161   结果来源（存储器/ALU）
        ex_pc,          // 160:129 指令PC
        rkd_value,      // 128:97 源操作数2（寄存器或立即数）
        rj_value,       // 96:65 源操作数1（寄存器值）
        imm,            // 64:33 立即数
        dest,           // 32:28 目标寄存器号
        mem_sign_ext,   // 27    符号扩展标志
        mem_size,       // 26:24 访存大小
        mem_we,         // 23    存储器写使能
        gr_we,          // 22    寄存器写使能
        src2_is_imm,    // 21    操作数2来源（立即数/寄存器）
        src1_is_pc,     // 20    操作数1来源（PC/寄存器）
        ex_load_op,     // 19    加载指令标志
        alu_op          // 18:0  ALU操作码
    } = id_to_ex_bus_r;

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
    assign ex_ready_go   = is_mul_inst ? (mul_ready || mul_ready_r) || (!ex_valid || ex_flush_pending) :
                           is_div_inst ? (div_ready || div_ready_r) || (!ex_valid || ex_flush_pending) :
                           1'b1;
    assign ex_allowin    = !ex_valid || ex_ready_go && pre_mem_allowin;
    assign ex_to_pre_mem_valid = ex_valid && ex_ready_go;

    // 执行级有效标志更新
    always @(posedge clk) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            ex_valid <= 1'b0;
        end
        else if (ex_allowin) begin
            ex_valid <= id_to_ex_valid;
        end
    end
    // 执行级数据传递
    always @(posedge clk) begin
        if (id_to_ex_valid && ex_allowin) begin
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
        if (reset || (ex_to_pre_mem_valid && pre_mem_allowin)) begin
            div_ready_r <= 1'b0;
        end
        else if (div_ready) begin
            div_ready_r <= 1'b1;
        end
    end

    // 乘法就绪信号需要寄存（复用除法器模式）
    always @(posedge clk) begin
        if (reset || (ex_to_pre_mem_valid && pre_mem_allowin)) begin
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