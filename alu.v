module alu(
  input   [18:0] alu_op,       // ALU操作码，每位代表一种运算
  input   [31:0] alu_src1,     // 源操作数1（来自寄存器或PC）
  input   [31:0] alu_src2,     // 源操作数2（来自寄存器或立即数）
  output  [31:0] alu_result,   // ALU运算结果
  output  div_ready,           // 除法器就绪信号（用于流水线停顿）
  input   mem_exc_valid,       // mem异常就不发起除法请求
  input   mem_ertn_flush,      // mem为ertn就不发起除法请求
  input   wb_exc_valid,        // wb有异常冲刷就不发起除法请求
  input   wb_ertn_flush,       // wb有ertn指令就不发出除法请求
  input   [4:0] ex_exc,        // 在ex阶段之前产生的异常类型
  input   ex_valid,            // 无效的ex指令就不发起除法请求
  input   clk,                 // 时钟信号
  input   reset                // 复位信号（高有效）
);

// ========== ALU操作码定义（每位代表一种运算）==========
wire op_add;   //加法操作
wire op_sub;   //减法操作
wire op_slt;   //有符号比较并置1（rj < rk时结果=1）
wire op_sltu;  //无符号比较并置1
wire op_and;   //按位与
wire op_nor;   //按位或非
wire op_or;    //按位或
wire op_xor;   //按位异或
wire op_sll;   //逻辑左移
wire op_srl;   //逻辑右移
wire op_sra;   //算术右移
wire op_lui;   //加载高20位立即数（结果 = src2 << 12）
wire op_mul;   //乘法（取低32位）
wire op_mulh;  //乘法（取高32位，有符号）
wire op_mulhu; //乘法（取高32位，无符号）
wire op_div_w; //有符号除法（商）
wire op_mod_w; //有符号除法（余数）
wire op_div_wu;//无符号除法（商）
wire op_mod_wu;//无符号除法（余数）

// ========== 操作码分解（将19位操作码拆分为独立控制信号）==========
assign op_add  = alu_op[ 0];
assign op_sub  = alu_op[ 1];
assign op_slt  = alu_op[ 2];
assign op_sltu = alu_op[ 3];
assign op_and  = alu_op[ 4];
assign op_nor  = alu_op[ 5];
assign op_or   = alu_op[ 6];
assign op_xor  = alu_op[ 7];
assign op_sll  = alu_op[ 8];
assign op_srl  = alu_op[ 9];
assign op_sra  = alu_op[10];
assign op_lui  = alu_op[11];
// exp 10
assign op_mul  = alu_op[12];
assign op_mulh = alu_op[13];
assign op_mulhu = alu_op[14];
assign op_div_w = alu_op[15];
assign op_mod_w = alu_op[16];
assign op_div_wu = alu_op[17];
assign op_mod_wu = alu_op[18];

// ========== 各运算的中间结果 ==========
wire [31:0] add_sub_result;  // 加/减法结果
wire [31:0] slt_result;      // 有符号比较结果
wire [31:0] sltu_result;     // 无符号比较结果
wire [31:0] and_result;      // 与运算结果
wire [31:0] nor_result;      // 或非运算结果
wire [31:0] or_result;       // 或运算结果
wire [31:0] xor_result;      // 异或运算结果
wire [31:0] lui_result;      // LUI结果
wire [31:0] sll_result;      // 逻辑左移结果
wire [63:0] sr64_result;     // 右移中间结果（64位，用于算术右移的符号扩展）
wire [31:0] sr_result;       // 右移最终结果（逻辑或算术）
wire [63:0] mul64_result;    // 有符号乘法64位结果
wire [63:0] mulu64_result;   // 无符号乘法64位结果
wire [31:0] mul_result;      // 乘法低32位
wire [31:0] mulh_result;     // 有符号乘法高32位
wire [31:0] mulhu_result;    // 无符号乘法高32位
wire [31:0] div_result_signed;   // 有符号除法商
wire [31:0] mod_result_signed;   // 有符号除法余数
wire [31:0] div_result_unsigned; // 无符号除法商
wire [31:0] mod_result_unsigned; // 无符号除法余数

// ========== 32位加法器（同时用于加法和减法）==========
// 加法器输入：src1固定，src2根据操作类型选择取反或不取反
wire [31:0] adder_a;      // 加法器输入A = alu_src1
wire [31:0] adder_b;      // 加法器输入B：减法/比较时取反，否则原值
wire        adder_cin;    // 加法器进位输入：减法/比较时为1（实现补码加减）
wire [31:0] adder_result; // 加法器32位结果
wire        adder_cout;   // 加法器进位输出

// 减法/比较指令时，对src2取反（因为A - B = A + ~B + 1）
assign adder_a   = alu_src1;
assign adder_b   = (op_sub | op_slt | op_sltu) ? ~alu_src2 : alu_src2;
assign adder_cin = (op_sub | op_slt | op_sltu) ? 1'b1      : 1'b0;
assign {adder_cout, adder_result} = adder_a + adder_b + adder_cin;
// ADD、SUB结果直接取加法器的32位结果（进位丢弃）
assign add_sub_result = adder_result;

