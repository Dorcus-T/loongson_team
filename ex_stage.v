`include "mycpu.h"

module exe_stage (
    // 时钟与复位
    input  wire        clk,              // 时钟信号
    input  wire        reset,            // 复位信号（高有效）
    // allowin
    input  wire        mem_allowin,      // MEM阶段允许接收
    output wire        ex_allowin,       // EX阶段允许接收
    // 来自ID阶段
    input  wire        id_to_ex_valid,   // ID到EX有效
    input  wire [`ID_TO_EX_BUS_WD-1:0] id_to_ex_bus, // 来自ID的控制信号和操作数
    // 输出给MEM阶段
    output wire        ex_to_mem_valid,  // EX到MEM有效
    output wire [`EX_TO_MEM_BUS_WD-1:0] ex_to_mem_bus, // EX到MEM总线
    // 访问MMU信号
    output wire [31:0] ex_to_mmu_vaddr,  // 虚地址输出
    output wire [35:0] vtlb_enop,        // {tlbsrch_valid, invtlb_valid, invtlb_op, invtlb_asid, invtlb_vaddr}
    output wire [ 1:0] ld_and_str,       // 输出操作是load还是store
    input  wire [31:0] padd,             // MMU物理地址返回
    input  wire [ 5:0] srch_value,       // {s1_found, index}
    input  wire [ 4:0] mem_tlb_exc,      // MMU返回tlb异常
    // 与数据存储器交互
    output wire        data_sram_req,    // 数据SRAM请求
    output wire        data_sram_wr,     // 数据SRAM写使能
    output wire [ 1:0] data_sram_size,   // 数据SRAM访问长度
    output wire [ 3:0] data_sram_wstrb,  // 数据SRAM写掩码
    output wire [31:0] data_sram_addr,   // 数据SRAM地址
    output wire [31:0] data_sram_wdata,  // 数据SRAM写数据
    input  wire        data_sram_addr_ok,// 数据SRAM握手信号
    // 前递控制
    output wire [ 4:0] ex_to_id_dest,    // EX阶段写回寄存器号
    output wire [31:0] ex_to_id_result,  // EX阶段计算结果
    output wire        ex_to_id_load_op, // EX阶段是否是加载指令
    output wire        ex_exc_valid,     // EX阶段存在异常
    // 异常冲刷
    input  wire        wb_exc_valid,     // WB阶段存在异常，冲刷流水线
    input  wire        wb_ertn_flush,    // WB阶段有ertn指令则冲刷流水线
    input  wire        mem_exc_valid,    // MEM阶段存在异常，防止访存
    input  wire        mem_ertn_flush,   // 防止ertn位于mem时,ex发出访存请求
    // CSR与ERTN冒险
    output wire        ex_csr_we,        // ex阶段确定要写csr
    output wire [13:0] ex_csr_num,       // ex阶段写csr的号码
    output wire        ex_ertn_flush,    // ex阶段为ertn指令
    // 读取计数器
    input  wire [63:0] timer_value       // 计数器数值
);

    reg  ex_valid;                               // EX阶段有效标志
    wire ex_ready_go;                            // EX阶段就绪标志（除法指令需等待）
    reg  [`ID_TO_EX_BUS_WD-1:0] id_to_ex_bus_r;  // 锁存的译码级数据

    // ========== 异常信号 ==========
    wire fpe;
    wire adem;
    wire ale;
    wire [12:0] ex_exc;
    wire [15:0] mem_exc;
    wire [ 4:0] valid_mem_tlb_exc;
    wire        ex_rf_valid;     // EX阶段重取指标志
    wire        ex_inst_valid;   // 判断指令能否正常起效
    wire [31:0] result_or_badv;  // 若取指阶段为tlb相关异常，替换为pc

    // ========== 控制信号解析 ==========
    wire [31:0] final_csr_wmask;
    wire [31:0] final_csr_wvalue;
    wire tlbsrch_en;                    // EXE访问tlb进行查找
    wire invtlb_en;                     // EXE访问tlb进行选中无效
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
    wire [2:0] mem_size;                // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                  // 符号扩展标志
    wire is_div_inst;                   // 判断是否为除法指令，控制流水线前进
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
    // 实现类SRAM总线
    wire is_mem_inst;                   // 是访存指令
    reg  req_already;                   // 已经发送过访存请求

    // ========== 解析来自ID阶段的总线 ==========
    assign {
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

    // ========== 输出到MEM阶段的总线 ==========
    assign ex_to_mem_bus = {
        tlbrd_en,              // 241     tlbrd使能
        tlbwr_en,              // 240     tlbwf使能
        tlbfill_en,            // 239
        ex_rf_valid,           // 238     重取指标志
        is_mem_inst,           // 237     是访存指令
        timer_finalval,        // 236:205 筛选后的计数器数据
        res_from_timer,        // 204     结果来自计数器
        res_from_csr,          // 203     结果来自csr寄存器堆
        ex_csr_num,            // 202:189 csr号码
        csr_rvalue,            // 188:157 csr读数据
        csr_we,                // 156     csr写使能
        final_csr_wmask,       // 155:124 csr写掩码
        final_csr_wvalue,      // 123:92  csr写数据
        ertn_flush,            // 91      异常返回冲刷信号
        mem_exc,               // 90:75   异常类型
        res_from_mem,          // 74      结果来源
        mem_sign_ext,          // 73      符号扩展标志
        mem_size,              // 72:70   访存大小
        gr_we,                 // 69      寄存器写使能
        dest,                  // 68:64   目标寄存器号
        result_or_badv,        // 63:32   ALU计算结果
        ex_pc                  // 31:0    PC
    };

    // ========== 流水线控制 ==========
    assign ex_inst_valid = ex_valid && !mem_exc_valid && !ex_exc_valid && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid;
    assign is_div_inst   = |alu_op[18:15];                    // 判断是否是除法/取模指令（ALU操作码15-18位非零）
    assign ex_ready_go   = is_div_inst ? (div_ready || div_ready_r) || (!ex_valid || |ex_exc[12:3] || mem_ertn_flush || mem_exc_valid || wb_ertn_flush || wb_exc_valid) :
                                        ex_valid && (mem_we || res_from_mem) && !(|mem_exc || ex_rf_valid) ? (data_sram_req && data_sram_addr_ok) || req_already : 1'b1;
    // 如果是除法指令，要么正确握手并且算完了发出ready信号，要么由于后面有异常和ertn导致除法指令不发出除法请求就直接走
    // 如果是访存指令，就必须发出访存请求之后才能往后走
    // ex阶段的异常中除了ale异常都不应该发出除法请求，不能添加ale，因为ale异常依赖alu结果，alu结果依赖除法结果，除法结果又依赖异常判断形成闭环，虽然二者互斥但是不能有闭环
    assign ex_allowin    = !ex_valid || ex_ready_go && mem_allowin;
    assign ex_to_mem_valid = ex_valid && ex_ready_go;

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

    // ========== 实现类sram总线 ==========
    always @(posedge clk) begin
        if (reset || (ex_ready_go && mem_allowin)) begin
            req_already <= 1'b0;
        end
        else if ((data_sram_req && data_sram_addr_ok) && !(ex_ready_go && mem_allowin)) begin
            req_already <= 1'b1;
        end
    end
    //指令往后走就清零，指令发请求且不往后走就置1。ex中的指令不存在preif中的因为冲刷和brtaken而立马变化，ex中的指令只会从id中来，如果阻塞指令就一定不变
    assign is_mem_inst = (mem_we || res_from_mem);

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
        .ex_valid       (ex_valid),
        .ex_exc         (ex_exc[12:3]),
        .mem_exc_valid  (mem_exc_valid),
        .mem_ertn_flush (mem_ertn_flush),
        .wb_ertn_flush  (wb_ertn_flush),
        .wb_exc_valid   (wb_exc_valid)
    );

    // 除法就绪信号需要寄存
    always @(posedge clk) begin
        if (reset || (ex_to_mem_valid && mem_allowin)) begin
            div_ready_r <= 1'b0;
        end
        else if (div_ready) begin
            div_ready_r <= 1'b1;
        end
    end

    // ========== 访问MMU信号逻辑 ==========
    assign ex_to_mmu_vaddr = alu_result;
    assign vtlb_enop = {
        tlbsrch_en,
        ex_valid && !mem_exc_valid && !(|ex_exc[12:3]) && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid ? invtlb_en : 1'b0,
        dest,
        rj_value[9:0],
        rkd_value[31:13]
    };
    assign final_csr_wmask  = tlbsrch_en && srch_value[5] ? 32'h8000001f : csr_wmask;
    assign final_csr_wvalue = tlbsrch_en && srch_value[5] ? {27'b0,srch_value[4:0]} : csr_wvalue;
    assign ld_and_str       = {ex_load_op, mem_we} & {2{ex_valid}};

    // ========== 数据存储器写控制 ==========
    assign data_sram_req   = ex_valid && (!mem_exc_valid && !(|mem_exc || ex_rf_valid) && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid) && !req_already && (mem_we || res_from_mem);
    // 只有访存指令，且是有效指令,并且mem和ex和wb阶段无异常、不是ertn,之前没发送过请求的指令才能发送访存请求
    assign data_sram_wr    = mem_we && ex_valid && (!mem_exc_valid && !(|mem_exc || ex_rf_valid) && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid);
    assign data_sram_size  = mem_size[0] ? 2'b00 :
                             mem_size[1] ? 2'b01 :
                             2'b10;
    assign data_sram_wstrb = mem_size[0] ? (4'b0001 << alu_result[1:0]) :          // 字节访问
                             mem_size[1] ? (alu_result[1] ? 4'b1100 : 4'b0011) :   // 半字访问
                             4'b1111;                                              // 字访问
    assign data_sram_addr  = padd;                                                 // 地址
    assign data_sram_wdata = mem_size[0] ? {4{rkd_value[7:0]}} :                   // 字节：4份
                             mem_size[1] ? {2{rkd_value[15:0]}} :                  // 半字：2份
                             rkd_value;                                            // 字：原值

    // ========== 前递输出 ==========
    assign ex_to_id_dest    = dest & {5{ex_valid}} & {5{gr_we}};
    assign ex_to_id_result  = res_from_csr ? csr_rvalue :
                              alu_result;                  // 计算结果
    assign ex_to_id_load_op = ex_load_op & ex_valid;       // 加载指令标志

    // ========== 检测异常与ertn ==========
    assign fpe  = 1'b0;                                           // 基础浮点指令例外//占位
    assign adem = 1'b0;                                           // 访存指令地址错例外//占位
    assign ale  = (ex_valid && (ex_load_op || mem_we)) &&         // 有效的访存指令,load_op本用来表示为ld指令用于处理ld-use数据冒险，这里复用该信号
                 ((mem_size[1] && (alu_result[0] != 1'b0)) ||     // 半字访问，地址bit0≠0
                  (mem_size[2] && (alu_result[1:0] != 2'b00)));   // 字访问，地址bit1:0≠00
    assign ex_exc[2:0]       = {fpe, adem, ale};
    assign valid_mem_tlb_exc = mem_tlb_exc & {5{!ex_exc_valid && ex_valid && ld_and_str != 2'b0}};
    assign mem_exc           = {ex_exc[12:11], ex_exc[10] || valid_mem_tlb_exc[4], ex_exc[9], ex_exc[8] || valid_mem_tlb_exc[3], ex_exc[7:0], valid_mem_tlb_exc[2:0]};
    // 将要送往mem阶段的全部例外
    assign ex_exc_valid  = (|ex_exc || ex_rf_valid) && ex_valid;
    assign ex_ertn_flush = ertn_flush && ex_valid;                // ex阶段的ertn要在指令有效的时候才能发挥作用
    assign result_or_badv = (!ex_exc[11] && |ex_exc[10:8]) ? ex_pc : alu_result;
endmodule