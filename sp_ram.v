// ============================================================================
// 单端口同步 RAM（按位写使能）
//   - 真单端口：一个地址口，每拍只做读或写其中之一
//   - en 拉高时：|wen 则按位写，wen 全 0 则读
//   - rdata 同步输出（读延迟一拍，read-first 语义）
//   - 按位写使能 wen：用于 tagv 只写 V 位、databank 字节写等
// ============================================================================
module sp_ram #(
    parameter WIDTH = 32,   // 数据位宽
    parameter DEPTH = 256,  // 深度（条目数）
    parameter ADDRW = 8     // 地址位宽
) (
    // 时钟
    input  wire             clk,
    // 单端口访问
    input  wire             en,      // 访问使能：有读或写才拉高
    input  wire [WIDTH-1:0] wen,     // 按位写使能，全 0 表示读
    input  wire [ADDRW-1:0] addr,
    input  wire [WIDTH-1:0] wdata,
    output reg  [WIDTH-1:0] rdata
);

    // ========== 存储阵列 ==========
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // ========== 仿真初始化（清零防 X 传播） ==========
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem[init_i] = {WIDTH{1'b0}};
        end
        rdata = {WIDTH{1'b0}};
    end

    // ========== 单端口同步读 / 按位写 ==========
    integer b;
    always @(posedge clk) begin
        if (en) begin
            if (|wen) begin
                for (b = 0; b < WIDTH; b = b + 1) begin
                    if (wen[b]) begin
                        mem[addr][b] <= wdata[b];
                    end
                end
            end
            else begin
                rdata <= mem[addr];
            end
        end
    end

endmodule
