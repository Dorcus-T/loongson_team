module mymul (
    input  wire        aclk,
    // 输入握手（复用除法器 AXI-stream 模式）
    input  wire        s_axis_mul_tvalid,
    output wire        s_axis_mul_tready,
    input  wire [31:0] s_axis_mul_src1,
    input  wire [31:0] s_axis_mul_src2,
    // 输出握手
    output wire        m_axis_dout_tvalid,
    output wire [95:0] m_axis_dout_tdata   // {unsigned_hi[31:0], signed_hi[31:0], low[31:0]}
);

    localparam IDLE   = 2'd0;
    localparam STAGE1 = 2'd1;
    localparam STAGE2 = 2'd2;

    reg  [1:0] state;
    reg  [31:0] src1_r;
    reg  [31:0] src2_r;
    reg  [63:0] unsigned_r;
    reg  [63:0] signed_r;

    wire handshake = (state == IDLE) && s_axis_mul_tvalid;

    assign s_axis_mul_tready  = (state == IDLE);
    assign m_axis_dout_tvalid = (state == STAGE2);

    // STAGE1 → STAGE2：在已寄存的操作数上计算乘积（整拍组合路径）
    wire [63:0] stage2_unsigned = src1_r * src2_r;
    // 有符号修正：signed = unsigned - A31*B*2^32 - B31*A*2^32
    wire [63:0] stage2_correction = (src1_r[31] ? {src2_r, 32'd0} : 64'd0)
                                  + (src2_r[31] ? {src1_r, 32'd0} : 64'd0);
    wire [63:0] stage2_signed = stage2_unsigned - stage2_correction;

    assign m_axis_dout_tdata = {unsigned_r[63:32], signed_r[63:32], unsigned_r[31:0]};

    always @(posedge aclk) begin
        case (state)
            IDLE: begin
                if (handshake) begin
                    src1_r <= s_axis_mul_src1;
                    src2_r <= s_axis_mul_src2;
                    state  <= STAGE1;
                end
            end

            STAGE1: begin
                unsigned_r <= stage2_unsigned;
                signed_r   <= stage2_signed;
                state      <= STAGE2;
            end

            STAGE2: begin
                state <= IDLE;
            end

            default: begin
                state <= IDLE;
            end
        endcase
    end

endmodule
