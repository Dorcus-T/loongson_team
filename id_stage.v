`include "mycpu.h"

module id_stage (
    input  wire                         clk,
    input  wire                         reset,
    // 来自IF阶段
    input  wire                         if_to_id_valid,      // IF到ID的有效标志
    input  wire [`IF_TO_ID_BUS_WD-1:0]  if_to_id_bus,        // IF传递的总线：{指令, PC}
    // 输出给ex阶段
    output wire                         id_to_ex_valid,      // ID到EX的有效标志
    output wire [`ID_TO_EX_BUS_WD-1:0]  id_to_ex_bus,        // ID到EX的控制总线
    (* max_fanout = 64 *) output wire   id_to_ex_upd,         // ID→EX 更新 data_n
    output wire                         id_ready_go,         // ID阶段就绪标志
    // wb阶段输入的寄存器文件总线
    input  wire [`WB_TO_RF_BUS_WD-1:0]  wb_to_rf_bus,        // WB阶段写回数据
    // 前递控制
    input  wire [ 4:0]                  ex_to_id_dest,       // EX阶段的目的寄存器号
    input  wire [ 4:0]                  pre_mem_to_id_dest,  // PRE_MEM阶段写回寄存器号
    input  wire [ 4:0]                  mem_to_id_dest,      // MEM阶段的目的寄存器号
    input  wire [ 4:0]                  wb_to_id_dest,       // WB阶段的目的寄存器号
    input  wire                         ex_to_id_load_op,    // EX阶段是否为加载指令（用于检测load-use冒险）
    input  wire                         pre_mem_to_id_load_op,  // PRE_MEM阶段是否有load指令（用于检测load-use冒险）
    input  wire [31:0]                  ex_to_id_result,       // EX阶段计算结果
    input  wire [31:0]                  pre_mem_to_id_result,  // PRE_MEM阶段前递数据
    input  wire [31:0]                  mem_to_id_result,      // MEM阶段计算结果
    input  wire [31:0]                  wb_to_id_result,       // WB阶段计算结果
    input  wire                         mem_to_id_data_ok,   // MEM前递给ID的数据是否准备好
    input  wire                         calc_not_ready,      // EX 乘除结果未就绪
    // csr与ertn冒险
    input  wire                         ex_csr_we,           // EX阶段写CSR使能
    input  wire [13:0]                  ex_csr_num,          // EX阶段写CSR号码
    input  wire                         ex_ertn_flush,       // EX阶段有ertn指令
    input  wire                         pre_mem_csr_we,      // PRE_MEM阶段写CSR使能
    input  wire [13:0]                  pre_mem_csr_num,     // PRE_MEM阶段写CSR号码
    input  wire                         pre_mem_ertn_flush,  // PRE_MEM阶段有ertn指令
    input  wire                         mem_csr_we,          // MEM阶段写CSR使能
    input  wire [13:0]                  mem_csr_num,         // MEM阶段写CSR号码
    input  wire                         mem_ertn_flush,      // MEM阶段有ertn指令
    input  wire                         wb_csr_we,           // WB阶段写CSR使能
    input  wire [13:0]                  wb_csr_num,          // WB阶段写CSR号码
    input  wire                         wb_ertn_flush,       // WB阶段有ertn指令则冲刷流水线
    // 与csr寄存器堆的读交互
    input  wire [ 1:0]                  csr_da_pg,           // csr CRMD_DA_PG 即当前映射模式
    input  wire [31:0]                  csr_rvalue,          // csr访问指令读的数据
    output wire [13:0]                  csr_id_num,          // csr寄存器号码(id阶段用于读)
    // 来自csr的中断判断
    input  wire                         has_int,

    // ── linectrl 接口 ──
    input  wire                         ldata,              // 0=用旧寄存器, 1=用新寄存器
    input  wire                         lvalid,             // 本拍可呈现数据
    input  wire                         lpower,             // 本拍有权发请求
    input  wire                         lready,             // 维持就绪
    input  wire                         upd,                // 上级已准备且有权力 → 更新 data_n

    output wire                         id_valid_o,         // → linectrl valid_i
    output wire                         id_exc_o,           // → linectrl exc_i
    output wire                         id_ertn_o           // → linectrl ertn_i
    `ifdef DIFFTEST_EN
    ,
    // difftest
    output wire [31:0]                  rf_to_diff [31:0]
    `endif
);

    wire id_valid;                                  // 本拍有效 = (ldata? valid_n : valid_o) & lvalid
    wire id_exc_valid;                              // 异常有效
    wire id_ertn_flush;                             // ertn 冲刷
    reg  rf_valid;                                  // 计算下拍是否应该有重取指标记
    wire id_rf_valid;                               // 重取指标记

    // ========== 双寄存器结构 ==========
    reg  [`IF_TO_ID_BUS_WD-1:0] data_n;            // 新数据寄存器（upd 时捕获）
    reg                      valid_n;               // 新 valid
    reg  [`IF_TO_ID_BUS_WD-1:0] data_o;             // 旧数据寄存器
    reg                      valid_o;               // 旧 valid

    // ========== 双寄存器逻辑 ==========

    // ── data_n: upd 时从上游捕获 ──
    always @(posedge clk) begin
        if (reset) begin
            data_n  <= `IF_TO_ID_BUS_WD'd0;
            valid_n <= 1'b0;
        end
        else if (upd) begin
            data_n  <= if_to_id_bus;
            valid_n <= if_to_id_valid;
        end
    end

    // ── data_o: ldata=1 且未准备时从 data_n 拷贝 ──
    always @(posedge clk) begin
        if (reset) begin
            data_o  <= `IF_TO_ID_BUS_WD'd0;
            valid_o <= 1'b0;
        end
        else begin
            if (ldata)  data_o  <= data_n;
            valid_o <= (ldata ? valid_n : valid_o) & lvalid;
        end
    end

    // ── ldata 选通 ──
    wire [`IF_TO_ID_BUS_WD-1:0] current_bus;
    assign current_bus = ldata ? data_n : data_o;
    assign id_valid    = (ldata ? valid_n : valid_o) & lvalid;

    // ── ready_go = work_done || !valid || lready ──
    wire work_done;
    assign id_ready_go = work_done || !id_valid || lready;

    // ── → linectrl ──
    assign id_valid_o = id_valid;
    assign id_exc_o   = id_exc_valid;
    assign id_ertn_o  = id_ertn_flush;
    assign id_ertn_flush = 1'b0;

    // ── → EX ──
    assign id_to_ex_valid = id_valid;
    assign id_to_ex_upd   = lpower || !id_valid;

    // ========== 异常信号 ==========
    wire ipe;
    wire fpd;
    wire syscall;
    wire brk;
    wire ine;
    wire intr;
    wire [9:0] id_exc;

    // ========== 指令字段分割 ==========
    wire [5:0] op_31_26;                 // 操作码[31:26]
    wire [3:0] op_25_22;                 // 操作码[25:22]
    wire [1:0] op_25_24;                 // 操作码[25:24]
    wire [1:0] op_21_20;                 // 操作码[21:20]
    wire [4:0] op_19_15;                 // 操作码[19:15]
    wire [4:0] op_14_10;                 // 操作码[14:10]
    wire [4:0] rd;                       // 目的寄存器号[4:0]
    wire [4:0] rj;                       // 源寄存器1号[9:5]
    wire [4:0] rk;                       // 源寄存器2号[14:10]
    wire [11:0] i12;                     // 12位立即数[21:10]
    wire [19:0] i20;                     // 20位立即数[24:5]
    wire [15:0] i16;                     // 16位立即数[25:10]
    wire [25:0] i26;                     // 26位立即数（用于分支）
    wire [4:0] cacop_code;               // cache操作类型
    // ========== 解码器输出（用于指令识别） ==========
    wire [63:0] op_31_26_d;              // 6位操作码的1-of-64解码
    wire [15:0] op_25_22_d;              // 4位操作码的1-of-16解码
    wire [3:0]  op_25_24_d;              // 2位操作码的1-of-4解码
    wire [3:0]  op_21_20_d;              // 2位操作码的1-of-4解码
    wire [31:0] op_19_15_d;              // 5位操作码的1-of-32解码
    wire [31:0] op_14_10_d;              // 5位操作码的1-of-32解码

    // ============================================================
    // 指令识别
    // ============================================================
    // ========== 算术运算指令 ==========
    wire inst_add_w;        // 32位加法（寄存器-寄存器）
    wire inst_sub_w;        // 32位减法（寄存器-寄存器）
    wire inst_addi_w;       // 32位加法（寄存器-立即数）

    // ========== 比较指令 ==========
    wire inst_slt;          // 有符号小于置1（寄存器-寄存器）
    wire inst_sltu;         // 无符号小于置1（寄存器-寄存器）
    wire inst_slti;         // 有符号小于置1（寄存器-立即数）
    wire inst_sltui;        // 无符号小于置1（寄存器-立即数）

    // ========== 逻辑运算指令 ==========
    wire inst_and;          // 按位与（寄存器-寄存器）
    wire inst_or;           // 按位或（寄存器-寄存器）
    wire inst_xor;          // 按位异或（寄存器-寄存器）
    wire inst_nor;          // 按位或非（寄存器-寄存器）
    wire inst_andi;         // 按位与（寄存器-立即数）
    wire inst_ori;          // 按位或（寄存器-立即数）
    wire inst_xori;         // 按位异或（寄存器-立即数）

    // ========== 移位指令 ==========
    wire inst_slli_w;       // 逻辑左移（立即数移位量）
    wire inst_srli_w;       // 逻辑右移（立即数移位量）
    wire inst_srai_w;       // 算术右移（立即数移位量）
    wire inst_sll_w;        // 逻辑左移（寄存器移位量）
    wire inst_srl_w;        // 逻辑右移（寄存器移位量）
    wire inst_sra_w;        // 算术右移（寄存器移位量）

    // ========== 乘除法指令 ==========
    wire inst_mul_w;        // 有符号乘法（取低32位）
    wire inst_mulh_w;       // 有符号乘法（取高32位）
    wire inst_mulh_wu;      // 无符号乘法（取高32位）
    wire inst_div_w;        // 有符号除法（商）
    wire inst_div_wu;       // 无符号除法（商）
    wire inst_mod_w;        // 有符号除法（余数）
    wire inst_mod_wu;       // 无符号除法（余数）

    // ========== 访存指令 ==========
    // 字访问
    wire inst_ld_w;         // 加载字（32位）
    wire inst_st_w;         // 存储字（32位）
    // 半字访问
    wire inst_ld_h;         // 加载半字（16位，有符号扩展）
    wire inst_ld_hu;        // 加载半字（16位，零扩展）
    wire inst_st_h;         // 存储半字（16位）
    // 字节访问
    wire inst_ld_b;         // 加载字节（8位，有符号扩展）
    wire inst_ld_bu;        // 加载字节（8位，零扩展）
    wire inst_st_b;         // 存储字节（8位）

    // ========== 分支跳转指令 ==========
    // 无条件跳转
    wire inst_b;            // 无条件相对跳转（PC + 偏移）
    wire inst_bl;           // 无条件相对跳转并链接（函数调用）
    wire inst_jirl;         // 间接跳转并链接（寄存器目标）
    // 条件分支（相等/不等）
    wire inst_beq;          // 相等则分支（rj == rd）
    wire inst_bne;          // 不等则分支（rj != rd）
    // 条件分支（有符号比较）
    wire inst_blt;          // 有符号小于则分支（rj < rd）
    wire inst_bge;          // 有符号大于等于则分支（rj >= rd）
    // 条件分支（无符号比较）
    wire inst_bltu;         // 无符号小于则分支（rj < rd）
    wire inst_bgeu;         // 无符号大于等于则分支（rj >= rd）

    // ========== 立即数加载指令 ==========
    wire inst_lu12i_w;      // 加载高20位立即数到寄存器（左移12位）
    wire inst_pcaddu12i;    // PC + 12位立即数左移12位

    // ========== 系统指令 ==========
    wire inst_syscall;      // 系统调用（触发异常，陷入内核）
    wire inst_break;        // 断点指令（触发调试异常）
    wire inst_ertn;         // 异常返回（恢复上下文，从ERA跳转）
    //ertn指令的唯一功能就是在wb阶段发出冲刷信号，csr堆接受到冲刷信号后，在下一个上跳沿会立马利用csr中的数据来写csr，是立马读立马写所以无冒险

    // ========== TLB相关指令 ==========
    wire inst_tlbwr;        // 将TLB相关CSR页表项信息写入TLB（由index指定位置）
    wire inst_tlbfill;      // 将TLB相关CSR页表项信息写入TLB（随机位置）
    wire inst_invtlb;       // 根据op指示，将rj，rk匹配的TLB清除

    // ========== CSR访问指令 ==========
    wire inst_csrrd;        // CSR读：将CSR寄存器的值读取到通用寄存器
    wire inst_csrwr;        // CSR写：将通用寄存器的值写入CSR寄存器
    wire inst_csrxchg;      // CSR原子读改写：读取CSR原值，同时按掩码修改CSR
    // TLB相关指令(写CSR)
    wire inst_tlbsrch;      // CSR写：exe阶段查找tlb，写TLBIDX
    wire inst_tlbrd;        // CSR写：读tlb，写TLBIDX,TLBEHI,TLBELO0,TLBELO1,ASID
    // CPU配置读取指令
    wire inst_cpucfg;       // CPUCFG：读配置信息字到rd（CSR地址 = rj + 0x00b0）

    // ========== 计时器访问指令 ==========
    wire inst_rdcntvl_w;    // 读取计数器低32位写入rd
    wire inst_rdcntvh_w;    // 读取计数器高32位写入rd
    wire inst_rdcntid;      // 读取csr_tid写入rd
    // ========== cache控制指令 ==========
    wire inst_cacop;        // cache操作指令

    // ========== 控制信号 ==========
    wire [18:0] alu_op;                  // ALU操作码（19位）
    wire src1_is_pc;                     // 源操作数1是否来自PC
    wire src2_is_imm;                    // 源操作数2是否为立即数
    wire res_from_mem;                   // 结果是否来自存储器
    wire res_from_csr;                   // 结果是否来自csr寄存器堆
    wire res_from_timer;                 // 结果来自计数器
    wire timer_high;                     // 使用计数器高32位
    wire dst_is_r1;                      // 目的寄存器是否为R1（用于BL指令）
    wire dst_is_rdtid;                   // 目的寄存器是否为rj
    wire gr_we;                          // 通用寄存器写使能
    wire mem_we;                         // 存储器写使能
    wire src_reg_is_rd;                  // 源寄存器是否使用rd（用于条件分支）
    wire [4:0] dest;                     // 目的寄存器号
    wire ertn_flush;                     // 异常返回冲刷信号
    wire [31:0] id_pc;                   // 当前指令的PC值
    wire [31:0] id_inst;                 // 当前指令的机器码
    wire [2:0] mem_size;                 // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                   // 符号扩展标志
    wire tlbsrch_en;                     // EXE访问tlb进行查找
    wire invtlb_en;                      // EXE访问tlb进行选中无效
    wire tlbrd_en;                       // WB读tlb并写csr
    wire tlbwr_en;                       // tlbwrWB写tlb
    wire tlbfill_en;
    wire cacop_en;                       // cache操作使能
    // ========== 立即数控制信号 ==========
    wire need_ui5;                       // 5位无符号立即数（移位量）
    wire need_si12;                      // 12位有符号立即数
    wire need_ui12;                      // 12位无符号立即数
    wire need_si16;                      // 16位有符号立即数（分支）
    wire need_si20;                      // 20位有符号立即数
    wire need_si26;                      // 26位有符号立即数（分支）
    wire src2_is_4;                      // 常数4（用于链接寄存器）

    // ========== 寄存器文件接口 ==========
    wire [4:0] rf_raddr1;                // 读端口1地址（rj）
    wire [31:0] rf_rdata1;               // 读端口1数据
    wire [4:0] rf_raddr2;                // 读端口2地址（rk或rd）
    wire [31:0] rf_rdata2;               // 读端口2数据
    wire rf_we;                          // 寄存器写使能（来自WB）
    wire [4:0] rf_waddr;                 // 写地址（来自WB）
    wire [31:0] rf_wdata;                // 写数据（来自WB）

    // ========== csr文件写信号 ==========
    //读相关信号需要立即与csr寄存器堆交互
    wire        csr_we;
    wire [31:0] csr_wvalue;
    wire [31:0] csr_wmask;

    // ========== 操作数（支持前递，用于ALU/CSR/Store数据通路） ==========
    wire [31:0] rj_value;                // 源操作数1（经过前递）
    wire [31:0] rkd_value;               // 源操作数2（经过前递）
    wire [31:0] imm;                     // 立即数
    wire [31:0] br_offs;                 // 分支偏移量

    `ifdef DIFFTEST_EN
    // ========== difftest 信号 ==========
    wire [ 7:0] inst_ld_en;
    wire [ 7:0] inst_st_en;
    wire        cnt_inst;
    wire        csr_rstat_en;
    `endif

    // ========== 数据冒险检测信号 ==========
    wire src_no_rj;                      // 指令不使用rj
    wire src_no_rk;                      // 指令不使用rk
    wire src_has_rd;                     // 指令需要读rd
    wire rj_wait;                        // rj需要等待前递
    wire rk_wait;                        // rk需要等待前递
    wire rd_wait;                        // rd需要等待前递

    // ========== 流水线停顿检测 ==========
    wire id_load_op;                     // ID阶段是否为加载指令
    wire load_use_stall;                 // load-use冒险需要停顿
    wire csr_stall;                      // csr与ertn有关冒险
    wire int_csr_stall;                  // 中断与csr有关冒险
    wire inst_csr_stall;                 // csr指令有关冒险
    wire calc_stall;                     // 乘除法计算结果未就绪停顿

    // ========== 指令字段生成 ==========
    assign op_31_26 = id_inst[31:26];
    assign op_25_22 = id_inst[25:22];
    assign op_25_24 = id_inst[25:24];
    assign op_21_20 = id_inst[21:20];
    assign op_19_15 = id_inst[19:15];
    assign op_14_10 = id_inst[14:10];
    assign rd       = id_inst[4:0];
    assign rj       = id_inst[9:5];
    assign rk       = id_inst[14:10];
    assign i12      = id_inst[21:10];
    assign i20      = id_inst[24:5];
    assign i16      = id_inst[25:10];
    assign i26      = {id_inst[9:0], id_inst[25:10]};
    // cpucfg: ID用固定常数避免14-bit加法器进关键路径, 实际CSR号由EX计算
    assign csr_id_num = inst_cpucfg  ? 14'h00b1
                      : inst_rdcntid ? 14'h40
                      : inst_tlbsrch ? 14'h10 : id_inst[23:10];
    assign cacop_code = id_inst[4:0];
    // ========== 指令解码器实例化（将位向量转换为独热码） ==========
    decoder_6_64 u_dec0 (
        .in  (op_31_26),
        .out (op_31_26_d)
    );
    decoder_4_16 u_dec1 (
        .in  (op_25_22),
        .out (op_25_22_d)
    );
    decoder_2_4 u_dec2 (
        .in  (op_25_24),
        .out (op_25_24_d)
    );
    decoder_2_4 u_dec3 (
        .in  (op_21_20),
        .out (op_21_20_d)
    );
    decoder_5_32 u_dec4 (
        .in  (op_19_15),
        .out (op_19_15_d)
    );
    decoder_5_32 u_dec5 (
        .in  (op_14_10),
        .out (op_14_10_d)
    );
    // ========== 指令识别 ==========
    // 算术运算指令
    assign inst_add_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
    assign inst_sub_w  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
    assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
    // 比较指令
    assign inst_slt    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
    assign inst_sltu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
    // 逻辑运算指令
    assign inst_nor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
    assign inst_and    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
    assign inst_or     = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
    assign inst_xor    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
    // 移位指令
    assign inst_slli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h01];
    assign inst_srli_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h09];
    assign inst_srai_w = op_31_26_d[6'h00] & op_25_22_d[4'h1] & op_21_20_d[2'h0] & op_19_15_d[5'h11];
    // 访存指令
    assign inst_ld_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h2];
    assign inst_st_w   = op_31_26_d[6'h0a] & op_25_22_d[4'h6];
    // 分支跳转指令
    assign inst_jirl   = op_31_26_d[6'h13];   // 间接跳转并链接
    assign inst_b      = op_31_26_d[6'h14];   // 无条件跳转
    assign inst_bl     = op_31_26_d[6'h15];   // 跳转并链接（函数调用）
    assign inst_beq    = op_31_26_d[6'h16];   // 相等则分支
    assign inst_bne    = op_31_26_d[6'h17];   // 不等则分支
    // 立即数加载指令
    assign inst_lu12i_w  = op_31_26_d[6'h05] & ~id_inst[25];
    // 立即数比较指令
    assign inst_slti     = op_31_26_d[6'h00] & op_25_22_d[4'h8];
    assign inst_sltui    = op_31_26_d[6'h00] & op_25_22_d[4'h9];
    // 立即数逻辑运算指令
    assign inst_andi     = op_31_26_d[6'h00] & op_25_22_d[4'hd];
    assign inst_ori      = op_31_26_d[6'h00] & op_25_22_d[4'he];
    assign inst_xori     = op_31_26_d[6'h00] & op_25_22_d[4'hf];
    // 寄存器移位指令
    assign inst_sll_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0e];
    assign inst_srl_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0f];
    assign inst_sra_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h10];
    // PC相关指令
    assign inst_pcaddu12i = op_31_26_d[6'h07] & ~id_inst[25];
    // 乘除法指令
    assign inst_mul_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h18];
    assign inst_mulh_w   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h19];
    assign inst_mulh_wu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h1a];
    assign inst_div_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h00];
    assign inst_div_wu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h02];
    assign inst_mod_w    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h01];
    assign inst_mod_wu   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h03];
    // 条件分支指令
    assign inst_blt      = op_31_26_d[6'h18];   // 有符号小于分支
    assign inst_bge      = op_31_26_d[6'h19];   // 有符号大于等于分支
    assign inst_bltu     = op_31_26_d[6'h1a];   // 无符号小于分支
    assign inst_bgeu     = op_31_26_d[6'h1b];   // 无符号大于等于分支
    // 字节/半字访存指令
    assign inst_ld_b     = op_31_26_d[6'h0a] & op_25_22_d[4'h0];
    assign inst_ld_h     = op_31_26_d[6'h0a] & op_25_22_d[4'h1];
    assign inst_ld_bu    = op_31_26_d[6'h0a] & op_25_22_d[4'h8];
    assign inst_ld_hu    = op_31_26_d[6'h0a] & op_25_22_d[4'h9];
    assign inst_st_b     = op_31_26_d[6'h0a] & op_25_22_d[4'h4];
    assign inst_st_h     = op_31_26_d[6'h0a] & op_25_22_d[4'h5];
    // 系统指令
    assign inst_syscall  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h16];
    assign inst_break    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h2] & op_19_15_d[5'h14];
    assign inst_ertn     = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & op_14_10_d[5'h0e] & (rj == 5'b0) & (rd == 5'b0);
    // tlb相关指令
    assign inst_tlbsrch  = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & op_14_10_d[5'h0a] & (rj == 5'b0) & (rd == 5'b0);
    assign inst_tlbrd    = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & op_14_10_d[5'h0b] & (rj == 5'b0) & (rd == 5'b0);
    assign inst_tlbwr    = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & op_14_10_d[5'h0c] & (rj == 5'b0) & (rd == 5'b0);
    assign inst_tlbfill  = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h10] & op_14_10_d[5'h0d] & (rj == 5'b0) & (rd == 5'b0);
    assign inst_invtlb   = op_31_26_d[6'h01] & op_25_22_d[4'h9] & op_21_20_d[2'h0] & op_19_15_d[5'h13];
    // csr访问指令
    assign inst_csrrd    = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj == 5'b0);
    assign inst_csrwr    = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj == 5'b1);
    assign inst_csrxchg  = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj != 5'b0) & (rj != 5'b1);
    assign inst_cpucfg   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h1b];
    // 计数器指令
    assign inst_rdcntvl_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h18] & (rj == 5'b0);
    assign inst_rdcntvh_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h19] & (rj == 5'b0);
    assign inst_rdcntid   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h18] & (rd == 5'b0);
    // cache控制指令
    assign inst_cacop     = op_31_26_d[6'h01] & op_25_22_d[4'h8];

    // ========== alu操作码生成 ==========
    assign alu_op[0]  = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w |
                        inst_jirl | inst_bl | inst_pcaddu12i |
                        inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                        inst_st_b | inst_st_h | inst_cacop;
                                                   // 加法操作
    assign alu_op[1]  = inst_sub_w;                // 减法操作
    assign alu_op[2]  = inst_slt | inst_slti;      // 有符号小于置1
    assign alu_op[3]  = inst_sltu | inst_sltui;    // 无符号小于置1
    assign alu_op[4]  = inst_and | inst_andi;      // 按位与
    assign alu_op[5]  = inst_nor;                  // 按位或非
    assign alu_op[6]  = inst_or | inst_ori;        // 按位或
    assign alu_op[7]  = inst_xor | inst_xori;      // 按位异或
    assign alu_op[8]  = inst_slli_w | inst_sll_w;  // 逻辑左移
    assign alu_op[9]  = inst_srli_w | inst_srl_w;  // 逻辑右移
    assign alu_op[10] = inst_srai_w | inst_sra_w;  // 算术右移
    assign alu_op[11] = inst_lu12i_w;              // 加载高20位立即数
    assign alu_op[12] = inst_mul_w;                // 乘法（低32位）
    assign alu_op[13] = inst_mulh_w;               // 乘法（高32位，有符号）
    assign alu_op[14] = inst_mulh_wu;              // 乘法（高32位，无符号）
    assign alu_op[15] = inst_div_w;                // 有符号除法
    assign alu_op[16] = inst_mod_w;                // 有符号取模
    assign alu_op[17] = inst_div_wu;               // 无符号除法
    assign alu_op[18] = inst_mod_wu;               // 无符号取模

    // ========== 立即数生成 ==========
    assign need_ui5  = inst_slli_w | inst_srli_w | inst_srai_w;     // 5位无符号立即数（移位量）
    assign need_si12 = inst_addi_w | inst_ld_w | inst_st_w |
                       inst_slti | inst_sltui |
                       inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                       inst_st_b | inst_st_h | inst_cacop;          // 12位有符号立即数
    assign need_ui12 = inst_andi | inst_ori | inst_xori;            // 12位无符号立即数
    assign need_si16 = inst_jirl | inst_beq | inst_bne |
                       inst_blt | inst_bltu | inst_bge | inst_bgeu; // 16位有符号立即数（分支）
    assign need_si20 = inst_lu12i_w | inst_pcaddu12i;               // 20位有符号立即数
    assign need_si26 = inst_b | inst_bl;                            // 26位有符号立即数（分支）
    assign src2_is_4 = inst_jirl | inst_bl;                         // 常数4（用于链接寄存器）

    // 扁平化 5:1 优先级链为并行 mask（条件互斥）
    assign imm = ({32{src2_is_4}} & 32'h4)
               | ({32{need_si20}} & {i20[19:0], 12'b0})
               | ({32{need_ui5 }} & {27'b0, rk})
               | ({32{need_si12}} & {{20{i12[11]}}, i12[11:0]})
               | ({32{need_ui12}} & {20'b0, i12});

    // 分支偏移量计算（左移2位，因为指令是4字节对齐）
    assign br_offs = need_si26 ? { {4{i26[25]}}, i26[25:0], 2'b0 } :
                     { {14{i16[15]}}, i16[15:0], 2'b0 };

    // ========== 控制信号生成 ==========
    assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w | inst_blt |
                           inst_bltu | inst_bge | inst_bgeu | inst_st_b | inst_st_h | inst_csrwr | inst_csrxchg;  // rkd数据源于rd寄存器
    assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;  // alu操作数1来自PC
    assign src2_is_imm   = inst_slli_w | inst_srli_w | inst_srai_w | inst_addi_w |
                           inst_ld_w | inst_st_w | inst_lu12i_w | inst_jirl | inst_bl |
                           inst_slti | inst_sltui | inst_pcaddu12i |
                           inst_andi | inst_ori | inst_xori |
                           inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                           inst_st_b | inst_st_h | inst_cacop;    // alu操作数2来自立即数
    assign res_from_mem  = inst_ld_w | inst_ld_b | inst_ld_h |
                           inst_ld_bu | inst_ld_hu;               // 结果来自存储器（加载指令）
    assign res_from_csr  = inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid | inst_cpucfg;// 结果来自csr寄存器堆
    assign res_from_timer = inst_rdcntvh_w | inst_rdcntvl_w;      // 结果来自计数器
    assign timer_high    = inst_rdcntvh_w;                        // 读取计数器高32位
    assign dst_is_r1     = inst_bl;                               // BL指令将返回地址写入R1
    assign dst_is_rdtid  = inst_rdcntid;                          // rdtid指令写rj
    assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b &
                           ~inst_blt & ~inst_bltu & ~inst_bge & ~inst_bgeu &
                           ~inst_st_b & ~inst_st_h & ~inst_tlbsrch & ~inst_tlbrd & ~inst_tlbwr & ~inst_tlbfill & ~inst_invtlb &
                           ~inst_ertn & ~inst_cacop;               // 写通用寄存器条件
    assign mem_we        = inst_st_w | inst_st_b | inst_st_h;     // 存储器写使能
    assign dest          = dst_is_r1 ? 5'd1 :
                           dst_is_rdtid ? rj : rd;                // 目的寄存器：BL写R1，rdtid写rj，其他写rd
    assign ertn_flush    = inst_ertn;
    assign tlbsrch_en    = inst_tlbsrch;
    assign invtlb_en     = inst_invtlb;
    assign tlbrd_en      = inst_tlbrd;
    assign tlbwr_en      = inst_tlbwr;
    assign tlbfill_en    = inst_tlbfill;
    assign cacop_en      = inst_cacop;

    `ifdef DIFFTEST_EN
    // ========== difftest 信号生成 ==========
    // load使能: ldw ldhu ldh ldbu ldb (无ll_w)
    assign inst_ld_en = {2'b0, inst_ld_w, inst_ld_hu, inst_ld_h, inst_ld_bu, inst_ld_b};
    // store使能: stw sth stb (无sc_w)
    assign inst_st_en = {5'b0, inst_st_w, inst_st_h, inst_st_b};
    // 计数器指令
    assign cnt_inst = res_from_timer || inst_rdcntid;
    // csr estat读使能
    assign csr_rstat_en = (inst_csrrd || inst_csrwr || inst_csrxchg) && (csr_id_num == `CSR_ESTAT);
    `endif

    // 访存大小编码
    assign mem_size[0]   = inst_ld_b | inst_ld_bu | inst_st_b;    // 字节访问
    assign mem_size[1]   = inst_ld_h | inst_ld_hu | inst_st_h;    // 半字访问
    assign mem_size[2]   = inst_ld_w | inst_st_w;                 // 字访问
    assign mem_sign_ext  = inst_ld_b | inst_ld_h;                 // 有符号加载需要符号扩展

    // ========== 寄存器文件接口 ==========
    assign rf_raddr1 = rj;                         // 读端口1：始终读rj
    assign rf_raddr2 = src_reg_is_rd ? rd : rk;    // 读端口2：条件分支读rd，否则读rk
    assign rf_we     = wb_to_rf_bus[37];           // 写使能（来自WB）
    assign rf_waddr  = wb_to_rf_bus[36:32];        // 写地址（来自WB）
    assign rf_wdata  = wb_to_rf_bus[31:0];         // 写数据（来自WB）

    // 寄存器文件实例化
    regfile u_regfile (
        .clk    (clk),
        .raddr1 (rf_raddr1),
        .rdata1 (rf_rdata1),
        .raddr2 (rf_raddr2),
        .rdata2 (rf_rdata2),
        .we     (rf_we),
        .waddr  (rf_waddr),
        .wdata  (rf_wdata)
        `ifdef DIFFTEST_EN
        ,
        .rf_o   (rf_to_diff)
        `endif
    );

    // ========== csr文件写接口 ==========
    assign csr_we     = inst_csrwr | inst_csrxchg | inst_tlbsrch;
    assign csr_wvalue = inst_tlbsrch ? 32'h80000000 : rkd_value;
    assign csr_wmask  = inst_csrxchg ? rj_value
                      : inst_csrwr   ? 32'hffffffff
                      : inst_tlbsrch ? 32'h80000000 : 32'b0;

    // ========== 操作数前递 ==========
    assign rj_value = rj_wait ?
                      (rj_eq_ex  ? ex_to_id_result :
                       rj_eq_pre ? pre_mem_to_id_result :
                       rj_eq_mem ? mem_to_id_result : wb_to_id_result)
                      : rf_rdata1;

    assign rkd_value = rk_wait ?
                       (rk_eq_ex  ? ex_to_id_result :
                        rk_eq_pre ? pre_mem_to_id_result :
                        rk_eq_mem ? mem_to_id_result : wb_to_id_result) :
                       rd_wait ?
                       (rd_eq_ex  ? ex_to_id_result :
                        rd_eq_pre ? pre_mem_to_id_result :
                        rd_eq_mem ? mem_to_id_result : wb_to_id_result) :
                       rf_rdata2;

    // ============================================================
    // 预测信息解析 + 分支辅助信号生成（仅透传给 EX，不做决策）
    // ============================================================
    // 解析来自if阶段的总线（含预测信息）
    wire        id_pred_valid;
    wire        id_pred_taken;
    wire [29:0] id_pred_target;
    wire        id_pred_is_ras;
    wire [ 4:0] id_pred_btb_index;
    wire [ 3:0] id_pred_ras_index;
    wire        id_static_taken;
    assign {
        id_exc[8:5],
        id_inst,
        id_pc,
        id_pred_valid,
        id_pred_taken,
        id_pred_target,
        id_pred_is_ras,
        id_pred_btb_index,
        id_pred_ras_index,
        id_static_taken
    } = current_bus;

    // 当前指令是否是分支
    wire id_is_branch;
    assign id_is_branch = inst_beq | inst_bne | inst_bl | inst_b |
                          inst_blt | inst_bge | inst_bltu | inst_bgeu | inst_jirl;

    // 分支类型编码：00=无条件(B/JIRL call) 01=条件 10=call(BL) 11=ret
    wire [1:0] id_br_type;
    wire is_ret = inst_jirl && rd == 5'd0 && rj == 5'd1 && ~|i16;
    wire is_cond= inst_beq | inst_bne | inst_blt | inst_bge | inst_bltu | inst_bgeu;
    assign id_br_type = ({2{inst_bl }} & 2'b10)
                      | ({2{is_ret   }} & 2'b11)
                      | ({2{is_cond  }} & 2'b01);

    // 条件分支比较码 — 扁平化 6:1 优先级链（条件互斥）
    wire [2:0] cond_cmp;
    assign cond_cmp = ({3{inst_beq }} & 3'b000)
                    | ({3{inst_bne }} & 3'b001)
                    | ({3{inst_blt }} & 3'b010)
                    | ({3{inst_bge }} & 3'b011)
                    | ({3{inst_bltu}} & 3'b100)
                    | ({3{inst_bgeu}} & 3'b101);

    // ========== 输出到ex阶段的总线 ==========
    // ID到EX总线组装
    assign id_to_ex_bus = {
        `ifdef DIFFTEST_EN
        csr_rstat_en,   // 412     csr estat读使能 for difftest
        inst_st_en,     // 411:404 store使能 for difftest
        inst_ld_en,     // 403:396 load使能 for difftest
        cnt_inst,       // 395     计数器指令 for difftest
        64'd0,          // 394:331 定时器值 for difftest（由 EX 直接提供）
        id_inst,        // 330:299 指令编码 for difftest
        `else
        114'd0,         // 占位：保持非difftest字段bit位置不变
        `endif
        cacop_code,     // 298:294 cache操作类型
        cacop_en,       // 293     cache操作使能
        tlbsrch_en,     // 292     tlbsrch使能
        invtlb_en,      // 291     invtlb使能
        tlbrd_en,       // 290     tlbrd使能
        tlbwr_en,       // 289     tlbwf使能
        tlbfill_en,     // 288
        id_rf_valid,    // 287     重取指标志
        timer_high,     // 286     使用计数器高32位
        res_from_timer, // 285     结果来自计数器
        res_from_csr,   // 284     结果来自csr寄存器堆
        csr_id_num,     // 283:270 csr号码
        csr_rvalue,     // 269:238 csr读数据
        csr_we,         // 237     csr写使能
        csr_wmask,      // 236:205 csr写掩码
        csr_wvalue,     // 204:173 csr写数据
        ertn_flush,     // 172    异常返回冲刷信号
        id_exc,         // 171:162 异常类型
        res_from_mem,   // 161    结果来源（存储器/ALU）
        id_pc,          // 160:129 指令PC
        rkd_value,      // 128:97 源操作数2
        rj_value,       // 96:65  源操作数1
        imm,            // 64:33  立即数
        dest,           // 32:28  目的寄存器号
        mem_sign_ext,   // 27     符号扩展标志
        mem_size,       // 26:24  访存大小
        mem_we,         // 23     存储器写使能
        gr_we,          // 22     寄存器写使能
        src2_is_imm,    // 21     操作数2来源
        src1_is_pc,     // 20     操作数1来源
        id_load_op,     // 19     是否为加载指令（用于load-use检测）
        alu_op,          // 18:0   ALU操作码
        // 预测透传（42 bit）+ br_type（2 bit）+ cond_cmp（3 bit）+ br_offs（32 bit）
        id_pred_valid,        // 1   预测有效
        id_pred_taken,        // 1   预测方向
        id_pred_target,       // 30  预测目标 PC[31:2]
        id_pred_is_ras,       // 1   RAS 预测
        id_pred_btb_index,    // 5   BTB 命中索引
        id_pred_ras_index,    // 4   RAS 命中索引
        id_br_type,           // 2   分支类型
        cond_cmp,             // 3   条件分支比较码
        br_offs,              // 32  分支偏移量（已符号扩展+左移2位，覆盖B/BL的26位和条件/JIRL的16位）
        id_is_branch,         // 1   是否为分支指令
        id_static_taken       // 1   静态分支预测
    };  // 总计 413 + 80 + 1 = 494

    assign work_done = id_exc_valid || (!load_use_stall && !csr_stall && !calc_stall);
    
    wire rf_ctrl = ((csr_we && (csr_id_num == `CSR_ASID || csr_id_num == `CSR_CRMD && csr_wmask[`CSR_CRMD_PG : `CSR_CRMD_DA] != 2'b0
                            || (csr_id_num == `CSR_DMW0 || csr_id_num == `CSR_DMW1 || csr_id_num == `CSR_CRMD && csr_wmask[`CSR_CRMD_PLV] != 2'b0) && csr_da_pg == 2'b01)
                            || inst_tlbrd || inst_invtlb || inst_tlbwr || inst_tlbfill) || (cacop_code[2:0] == 3'b000) && cacop_en) && !id_exc_valid && id_valid;
    reg rf_r;
    // 重取指信号生成
    always @(posedge clk) begin
        if (reset) begin
            rf_valid <= 1'b0;
        end
        else if (rf_r & ldata) begin
            rf_valid <= 1'b0;
        end
        else if (rf_ctrl) begin
            rf_valid <= 1'b1;
        end

        if (reset) begin
            rf_r <= 1'b0;
        end
        else if (ldata & rf_valid & id_valid) begin
            rf_r <= 1'b1;
        end
        else if (ldata) begin
            rf_r <= 1'b0;
        end
    end
    assign id_rf_valid = rf_valid && ldata && id_valid || rf_r;
    // ========== 冒险检测、前递处理、阻塞处理 ==========
    // 指令类型分类
    assign src_no_rj    = inst_b | inst_bl | inst_lu12i_w | inst_pcaddu12i | inst_csrrd | inst_csrwr |
                          inst_rdcntid | inst_tlbsrch | inst_tlbrd | inst_tlbwr | inst_tlbfill;                 // 不读取rj的指令
    assign src_no_rk    = inst_slli_w | inst_srli_w | inst_srai_w | inst_addi_w |
                          inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                          inst_st_w | inst_jirl | inst_b | inst_bl | inst_beq | inst_bne |
                          inst_blt | inst_bge | inst_bltu | inst_bgeu | inst_lu12i_w |
                          inst_slti | inst_sltui | inst_andi | inst_ori | inst_xori |
                          inst_pcaddu12i | inst_st_b | inst_st_h |
                          inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid | inst_rdcntvl_w | inst_rdcntvh_w |
                          inst_tlbsrch | inst_tlbrd | inst_tlbwr | inst_tlbfill | inst_cacop | inst_cpucfg;            // 不读取rk的指令
    assign src_has_rd   = inst_st_w | inst_beq | inst_bne |
                          inst_blt | inst_bge | inst_bltu | inst_bgeu |
                          inst_st_b | inst_st_h | inst_csrwr | inst_csrxchg;                                     // 需要读取rd的指令


    // ── 预计算 5-bit 寄存器号比较（共享，减扇出）──
    wire rj_valid  = (rj != 5'b00000);
    wire rk_valid  = (rk != 5'b00000);
    wire rd_valid  = (rd != 5'b00000);
    wire rj_eq_ex  = (rj == ex_to_id_dest);
    wire rj_eq_pre = (rj == pre_mem_to_id_dest);
    wire rj_eq_mem = (rj == mem_to_id_dest);
    wire rj_eq_wb  = (rj == wb_to_id_dest);
    wire rk_eq_ex  = (rk == ex_to_id_dest);
    wire rk_eq_pre = (rk == pre_mem_to_id_dest);
    wire rk_eq_mem = (rk == mem_to_id_dest);
    wire rk_eq_wb  = (rk == wb_to_id_dest);
    wire rd_eq_ex  = (rd == ex_to_id_dest);
    wire rd_eq_pre = (rd == pre_mem_to_id_dest);
    wire rd_eq_mem = (rd == mem_to_id_dest);
    wire rd_eq_wb  = (rd == wb_to_id_dest);

    assign rj_wait = ~src_no_rj && rj_valid && (rj_eq_ex || rj_eq_pre || rj_eq_mem || rj_eq_wb);
    assign rk_wait = ~src_no_rk && rk_valid && (rk_eq_ex || rk_eq_pre || rk_eq_mem || rk_eq_wb);
    assign rd_wait =  src_has_rd && rd_valid && (rd_eq_ex || rd_eq_pre || rd_eq_mem || rd_eq_wb);

    // ── load-use stall / calc stall 复用预计算结果 ──
    assign id_load_op    = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
    wire   rj_need_ex    = ~src_no_rj && rj_valid && rj_eq_ex;
    wire   rk_need_ex    = ~src_no_rk && rk_valid && rk_eq_ex;
    wire   rd_need_ex    =  src_has_rd && rd_valid && rd_eq_ex;
    wire   rj_need_pre   = ~src_no_rj && rj_valid && rj_eq_pre;
    wire   rk_need_pre   = ~src_no_rk && rk_valid && rk_eq_pre;
    wire   rd_need_pre   =  src_has_rd && rd_valid && rd_eq_pre;
    wire   rj_need_mem   = ~src_no_rj && rj_valid && rj_eq_mem;
    wire   rk_need_mem   = ~src_no_rk && rk_valid && rk_eq_mem;
    wire   rd_need_mem   =  src_has_rd && rd_valid && rd_eq_mem;

    assign load_use_stall = ((rj_need_ex  || rk_need_ex  || rd_need_ex)  && ex_to_id_load_op)
                         || ((rj_need_pre || rk_need_pre || rd_need_pre) && pre_mem_to_id_load_op)
                         || ((rj_need_mem || rk_need_mem || rd_need_mem) && !mem_to_id_data_ok);

    assign calc_stall = (rj_need_ex || rk_need_ex || rd_need_ex) && calc_not_ready;

    // csr与ertn冒险
    // 简化：后面任意写csr就堵中断，任意ertn也堵
    wire any_ertn_downstream = ex_ertn_flush || pre_mem_ertn_flush || mem_ertn_flush || wb_ertn_flush;
    wire any_csr_we_downstream = ex_csr_we || pre_mem_csr_we || mem_csr_we || wb_csr_we;
    assign int_csr_stall = has_int && (any_csr_we_downstream || any_ertn_downstream);

    // 读csr指令与后面写同一个 CSR 冲突（简化：仅比较 csr 号相等）
    // tlbsrch 额外检查 TLBEHI 冲突；ESTAT 额外检查 TICLR 冲突（TICLR 写会清 ESTAT）
    wire is_csr_reader   = inst_csrrd || inst_csrxchg || inst_csrwr || inst_rdcntid || inst_tlbsrch;
    wire read_estat       = (csr_id_num == `CSR_ESTAT);
    wire any_ticlr_write  = (ex_csr_we      && ex_csr_num      == `CSR_TICLR)
                         || (pre_mem_csr_we && pre_mem_csr_num == `CSR_TICLR)
                         || (mem_csr_we     && mem_csr_num     == `CSR_TICLR)
                         || (wb_csr_we      && wb_csr_num      == `CSR_TICLR);
    assign inst_csr_stall = is_csr_reader &&
                           ((ex_csr_we      && (ex_csr_num == csr_id_num || inst_tlbsrch && ex_csr_num == `CSR_TLBEHI))
                         || (pre_mem_csr_we && (pre_mem_csr_num == csr_id_num || inst_tlbsrch && pre_mem_csr_num == `CSR_TLBEHI))
                         || (mem_csr_we     && (mem_csr_num == csr_id_num || inst_tlbsrch && mem_csr_num == `CSR_TLBEHI))
                         || (wb_csr_we      && wb_csr_num == csr_id_num)
                         || (read_estat && any_ticlr_write));
    assign csr_stall = inst_csr_stall || int_csr_stall;

    // ========== 检测异常 ==========
    assign ipe = 1'b0; // 指令特权等级错例外//占位
    assign fpd = 1'b0; // 浮点指令未使能例外//占位
    assign syscall = id_valid && inst_syscall;
    assign brk     = id_valid && inst_break;
    assign ine     = id_valid &&
             !(inst_add_w | inst_sub_w | inst_slt | inst_sltu | inst_nor |
               inst_and | inst_or | inst_xor | inst_slli_w | inst_srli_w | inst_srai_w |
               inst_addi_w | inst_ld_w | inst_st_w | inst_jirl | inst_b | inst_bl |
               inst_beq | inst_bne | inst_lu12i_w | inst_slti | inst_sltui |
               inst_andi | inst_ori | inst_xori | inst_sll_w | inst_srl_w | inst_sra_w |
               inst_pcaddu12i | inst_mul_w | inst_mulh_w | inst_mulh_wu |
               inst_div_w | inst_div_wu | inst_mod_w | inst_mod_wu |
               inst_blt | inst_bge | inst_bltu | inst_bgeu |
               inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
               inst_st_b | inst_st_h | inst_syscall | inst_break | inst_ertn |
               inst_csrrd | inst_csrwr | inst_csrxchg |
               inst_rdcntid | inst_rdcntvh_w | inst_rdcntvl_w |
               inst_tlbsrch | inst_tlbrd | inst_tlbwr | inst_tlbfill | inst_cacop | inst_cpucfg |
               (inst_invtlb & (rd == 5'd0 | rd == 5'd1 | rd == 5'd2 | rd == 5'd3 | rd == 5'd4 | rd == 5'd5 | rd == 5'd6)));
    assign {id_exc[9], id_exc[4:0]} = {intr, syscall, brk, ine, ipe, fpd};
    assign id_exc_valid = (|id_exc || id_rf_valid) && id_valid;
    assign intr = has_int;
    // has_int的产生逻辑在csr寄存器堆里
endmodule