// ========== SLT有符号比较（rj < rk ? 1 : 0）==========
assign slt_result[31:1] = 31'b0;   // 高31位恒为0
assign slt_result[0]    = (alu_src1[31] & ~alu_src2[31])   // rj负、rk正
                        | ((alu_src1[31] ~^ alu_src2[31]) & adder_result[31]); // 同号时看差值的符号位

// ========== SLTU无符号比较（rj < rk ? 1 : 0）==========
assign sltu_result[31:1] = 31'b0;
assign sltu_result[0]    = ~adder_cout;  // 进位输出为0表示A<B

// ========== 按位逻辑运算 ==========
assign and_result = alu_src1 & alu_src2;  // 按位与
assign or_result  = alu_src1 | alu_src2;  // 按位或
assign nor_result = ~or_result;           // 按位或非（先或再取反）
assign xor_result = alu_src1 ^ alu_src2;  // 按位异或
assign lui_result = alu_src2;             // LUI：直接传递src2（高20位立即数已左移12位）

// ========== SLL逻辑左移 ==========
assign sll_result = alu_src1 << alu_src2[4:0];

// ========== SRL逻辑右移 / SRA算术右移 ==========
assign sr64_result = {{32{op_sra & alu_src1[31]}}, alu_src1[31:0]} >> alu_src2[4:0];
assign sr_result   = sr64_result[31:0];  // 取低32位作为结果

// ========== 乘法运算 ==========
assign mul64_result = $signed(alu_src1) * $signed(alu_src2);  // 有符号64位乘法
assign mulu64_result = alu_src1 * alu_src2;                   // 无符号64位乘法
assign mul_result = mul64_result[31:0];      // mul_w：取低32位
assign mulh_result = mul64_result[63:32];    // mulh_w：取高32位（有符号）
assign mulhu_result = mulu64_result[63:32];  // mulh_wu：取高32位（无符号）

// ==================== 除法器控制逻辑 ====================

// 有符号除法器控制信号
reg s_axis_divisor_tvalid_signed;   // 除数有效（有符号）
wire s_axis_divisor_tready_signed;  // 除数准备就绪（IP核输出）
reg s_axis_dividend_tvalid_signed;  // 被除数有效（有符号）
wire s_axis_dividend_tready_signed; // 被除数准备就绪（IP核输出）
wire div_ready_signed;              // 有符号除法结果有效

// 无符号除法器控制信号
reg s_axis_divisor_tvalid_unsigned;   // 除数有效（无符号）
wire s_axis_divisor_tready_unsigned;  // 除数准备就绪
reg s_axis_dividend_tvalid_unsigned;  // 被除数有效（无符号）
wire s_axis_dividend_tready_unsigned; // 被除数准备就绪
wire div_ready_unsigned;              // 无符号除法结果有效

// 当前指令类型判断
wire signed_div_inst = op_div_w | op_mod_w;      // 有符号除法/取模
wire unsigned_div_inst = op_div_wu | op_mod_wu;  // 无符号除法/取模

// 握手成功标志（数据已成功发送给IP核）
wire signed_handshake = s_axis_divisor_tvalid_signed && s_axis_divisor_tready_signed &&
                        s_axis_dividend_tvalid_signed && s_axis_dividend_tready_signed &&
                        !(|ex_exc) && !mem_exc_valid && !mem_ertn_flush && ex_valid && !wb_ertn_flush && !wb_exc_valid;
wire unsigned_handshake = s_axis_divisor_tvalid_unsigned && s_axis_divisor_tready_unsigned &&
                          s_axis_dividend_tvalid_unsigned && s_axis_dividend_tready_unsigned &&
                        !(|ex_exc) && !mem_exc_valid  && !mem_ertn_flush && ex_valid && !wb_ertn_flush && !wb_exc_valid;
// 如果mem和wb阶段有ertn或者异常指令，除法指令就不握手发出请求，一个除法指令很占用资源
// 判断除法指令是否发送过请求
reg div_inst_new; 
always @(posedge clk) begin
    if(reset) begin
        div_inst_new <= 1'b1;
    end
    else if(signed_handshake || unsigned_handshake) begin
        div_inst_new <= 1'b0;  // 已经发送过请求
    end
    else if(div_ready_signed || div_ready_unsigned) begin
        div_inst_new <= 1'b1;  // 计算完成，清除
    end
end

