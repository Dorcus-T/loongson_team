`include "mycpu.h"

module id_stage(
    input  clk,
    input  reset,
    // allowin
    input  ex_allowin,                   // EX阶段允许接收信号（用于反压控制）
    output id_allowin,                   // ID阶段允许接收新指令
    // 来自IF阶段
    input  if_to_id_valid,                        // IF到ID的有效标志
    input [`IF_TO_ID_BUS_WD -1:0] if_to_id_bus,   // IF传递的总线：{指令, PC}
    // 输出给ex阶段
    output id_to_ex_valid,                        // ID到EX的有效标志
    output [`ID_TO_EX_BUS_WD -1:0] id_to_ex_bus,  // ID到EX的控制总线
    // 输出给if阶段的分支总线
    output [`BR_BUS_WD -1:0] br_bus,              // 分支总线：{跳转标志, 跳转目标}
    // wb阶段输入的寄存器文件总线
    input  [`WB_TO_RF_BUS_WD -1:0] wb_to_rf_bus,  // WB阶段写回数据
    // 前递控制
    input  [4:0]   ex_to_id_dest,       // EX阶段的目的寄存器号
    input  [4:0]   mem_to_id_dest,      // MEM阶段的目的寄存器号
    input  [4:0]   wb_to_id_dest,       // WB阶段的目的寄存器号
    input          ex_to_id_load_op,    // EX阶段是否为加载指令（用于检测load-use冒险）
    input  [31:0]  ex_to_id_result,     // EX阶段计算结果
    input  [31:0]  mem_to_id_result,    // MEM阶段计算结果
    input  [31:0]  wb_to_id_result,     // WB阶段计算结果
    input          mem_to_id_data_ok,   // MEM前递给ID的数据是否准备好
    input          mem_exc_valid,       // MEM有冲刷就不发起brtaken
    input          ex_exc_valid,        // ex有冲刷就不发起brtaken
    // csr与ertn冒险
    input          ex_csr_we,           // EX阶段写CSR使能
    input  [13:0]  ex_csr_num,          // EX阶段写CSR号码
    input          ex_ertn_flush,       // EX阶段有ertn指令
    input          mem_csr_we,          // MEM阶段写CSR使能
    input  [13:0]  mem_csr_num,         // MEM阶段写CSR号码
    input          mem_ertn_flush,      // MEM阶段有ertn指令 
    input          wb_csr_we,           // WB阶段写CSR使能
    input  [13:0]  wb_csr_num,          // WB阶段写CSR号码
    // 异常冲刷 
    input wb_exc_valid,                  // WB阶段存在异常冲刷流水线    
    input wb_ertn_flush,                 // WB阶段有ertn指令则冲刷流水线  
    // 与csr寄存器堆的读交互
    input  [31:0] csr_rvalue,                       // csr访问指令读的数据
    output [13:0] csr_id_num,                       // csr寄存器号码(id阶段用于读)
    // 来自csr的中断判断
    input has_int
);

    reg  id_valid;                                   // ID阶段有效标志
    wire id_ready_go;                                // ID阶段是否准备好（无冒险）
    reg [`IF_TO_ID_BUS_WD -1:0] if_to_id_bus_r;      // 锁存的取值级数据
    
    // ========== 异常信号 ==========
    wire syscall;
    wire brk;
    wire ine;
    wire int;
    wire [4:0] id_exc;
    wire id_exc_valid;

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

    // ========== 解码器输出（用于指令识别） ==========
    wire [63:0] op_31_26_d;              // 6位操作码的1-of-64解码
    wire [15:0] op_25_22_d;              // 4位操作码的1-of-16解码
    wire [3:0] op_25_24_d;               // 2位操作码的1-of-4解码
    wire [3:0] op_21_20_d;               // 2位操作码的1-of-4解码
    wire [31:0] op_19_15_d;              // 5位操作码的1-of-32解码
    wire [31:0] op_14_10_d;              // 5位操作码的1-of-32解码

    // ===========================================================================
    // ======================= 指令识别  =======================
    //============================================================================
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
    
    // ========== CSR访问指令 ==========
    wire inst_csrrd;        // CSR读：将CSR寄存器的值读取到通用寄存器
    wire inst_csrwr;        // CSR写：将通用寄存器的值写入CSR寄存器
    wire inst_csrxchg;      // CSR原子读改写：读取CSR原值，同时按掩码修改CSR
    
    // ========== 计时器访问指令 ==========
    wire inst_rdcntvl_w;    // 读取计数器低32位写入rd
    wire inst_rdcntvh_w;    // 读取计数器高32位写入rd
    wire inst_rdcntid;      // 读取csr_tid写入rd

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
    wire br_taken;                       // 分支是否发生
    wire [31:0] br_target;               // 分支目标地址
    wire [31:0] id_pc;                   // 当前指令的PC值
    wire [31:0] id_inst;                 // 当前指令的机器码
    wire [2:0]  mem_size;                // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                   // 符号扩展标志
    // ========== 立即数控制信号 ==========
    wire need_ui5 ;                      // 5位无符号立即数（移位量）
    wire need_si12;                      // 12位有符号立即数
    wire need_ui12;                      // 12位无符号立即数
    wire need_si16;                      // 16位有符号立即数（分支）
    wire need_si20;                      // 20位有符号立即数
    wire need_si26;                      // 26位有符号立即数（分支）
    wire src2_is_4;                      // 常数4（用于链接寄存器）

    // ========== 寄存器文件接口 ==========
    wire [4:0]  rf_raddr1;               // 读端口1地址（rj）
    wire [31:0] rf_rdata1;               // 读端口1数据
    wire [4:0]  rf_raddr2;               // 读端口2地址（rk或rd）
    wire [31:0] rf_rdata2;               // 读端口2数据
    wire        rf_we;                   // 寄存器写使能（来自WB）
    wire [4:0]  rf_waddr;                // 写地址（来自WB）
    wire [31:0] rf_wdata;                // 写数据（来自WB）

    // ========== csr文件写信号 ==========
    //读相关信号需要立即与csr寄存器堆交互
    wire         csr_we;
    wire  [31:0] csr_wvalue;
    wire  [31:0] csr_wmask;
    
    // ========== 操作数（支持前递） ==========
    wire [31:0] rj_value;                // 源操作数1（经过前递）
    wire [31:0] rkd_value;               // 源操作数2（经过前递）
    wire [31:0] imm;                     // 立即数
    wire [31:0] br_offs;                 // 分支偏移量
    wire [31:0] jirl_offs;               // JIRL指令偏移量
    
    // ========== 比较结果（用于条件分支） ==========
    wire rj_eq_rd;                       // rj == rkd
    wire rj_lt_rd;                       // rj < rkd（有符号）
    wire rj_lt_rd_u;                     // rj < rkd（无符号）
    wire rj_ge_rd;                       // rj >= rkd（有符号）
    wire rj_ge_rd_u;                     // rj >= rkd（无符号）
    wire adder_cout;                     // 加法器进位输出
    wire [31:0] adder_result;            // 加法器结果
    
    // ========== 数据冒险检测信号 ==========
    wire src_no_rj;                      // 指令不使用rj
    wire src_no_rk;                      // 指令不使用rk
    wire src_no_rd;                      // 指令不使用rd
    wire rj_wait;                        // rj需要等待前递
    wire rk_wait;                        // rk需要等待前递
    wire rd_wait;                        // rd需要等待前递
    
    // ========== 流水线停顿检测 ==========
    wire id_load_op;                     // ID阶段是否为加载指令
    wire load_use_stall;                 // load-use冒险需要停顿
    wire branch_stall;                   // 分支指令数据冒险需要停顿
    wire br_ld_stall;                    // 分支与ld冒险但是ld没取得数据
    wire csr_stall;                      // csr与ertn有关冒险
   
    // ========== 指令字段生成 ==========
    assign op_31_26 = id_inst[31:26];
    assign op_25_22 = id_inst[25:22];
    assign op_25_24 = id_inst[25:24];
    assign op_21_20 = id_inst[21:20];
    assign op_19_15 = id_inst[19:15];
    assign op_14_10 = id_inst[14:10];
    assign rd = id_inst[4:0];
    assign rj = id_inst[9:5];
    assign rk = id_inst[14:10];
    assign i12 = id_inst[21:10];
    assign i20 = id_inst[24:5];
    assign i16 = id_inst[25:10];
    assign i26 = {id_inst[9:0], id_inst[25:10]};  
    assign csr_id_num = inst_rdcntid ? 14'h40 : id_inst[23:10];
     
    // ========== 指令解码器实例化（将位向量转换为独热码） ==========
    decoder_6_64 u_dec0(.in(op_31_26), .out(op_31_26_d));
    decoder_4_16 u_dec1(.in(op_25_22), .out(op_25_22_d));
    decoder_2_4  u_dec2(.in(op_25_24), .out(op_25_24_d));
    decoder_2_4  u_dec3(.in(op_21_20), .out(op_21_20_d));
    decoder_5_32 u_dec4(.in(op_19_15), .out(op_19_15_d));
    decoder_5_32 u_dec5(.in(op_14_10), .out(op_14_10_d));
    // ========== 指令识别 ==========
    // 算术运算指令 
    assign inst_add_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h00];
    assign inst_sub_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h02];
    assign inst_addi_w = op_31_26_d[6'h00] & op_25_22_d[4'ha];
    // 比较指令
    assign inst_slt   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h04];
    assign inst_sltu  = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h05];
    // 逻辑运算指令 
    assign inst_nor   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h08];
    assign inst_and   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h09];
    assign inst_or    = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0a];
    assign inst_xor   = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h1] & op_19_15_d[5'h0b];
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
    assign inst_lu12i_w = op_31_26_d[6'h05] & ~id_inst[25];
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
    // csr访问指令
    assign inst_csrrd    = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj == 5'b0);
    assign inst_csrwr    = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj == 5'b1);
    assign inst_csrxchg  = op_31_26_d[6'h01] & op_25_24_d[2'h0] & (rj != 5'b0) & (rj != 5'b1);
    // 计数器指令
    assign inst_rdcntvl_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h18] & (rj == 5'b0);
    assign inst_rdcntvh_w = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h19] & (rj == 5'b0);
    assign inst_rdcntid = op_31_26_d[6'h00] & op_25_22_d[4'h0] & op_21_20_d[2'h0] & op_19_15_d[5'h00] & op_14_10_d[5'h18] & (rd == 5'b0);

    // ========== alu操作码生成 ==========
    assign alu_op[0]  = inst_add_w | inst_addi_w | inst_ld_w | inst_st_w | 
                        inst_jirl | inst_bl | inst_pcaddu12i | 
                        inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu | 
                        inst_st_b | inst_st_h;     // 加法操作
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
                     inst_st_b | inst_st_h;                         // 12位有符号立即数
    assign need_ui12 = inst_andi | inst_ori | inst_xori;            // 12位无符号立即数
    assign need_si16 = inst_jirl | inst_beq | inst_bne | 
                     inst_blt | inst_bltu | inst_bge | inst_bgeu;   // 16位有符号立即数（分支）
    assign need_si20 = inst_lu12i_w | inst_pcaddu12i;               // 20位有符号立即数
    assign need_si26 = inst_b | inst_bl;                            // 26位有符号立即数（分支）
    assign src2_is_4 = inst_jirl | inst_bl;                         // 常数4（用于链接寄存器）
    
    assign imm = src2_is_4 ? 32'h4 :
                 need_si20 ? {i20[19:0], 12'b0} :                 // 左移12位
                 need_ui5  ? {27'b0, rk} :                        // 零扩展5位
                 need_si12 ? {{20{i12[11]}}, i12[11:0]} :         // 符号扩展12位
                 need_ui12 ? {20'b0, i12} :                       // 零扩展12位
                 32'b0;
    
    // 分支偏移量计算（左移2位，因为指令是4字节对齐）
    assign br_offs = need_si26 ? { {4{i26[25]}}, i26[25:0], 2'b0 } :
                     { {14{i16[15]}}, i16[15:0], 2'b0 };
    
    // JIRL指令的偏移量（同样左移2位）
    assign jirl_offs = { {14{i16[15]}}, i16[15:0], 2'b0 };
    
    // ========== 控制信号生成 ==========
    assign src_reg_is_rd = inst_beq | inst_bne | inst_st_w | inst_blt | 
                           inst_bltu | inst_bge | inst_bgeu | inst_st_b | inst_st_h | inst_csrwr | inst_csrxchg;  // 使用rd作为第二读寄存器数
    assign src1_is_pc    = inst_jirl | inst_bl | inst_pcaddu12i;  // 读寄存器数1来自PC
    assign src2_is_imm   = inst_slli_w | inst_srli_w | inst_srai_w | inst_addi_w |
                           inst_ld_w | inst_st_w | inst_lu12i_w | inst_jirl | inst_bl |
                           inst_slti | inst_sltui | inst_pcaddu12i | 
                           inst_andi | inst_ori | inst_xori |
                           inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                           inst_st_b | inst_st_h;                 // 读寄存器数2来自立即数
    assign res_from_mem  = inst_ld_w | inst_ld_b | inst_ld_h | 
                           inst_ld_bu | inst_ld_hu;               // 结果来自存储器（加载指令）
    assign res_from_csr  = inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid;// 结果来自csr寄存器堆
    assign res_from_timer= inst_rdcntvh_w | inst_rdcntvl_w;       // 结果来自计数器
    assign timer_high    = inst_rdcntvh_w;                        // 读取计数器高32位 
    assign dst_is_r1     = inst_bl;                               // BL指令将返回地址写入R1
    assign dst_is_rdtid  = inst_rdcntid;                          // rdtid指令写rj
    assign gr_we         = ~inst_st_w & ~inst_beq & ~inst_bne & ~inst_b & 
                           ~inst_blt & ~inst_bltu & ~inst_bge & ~inst_bgeu &
                           ~inst_st_b & ~inst_st_h & 
                           ~inst_ertn;                            // 写通用寄存器条件
    assign mem_we        = inst_st_w | inst_st_b | inst_st_h;     // 存储器写使能
    assign dest          = dst_is_r1 ? 5'd1 :
                           dst_is_rdtid ? rj : rd;                // 目的寄存器：BL写R1，rdtid写rj，其他写rd
    assign ertn_flush    = inst_ertn;

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
    regfile u_regfile(
        .clk(clk),
        .raddr1(rf_raddr1), .rdata1(rf_rdata1),
        .raddr2(rf_raddr2), .rdata2(rf_rdata2),
        .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata)
    );
    
    // ========== csr文件写接口 ==========
    assign csr_we     = inst_csrwr | inst_csrxchg;
    assign csr_wvalue = rkd_value;
    assign csr_wmask  = inst_csrxchg ? rj_value : 32'hffffffff;

    // ========== 操作数前递 ==========
    // rj值前递：如果rj需要等待且与EX/MEM/WB阶段的目的寄存器匹配，则使用前递结果
    assign rj_value = rj_wait ? 
                      ((rj == ex_to_id_dest) ? ex_to_id_result :
                       (rj == mem_to_id_dest) ? mem_to_id_result : wb_to_id_result)
                      : rf_rdata1;
    
    // rkd值前递：类似地处理第二操作数
    assign rkd_value = rk_wait ? 
                       ((rk == ex_to_id_dest) ? ex_to_id_result :
                        (rk == mem_to_id_dest) ? mem_to_id_result : wb_to_id_result) : 
                       rd_wait ? 
                       ((rd == ex_to_id_dest) ? ex_to_id_result :
                        (rd == mem_to_id_dest) ? mem_to_id_result : wb_to_id_result) :
                       rf_rdata2;
    
    // ========== 条件分支比较逻辑 ===========
    assign rj_eq_rd    = (rj_value == rkd_value);
    // 有符号减法（用于比较大小）
    assign {adder_cout, adder_result} = {1'b0, rj_value} + {1'b0, ~rkd_value} + 1'b1;
    // 有符号小于比较
    assign rj_lt_rd    = (rj_value[31] && ~rkd_value[31]) ||
                         ((rj_value[31] ~^ rkd_value[31]) && adder_result[31]);
    assign rj_ge_rd    = !rj_lt_rd;
    // 无符号小于比较（利用加法器进位）
    assign rj_lt_rd_u  = !adder_cout;
    assign rj_ge_rd_u  = !rj_lt_rd_u;
    // ========== 分支控制逻辑 ==========
    assign br_taken = (   inst_beq  &&  rj_eq_rd
                       || inst_bne  && !rj_eq_rd
                       || inst_blt  &&  rj_lt_rd
                       || inst_bge  &&  rj_ge_rd
                       || inst_bltu &&  rj_lt_rd_u
                       || inst_bgeu &&  rj_ge_rd_u
                       || inst_jirl
                       || inst_bl
                       || inst_b
                    ) && id_valid && !load_use_stall && !branch_stall 
                      && !(mem_ertn_flush || mem_exc_valid) && !(ex_ertn_flush || ex_exc_valid) && !id_exc_valid;  
    // 冒险阻塞brtaken的意义，lduse：b指令无法取得正确的数据
    // branch阻塞：ex阶段前递数据进行分支判断再给if用来转换地址逻辑太长
    // csrstall：不需要阻塞，b类指令只有在标记中断且后面有csr写指令才会同时发生，如果真是中断，发不发brtaken都会冲刷，如果不是中断，能让正确指令提前一周期到if

    //id，ex，mem有异常或者ertn可以不管brtaken，因为不论是否跳转都会冲刷，wb若有异常或者ertn，其发出的冲刷信号优先级也高于id的brtaken
    assign br_ld_stall = branch_stall && load_use_stall && id_valid; // id为跳转指令，ex为load指令，此时会发出错误的brtarget，不能发出取值请求
    
    // 分支目标地址计算
    assign br_target = (inst_beq || inst_bne || inst_bl || inst_b || 
                        inst_blt || inst_bge || inst_bltu || inst_bgeu) ?
                       (id_pc + br_offs) : (rj_value + jirl_offs);
    
    // 分支总线输出（跳转标志 + 目标地址）
    assign br_bus = {br_ld_stall, br_taken, br_target};
    
    // ========== 解析来自if阶段的总线 ==========
    assign {id_exc[0], id_inst, id_pc} = if_to_id_bus_r;        

    // ========== 输出到ex阶段的总线 ==========
    // ID到EX总线组装
    assign id_to_ex_bus = {
        timer_high,     // 281     使用计数器高32位
        res_from_timer, // 280     结果来自计数器
        res_from_csr,   // 279     结果来自csr寄存器堆
        csr_id_num,     // 278:265 csr号码
        csr_rvalue,     // 264:233 csr读数据
        csr_we,         // 232     csr写使能
        csr_wmask,      // 231:200 csr写掩码
        csr_wvalue,     // 199:168 csr写数据
        ertn_flush,     // 167    异常返回冲刷信号
        id_exc,         // 166:162 异常类型
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
        alu_op          // 18:0   ALU操作码
    };

    // ========== 流水线控制 ==========
    assign id_ready_go = (!load_use_stall && !branch_stall && !csr_stall || id_exc_valid) ; 
    // wb发来冲刷脉冲就阻塞，正常情况下，有阻塞但是id如果是异常指令就不应该阻，异常指令最好快点到wb发冲刷信号
    assign id_allowin = !id_valid || (id_ready_go && ex_allowin);
    assign id_to_ex_valid = id_valid && id_ready_go;
    
    // 译码级有效标志更新
    always @(posedge clk ) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            id_valid <= 1'b0;
        end
        else if (id_allowin) begin
            id_valid <= if_to_id_valid;
        end
    end
    // 译码级数据传递
    always @(posedge clk) begin
        if (if_to_id_valid && id_allowin) begin
            if_to_id_bus_r <= if_to_id_bus;
        end
    end

    // ========== 冒险检测、前递处理、阻塞处理 ==========
    // 指令类型分类
    assign src_no_rj    = inst_b | inst_bl | inst_lu12i_w | inst_pcaddu12i | inst_csrrd | inst_csrwr;  // 不读取rj的指令
    assign src_no_rk    = inst_slli_w | inst_srli_w | inst_srai_w | inst_addi_w |
                          inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu |
                          inst_st_w | inst_jirl | inst_b | inst_bl | inst_beq | inst_bne |
                          inst_blt | inst_bge | inst_bltu | inst_bgeu | inst_lu12i_w |
                          inst_slti | inst_sltui | inst_andi | inst_ori | inst_xori |
                          inst_pcaddu12i | inst_st_b | inst_st_h | 
                          inst_csrrd | inst_csrwr | inst_csrxchg | inst_rdcntid;  // 不读取rk的指令
    assign src_no_rd    = ~inst_st_w & ~inst_beq & ~inst_bne & 
                          ~inst_blt & ~inst_bge & ~inst_bltu & ~inst_bgeu &
                          ~inst_st_b & ~inst_st_h & ~inst_csrwr & ~inst_csrxchg ;  // 不读取rd的指令

    assign rj_wait = ~src_no_rj && (rj != 5'b00000) && 
                     ((rj == ex_to_id_dest) || (rj == mem_to_id_dest) || (rj == wb_to_id_dest));
    assign rk_wait = ~src_no_rk && (rk != 5'b00000) && 
                     ((rk == ex_to_id_dest) || (rk == mem_to_id_dest) || (rk == wb_to_id_dest));
    assign rd_wait = ~src_no_rd && (rd != 5'b00000) && 
                     ((rd == ex_to_id_dest) || (rd == mem_to_id_dest) || (rd == wb_to_id_dest));
    
    // 如果当前指令的源寄存器与ex阶段的目的寄存器匹配，且EX阶段是加载指令，则需要停顿
    assign id_load_op = inst_ld_w | inst_ld_b | inst_ld_h | inst_ld_bu | inst_ld_hu;
    assign load_use_stall = (((rj_wait && (rj == ex_to_id_dest)) ||
                              (rk_wait && (rk == ex_to_id_dest)) ||
                              (rd_wait && (rd == ex_to_id_dest))) && ex_to_id_load_op) ||
                            (((rj_wait && (rj == mem_to_id_dest)) ||
                              (rk_wait && (rk == mem_to_id_dest)) ||
                              (rd_wait && (rd == mem_to_id_dest))) && !mem_to_id_data_ok);


    // 分支指令的阻塞检测（ex阶段的指令与id阶段的跳转指令发生冒险则需要阻塞，优化逻辑提高主频）
    assign branch_stall = ((rj_wait && (rj == ex_to_id_dest)) ||
                           (rk_wait && (rk == ex_to_id_dest)) ||
                           (rd_wait && (rd == ex_to_id_dest))) &&
                          (inst_beq || inst_bne || inst_jirl || inst_bl || 
                           inst_b || inst_blt || inst_bltu || inst_bge || inst_bgeu);
    // csr与ertn冒险
    // 中断判断发生csr冒险(只有确定中断的时候才发生，不确定中断指令继续走就行)
    assign int_csr_stall = has_int && 
                        ((ex_csr_we && (ex_csr_num == `CSR_CRMD || ex_csr_num == `CSR_ECFG || 
                                        ex_csr_num == `CSR_ESTAT || ex_csr_num == `CSR_TCFG || 
                                        ex_csr_num == `CSR_TICLR)) ||
                         (ex_ertn_flush) ||  // ex阶段有ertn，即将写CRMD.IE
                         (mem_csr_we && (mem_csr_num == `CSR_CRMD || mem_csr_num == `CSR_ECFG || 
                                         mem_csr_num == `CSR_ESTAT || mem_csr_num == `CSR_TCFG || 
                                         mem_csr_num == `CSR_TICLR)) ||
                         (mem_ertn_flush) ||  // mem阶段有ertn，即将写CRMD.IE
                         (wb_csr_we && (wb_csr_num == `CSR_CRMD || wb_csr_num == `CSR_ECFG || 
                                        wb_csr_num == `CSR_ESTAT || wb_csr_num == `CSR_TCFG || 
                                        wb_csr_num == `CSR_TICLR)) ||
                         (wb_ertn_flush));   // wb阶段有ertn，即将写CRMD.IE

    // 读csr指令与后面写同一个 CSR 冲突
    assign inst_csr_stall = (inst_csrrd || inst_csrxchg || inst_csrwr || inst_rdcntid) &&
                         ((ex_csr_we && ex_csr_num == csr_id_num) ||
                          (mem_csr_we && mem_csr_num == csr_id_num) ||
                          (wb_csr_we && wb_csr_num == csr_id_num));
    assign csr_stall = inst_csr_stall || int_csr_stall;

    // ========== 检测异常 ==========
    assign syscall = id_valid && inst_syscall;
    assign brk = id_valid && inst_break;
    assign ine = id_valid && 
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
               inst_rdcntid | inst_rdcntvh_w | inst_rdcntvl_w);
    assign id_exc[4:1] = {syscall, brk, ine, int};
    assign id_exc_valid = |id_exc;
    assign int = has_int;
    // has_int的产生逻辑在csr寄存器堆里
endmodule