module mydivu (
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
    reg         div_by_zero;

    wire handshake = (state == IDLE) && s_axis_divisor_tvalid && s_axis_dividend_tvalid;

    assign s_axis_divisor_tready  = (state == IDLE);
    assign s_axis_dividend_tready = (state == IDLE);
    assign m_axis_dout_tvalid     = (state == DONE);
    assign m_axis_dout_tdata      = {q, a};

    wire [31:0] a_shifted = {a[30:0], q[31]};
    wire [31:0] a_sub     = a_shifted - b;
    wire        a_ge_b    = a_shifted >= b;

    always @(posedge aclk) begin
        case (state)
            IDLE: begin
                if (handshake) begin
                    a <= 32'd0;
                    q <= s_axis_dividend_tdata;
                    b <= s_axis_divisor_tdata;
                    cnt <= 6'd0;
                    div_by_zero <= (s_axis_divisor_tdata == 32'd0);
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