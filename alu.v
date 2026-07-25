module alu (
    // ALU 运算接口
    input  wire [18:0] alu_op,         // ALU操作码，每位代表一种运算
    input  wire [31:0] alu_src1,       // 源操作数1（来自寄存器或PC）
    input  wire [31:0] alu_src2,       // 源操作数2（来自寄存器或立即数）
    output wire [31:0] alu_result,     // ALU运算结果
    // 除法器流水线控制信号
    output wire        div_ready_o,    // 除法器就绪信号（用于流水线停顿）
    // 时钟与复位
    input  wire        clk,            // 时钟信号
    input  wire        reset,          // 复位信号（高有效）
    // 乘法器握手
    output wire        mul_ready_o,      // 乘法器结果就绪（1拍脉冲，复用除法器停顿框架）
    // 流水线控制（简化为 can_req + ldata）
    input  wire        can_req,        // 本拍有权且有效，可发起乘除法请求
    input  wire        ldata           // 新指令到达，复位单发锁
);

    // ========== ALU 操作码定义（每位代表一种运算） ==========
    wire op_add;   // 加法操作
    wire op_sub;   // 减法操作
    wire op_slt;   // 有符号比较并置1（rj < rk时结果=1）
    wire op_sltu;  // 无符号比较并置1
    wire op_and;   // 按位与
    wire op_nor;   // 按位或非
    wire op_or;    // 按位或
    wire op_xor;   // 按位异或
    wire op_sll;   // 逻辑左移
    wire op_srl;   // 逻辑右移
    wire op_sra;   // 算术右移
    wire op_lui;   // 加载高20位立即数（结果 = src2 << 12）
    wire op_mul;   // 乘法（取低32位）
    wire op_mulh;  // 乘法（取高32位，有符号）
    wire op_mulhu; // 乘法（取高32位，无符号）
    wire op_div_w; // 有符号除法（商）
    wire op_mod_w; // 有符号除法（余数）
    wire op_div_wu;// 无符号除法（商）
    wire op_mod_wu;// 无符号除法（余数）

    // ========== 操作码分解（将19位操作码拆分为独立控制信号） ==========
    assign op_add    = alu_op[ 0];
    assign op_sub    = alu_op[ 1];
    assign op_slt    = alu_op[ 2];
    assign op_sltu   = alu_op[ 3];
    assign op_and    = alu_op[ 4];
    assign op_nor    = alu_op[ 5];
    assign op_or     = alu_op[ 6];
    assign op_xor    = alu_op[ 7];
    assign op_sll    = alu_op[ 8];
    assign op_srl    = alu_op[ 9];
    assign op_sra    = alu_op[10];
    assign op_lui    = alu_op[11];
    assign op_mul    = alu_op[12];
    assign op_mulh   = alu_op[13];
    assign op_mulhu  = alu_op[14];
    assign op_div_w  = alu_op[15];
    assign op_mod_w  = alu_op[16];
    assign op_div_wu = alu_op[17];
    assign op_mod_wu = alu_op[18];

    // ========== 各运算的中间结果 ==========
    wire [31:0] add_sub_result;     // 加/减法结果
    wire [31:0] slt_result;         // 有符号比较结果
    wire [31:0] sltu_result;        // 无符号比较结果
    wire [31:0] and_result;         // 与运算结果
    wire [31:0] nor_result;         // 或非运算结果
    wire [31:0] or_result;          // 或运算结果
    wire [31:0] xor_result;         // 异或运算结果
    wire [31:0] lui_result;         // LUI结果
    wire [31:0] sll_result;         // 逻辑左移结果
    wire [63:0] sr64_result;        // 右移中间结果（64位，算术右移符号扩展用）
    wire [31:0] sr_result;          // 右移最终结果（逻辑或算术）
    wire [31:0] mul_result;         // 乘法低32位
    wire [31:0] mulh_result;        // 有符号乘法高32位
    wire [31:0] mulhu_result;       // 无符号乘法高32位
    wire [31:0] div_result_signed;  // 有符号除法商
    wire [31:0] mod_result_signed;  // 有符号除法余数
    wire [31:0] div_result_unsigned;// 无符号除法商
    wire [31:0] mod_result_unsigned;// 无符号除法余数

    // ========== 32位加法器（同时用于加法和减法） ==========
    wire [31:0] adder_a;      // 加法器输入A = alu_src1
    wire [31:0] adder_b;      // 加法器输入B：减法/比较时取反，否则原值
    wire        adder_cin;    // 加法器进位输入：减法/比较时为1（实现补码加减）
    wire [31:0] adder_result; // 加法器32位结果
    wire        adder_cout;   // 加法器进位输出

    assign adder_a   = alu_src1;
    assign adder_b   = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;
    assign adder_cin = (op_sub | op_slt | op_sltu) ? 1'b1      : 1'b0;
    assign {adder_cout, adder_result} = adder_a + adder_b + adder_cin;
    assign add_sub_result = adder_result;

    // ========== SLT 有符号比较（rj < rk ? 1 : 0） ==========
    assign slt_result[31:1] = 31'b0;
    assign slt_result[0]    = (alu_src1[31] & ~alu_src2[31])
                            | ((alu_src1[31] ~^ alu_src2[31]) & adder_result[31]);

    // ========== SLTU 无符号比较（rj < rk ? 1 : 0） ==========
    assign sltu_result[31:1] = 31'b0;
    assign sltu_result[0]    = ~adder_cout;

    // ========== 按位逻辑运算 ==========
    assign and_result = alu_src1 & alu_src2;
    assign or_result  = alu_src1 | alu_src2;
    assign nor_result = ~or_result;
    assign xor_result = alu_src1 ^ alu_src2;
    assign lui_result = alu_src2;

    // ========== SLL 逻辑左移 ==========
    assign sll_result = alu_src1 << alu_src2[4:0];

    // ========== SRL 逻辑右移 / SRA 算术右移 ==========
    assign sr64_result = {{32{op_sra & alu_src1[31]}}, alu_src1[31:0]} >> alu_src2[4:0];
    assign sr_result   = sr64_result[31:0];

    // ============================================================
    // 乘法器流水线控制（2拍握手，复用除法器 AXI-stream 模式）
    // ============================================================

    wire is_mul_inst = op_mul | op_mulh | op_mulhu;

    // 乘法器握手控制信号
    wire s_axis_mul_tvalid;
    wire s_axis_mul_tready;
    reg  mul_ing; //   乘法器正在处理请求
    wire mul_ready;           // 乘法器 IP 输出就绪

    // 乘法握手
    wire mul_handshake = s_axis_mul_tvalid && s_axis_mul_tready;
    assign s_axis_mul_tvalid = is_mul_inst && can_req && !mul_ing;

    // mul_ing 控制
    always @(posedge clk) begin
        if (reset) begin
            mul_ing <= 1'b0;
        end
        else if (mul_handshake) begin
            mul_ing <= 1'b1;
        end
        else if (ldata | mul_ready) begin
            mul_ing <= 1'b0;
        end
    end

    assign mul_ready_o = mul_ready & mul_ing & !ldata;

    wire div_signed_ready   = div_ready_signed   & div_ing_signed   & !ldata;
    wire div_unsigned_ready = div_ready_unsigned & div_ing_unsigned & !ldata;

    // ========== 乘法器 IP 核实例化 ==========
    mymul u_mul_inst (
        .aclk               (clk),
        .s_axis_mul_tvalid  (s_axis_mul_tvalid),
        .s_axis_mul_tready  (s_axis_mul_tready),
        .s_axis_mul_src1    (alu_src1),
        .s_axis_mul_src2    (alu_src2),
        .m_axis_dout_tvalid (mul_ready),
        .m_axis_dout_tdata  ({mulhu_result, mulh_result, mul_result})
    );

    // ============================================================
    // 除法器控制逻辑
    // ============================================================

    // 有符号除法器控制信号
    wire s_axis_divisor_tvalid_signed;   // 除数有效（有符号）
    wire s_axis_divisor_tready_signed;   // 除数准备就绪（IP核输出）
    wire s_axis_dividend_tvalid_signed;  // 被除数有效（有符号）
    wire s_axis_dividend_tready_signed;  // 被除数准备就绪（IP核输出）
    wire div_ready_signed;               // 有符号除法结果有效

    // 无符号除法器控制信号
    wire s_axis_divisor_tvalid_unsigned;  // 除数有效（无符号）
    wire s_axis_divisor_tready_unsigned;  // 除数准备就绪
    wire s_axis_dividend_tvalid_unsigned; // 被除数有效（无符号）
    wire s_axis_dividend_tready_unsigned; // 被除数准备就绪
    wire div_ready_unsigned;              // 无符号除法结果有效

    // 当前指令类型
    wire signed_div_inst   = op_div_w | op_mod_w;
    wire unsigned_div_inst = op_div_wu | op_mod_wu;

    // ── 除法握手（同 mul 模式）──
    wire div_signed_handshake   = s_axis_divisor_tvalid_signed  && s_axis_divisor_tready_signed
                               && s_axis_dividend_tvalid_signed && s_axis_dividend_tready_signed;
    wire div_unsigned_handshake = s_axis_divisor_tvalid_unsigned  && s_axis_divisor_tready_unsigned
                               && s_axis_dividend_tvalid_unsigned && s_axis_dividend_tready_unsigned;

    assign s_axis_divisor_tvalid_signed   = signed_div_inst   && can_req && !div_ing_signed;
    assign s_axis_dividend_tvalid_signed  = signed_div_inst   && can_req && !div_ing_signed;
    assign s_axis_divisor_tvalid_unsigned = unsigned_div_inst && can_req && !div_ing_unsigned;
    assign s_axis_dividend_tvalid_unsigned = unsigned_div_inst && can_req && !div_ing_unsigned;

    reg div_ing_signed, div_ing_unsigned;
    always @(posedge clk) begin
        if (reset)                                                   div_ing_signed   <= 1'b0;
        else if (div_signed_handshake)                               div_ing_signed   <= 1'b1;
        else if (ldata | div_ready_signed)                           div_ing_signed   <= 1'b0;
    end
    always @(posedge clk) begin
        if (reset)                                                   div_ing_unsigned <= 1'b0;
        else if (div_unsigned_handshake)                             div_ing_unsigned <= 1'b1;
        else if (ldata | div_ready_unsigned)                         div_ing_unsigned <= 1'b0;
    end

    // ========== 有符号除法器 IP 核实例化 ==========
    mydiv u_div_inst (
        .aclk                   (clk),
        .s_axis_divisor_tvalid  (s_axis_divisor_tvalid_signed),
        .s_axis_divisor_tready  (s_axis_divisor_tready_signed),
        .s_axis_divisor_tdata   (alu_src2),
        .s_axis_dividend_tvalid (s_axis_dividend_tvalid_signed),
        .s_axis_dividend_tready (s_axis_dividend_tready_signed),
        .s_axis_dividend_tdata  (alu_src1),
        .m_axis_dout_tvalid     (div_ready_signed),
        .m_axis_dout_tdata      ({div_result_signed, mod_result_signed})
    );

    // ========== 无符号除法器 IP 核实例化 ==========
    mydivu u_divu_inst (
        .aclk                   (clk),
        .s_axis_divisor_tvalid  (s_axis_divisor_tvalid_unsigned),
        .s_axis_divisor_tready  (s_axis_divisor_tready_unsigned),
        .s_axis_divisor_tdata   (alu_src2),
        .s_axis_dividend_tvalid (s_axis_dividend_tvalid_unsigned),
        .s_axis_dividend_tready (s_axis_dividend_tready_unsigned),
        .s_axis_dividend_tdata  (alu_src1),
        .m_axis_dout_tvalid     (div_ready_unsigned),
        .m_axis_dout_tdata      ({div_result_unsigned, mod_result_unsigned})
    );

    assign div_ready_o = (signed_div_inst   && div_signed_ready)
                    || (unsigned_div_inst && div_unsigned_ready);

    // ========== 最终结果选择（二叉树 MUX，log2(17)≈5级，替代平坦OR） ==========
    // Level 1: 17 → 9（掩码选择 + 二合一归约）
    wire [31:0] res_l1_0 = ({32{op_add|op_sub}} & add_sub_result)
                         | ({32{op_slt       }} & slt_result);
    wire [31:0] res_l1_1 = ({32{op_sltu      }} & sltu_result)
                         | ({32{op_and       }} & and_result);
    wire [31:0] res_l1_2 = ({32{op_nor       }} & nor_result)
                         | ({32{op_or        }} & or_result);
    wire [31:0] res_l1_3 = ({32{op_xor       }} & xor_result)
                         | ({32{op_lui       }} & lui_result);
    wire [31:0] res_l1_4 = ({32{op_sll       }} & sll_result)
                         | ({32{op_srl|op_sra}} & sr_result);
    wire [31:0] res_l1_5 = ({32{op_mul       }} & mul_result)
                         | ({32{op_mulh      }} & mulh_result);
    wire [31:0] res_l1_6 = ({32{op_mulhu     }} & mulhu_result)
                         | ({32{op_div_w     }} & div_result_signed);
    wire [31:0] res_l1_7 = ({32{op_div_wu    }} & div_result_unsigned)
                         | ({32{op_mod_w     }} & mod_result_signed);
    wire [31:0] res_l1_8 = ({32{op_mod_wu    }} & mod_result_unsigned);

    // Level 2: 9 → 5
    wire [31:0] res_l2_0 = res_l1_0 | res_l1_1;
    wire [31:0] res_l2_1 = res_l1_2 | res_l1_3;
    wire [31:0] res_l2_2 = res_l1_4 | res_l1_5;
    wire [31:0] res_l2_3 = res_l1_6 | res_l1_7;
    wire [31:0] res_l2_4 = res_l1_8;

    // Level 3: 5 → 3
    wire [31:0] res_l3_0 = res_l2_0 | res_l2_1;
    wire [31:0] res_l3_1 = res_l2_2 | res_l2_3;
    wire [31:0] res_l3_2 = res_l2_4;

    // Level 4: 3 → 2
    wire [31:0] res_l4_0 = res_l3_0 | res_l3_1;
    wire [31:0] res_l4_1 = res_l3_2;

    // Level 5: 2 → 1
    assign alu_result = res_l4_0 | res_l4_1;

endmodule