// ===== 有符号除法器控制状态机 =====
always @(posedge clk) begin 
    if(reset) begin
        s_axis_divisor_tvalid_signed <= 1'b0;
        s_axis_dividend_tvalid_signed <= 1'b0;
    end
    else begin
        // divisor_tvalid控制：握手成功后清零，有新除法时拉高
        if(signed_handshake) begin
            s_axis_divisor_tvalid_signed <= 1'b0;  // 握手完成，清除有效标志
        end
        else if(signed_div_inst && div_inst_new ) begin
            s_axis_divisor_tvalid_signed <= 1'b1;  // 开始新的除法，拉高有效标志
        end
        else begin
            s_axis_divisor_tvalid_signed <= s_axis_divisor_tvalid_signed;  // 保持
        end
        
        // dividend_tvalid控制：逻辑同divisor
        if(signed_handshake) begin
            s_axis_dividend_tvalid_signed <= 1'b0;
        end
        else if(signed_div_inst && div_inst_new) begin
            s_axis_dividend_tvalid_signed <= 1'b1;
        end
        else begin
            s_axis_dividend_tvalid_signed <= s_axis_dividend_tvalid_signed;
        end
    end
end

// ===== 无符号除法器控制状态机（逻辑同有符号）=====
always @(posedge clk) begin 
    if(reset) begin
        s_axis_divisor_tvalid_unsigned <= 1'b0;
        s_axis_dividend_tvalid_unsigned <= 1'b0;
    end
    else begin
        if(unsigned_handshake) begin
            s_axis_divisor_tvalid_unsigned <= 1'b0;
        end
        else if(unsigned_div_inst && div_inst_new) begin
            s_axis_divisor_tvalid_unsigned <= 1'b1;
        end
        else begin
            s_axis_divisor_tvalid_unsigned <= s_axis_divisor_tvalid_unsigned;
        end
        
        if(unsigned_handshake) begin
            s_axis_dividend_tvalid_unsigned <= 1'b0;
        end
        else if(unsigned_div_inst && div_inst_new) begin
            s_axis_dividend_tvalid_unsigned <= 1'b1;
        end
        else begin
            s_axis_dividend_tvalid_unsigned <= s_axis_dividend_tvalid_unsigned;
        end
    end
end

// ===== 有符号除法器IP核实例化 =====
//   s_axis_divisor_tvalid/ready: 除数通道握手
//   s_axis_dividend_tvalid/ready: 被除数通道握手
//   m_axis_dout_tvalid: 结果有效标志
//   m_axis_dout_tdata: {商, 余数}，共64位
mydiv div_inst (
    .aclk(clk),
    .s_axis_divisor_tvalid(s_axis_divisor_tvalid_signed),
    .s_axis_divisor_tready(s_axis_divisor_tready_signed),
    .s_axis_divisor_tdata(alu_src2),      // 除数
    .s_axis_dividend_tvalid(s_axis_dividend_tvalid_signed),
    .s_axis_dividend_tready(s_axis_dividend_tready_signed),
    .s_axis_dividend_tdata(alu_src1),     // 被除数
    .m_axis_dout_tvalid(div_ready_signed),
    .m_axis_dout_tdata({div_result_signed, mod_result_signed})  // 高32位商，低32位余数
);

// ===== 无符号除法器IP核实例化 =====
mydivu divu_inst (
    .aclk(clk),
    .s_axis_divisor_tvalid(s_axis_divisor_tvalid_unsigned),
    .s_axis_divisor_tready(s_axis_divisor_tready_unsigned),
    .s_axis_divisor_tdata(alu_src2),
    .s_axis_dividend_tvalid(s_axis_dividend_tvalid_unsigned),
    .s_axis_dividend_tready(s_axis_dividend_tready_unsigned),
    .s_axis_dividend_tdata(alu_src1),
    .m_axis_dout_tvalid(div_ready_unsigned),
    .m_axis_dout_tdata({div_result_unsigned, mod_result_unsigned})
);

assign div_ready = (signed_div_inst && div_ready_signed) || 
                   (unsigned_div_inst && div_ready_unsigned);

// ========== 最终结果选择（根据操作码选择对应的运算结果）==========
assign alu_result = ({32{op_add|op_sub}} & add_sub_result)      // 加/减法
                  | ({32{op_slt       }} & slt_result)          // 有符号比较
                  | ({32{op_sltu      }} & sltu_result)         // 无符号比较
                  | ({32{op_and       }} & and_result)          // 与
                  | ({32{op_nor       }} & nor_result)          // 或非
                  | ({32{op_or        }} & or_result)           // 或
                  | ({32{op_xor       }} & xor_result)          // 异或
                  | ({32{op_lui       }} & lui_result)          // 加载高20位
                  | ({32{op_sll       }} & sll_result)          // 逻辑左移
                  | ({32{op_srl|op_sra}} & sr_result)           // 逻辑/算术右移
                  | ({32{op_mul       }} & mul_result)          // 乘法低32位
                  | ({32{op_mulh      }} & mulh_result)         // 有符号乘法高32位
                  | ({32{op_mulhu     }} & mulhu_result)        // 无符号乘法高32位
                  | ({32{op_div_w     }} & div_result_signed)   // 有符号除法商
                  | ({32{op_div_wu    }} & div_result_unsigned) // 无符号除法商
                  | ({32{op_mod_w     }} & mod_result_signed)   // 有符号取模
                  | ({32{op_mod_wu    }} & mod_result_unsigned); // 无符号取模

endmodule