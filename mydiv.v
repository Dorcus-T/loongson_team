module mydiv (
    input  wire        aclk,
    input  wire        s_axis_divisor_tvalid,
    output wire        s_axis_divisor_tready,
    input  wire [31:0] s_axis_divisor_tdata,
    input  wire        s_axis_dividend_tvalid,
    output wire        s_axis_dividend_tready,
    input  wire [31:0] s_axis_dividend_tdata,
    output wire        m_axis_dout_tvalid,
    output wire [63:0] m_axis_dout_tdata
);

    localparam IDLE    = 2'd0;
    localparam COMPUTE = 2'd1;
    localparam DONE    = 2'd2;

    reg  [1:0] state;
    reg  [5:0] cnt;
    reg  [31:0] a;
    reg  [31:0] q;
    reg  [31:0] b;
    reg         dividend_sign;
    reg         divisor_sign;
    reg         div_by_zero;

    wire handshake = (state == IDLE) && s_axis_divisor_tvalid && s_axis_dividend_tvalid;

    assign s_axis_divisor_tready  = (state == IDLE);
    assign s_axis_dividend_tready = (state == IDLE);
    assign m_axis_dout_tvalid     = (state == DONE);

    wire [31:0] dividend_abs = s_axis_dividend_tdata[31] ? -s_axis_dividend_tdata : s_axis_dividend_tdata;
    wire [31:0] divisor_abs  = s_axis_divisor_tdata[31] ? -s_axis_divisor_tdata : s_axis_divisor_tdata;

    wire [31:0] a_shifted = {a[30:0], q[31]};
    wire [31:0] a_sub     = a_shifted - b;
    wire        a_ge_b    = a_shifted >= b;

    wire [31:0] quotient_final  = (dividend_sign ^ divisor_sign) ? -q : q;
    wire [31:0] remainder_final = dividend_sign ? -a : a;

    assign m_axis_dout_tdata = {quotient_final, remainder_final};

    always @(posedge aclk) begin
        case (state)
            IDLE: begin
                if (handshake) begin
                    a <= 32'd0;
                    q <= dividend_abs;
                    b <= divisor_abs;
                    cnt <= 6'd0;
                    dividend_sign <= s_axis_dividend_tdata[31];
                    divisor_sign  <= s_axis_divisor_tdata[31];
                    div_by_zero   <= (divisor_abs == 32'd0);
                    state <= COMPUTE;
                end
            end

            COMPUTE: begin
                if (div_by_zero) begin
                    a <= 32'd0;
                    q <= 32'd0;
                    state <= DONE;
                end
                else begin
                    a <= a_ge_b ? a_sub : a_shifted;
                    q <= a_ge_b ? {q[30:0], 1'b1} : {q[30:0], 1'b0};
                    cnt <= cnt + 6'd1;
                    if (cnt == 6'd31)
                        state <= DONE;
                end
            end

            DONE: begin
                state <= IDLE;
            end

            default: begin
                state <= IDLE;
            end
        endcase
    end

endmodule