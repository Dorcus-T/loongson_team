// 文件：timer_64bit.v
// 64位只读计时器，每个时钟周期加1，复位为0，软件无法修改

module timer_64bit (
    input  wire        clk,         // 时钟信号
    input  wire        reset,       // 复位信号（高有效）
    output wire [63:0] timer_value  // 64位计时器当前值
);

    reg [63:0] timer_cnt;

    // 计时器更新：每个周期加1，复位清零
    always @(posedge clk) begin
        if (reset) begin
            timer_cnt <= 64'b0;
        end
        else begin
            timer_cnt <= timer_cnt + 1'b1;
        end
    end

    // 输出计时器值
    assign timer_value = timer_cnt;

endmodule