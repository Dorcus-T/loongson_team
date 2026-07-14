// ============================================================================
// 单端口同步 RAM（字节写使能 — Vivado BRAM 推断优化版）
//   - 内部固定 32-bit 存储，窄位宽由调用方 pad 零后传入，输出按 WIDTH 截断
//   - wen 固定 4 比特，显式字节 if 展开，工具直提 BRAM36
//   - rdata 同步输出（读延迟一拍）
// ============================================================================
module sp_ram #(
    parameter WIDTH = 32,   // 有效数据位宽（≤ 32）
    parameter DEPTH = 256,  // 深度（条目数）
    parameter ADDRW = 8     // 地址位宽
) (
    input  wire                      clk,
    input  wire                      en,
    input  wire [ 3:0]              wen,     // 字节写使能 [3:0]
    input  wire [ADDRW-1:0]         addr,
    input  wire [31:0]              wdata,   // 固定 32-bit（窄宽度由外部 pad）
    output wire [WIDTH-1:0]         rdata
);

    // ========== 32-bit 存储阵列 ==========
    reg [31:0] mem [0:DEPTH-1];
    reg [31:0] rdata_full;

    // ========== 仿真初始化 ==========
    integer init_i;
    initial begin
        for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
            mem[init_i] = 32'b0;
        end
        rdata_full = 32'b0;
    end

    // ========== 单端口同步读写 — Vivado 推荐 BRAM 推断模式 ==========
    always @(posedge clk) begin
        if (en) begin
            if (|wen) begin
                if (wen[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
                if (wen[1]) mem[addr][15: 8] <= wdata[15: 8];
                if (wen[2]) mem[addr][23:16] <= wdata[23:16];
                if (wen[3]) mem[addr][31:24] <= wdata[31:24];
            end
            else begin
                rdata_full <= mem[addr];
            end
        end
    end

    assign rdata = rdata_full[WIDTH-1:0];

endmodule
