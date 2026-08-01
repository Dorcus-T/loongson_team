// ========== Cache-AXI 转接桥 ==========
// 三组寄存器：ICache 读 Buffer、DCache 读 Buffer、DCache 写 Buffer
//           写追踪 FIFO（4项）、Burst 写事务寄存器、单拍写分拆握手寄存器
// 其余全部组合逻辑直通
module cache_axi_bridge (
    input  wire         clk,
    input  wire         reset,

    // ICache 读接口
    input  wire         icache_rd_req,
    input  wire [ 2:0]  icache_rd_type,
    input  wire [31:0]  icache_rd_addr,
    output wire         icache_rd_rdy,
    output wire         icache_return_valid,
    output wire         icache_return_last,
    output wire [31:0]  icache_return_data,

    // DCache 读写接口
    input  wire         dcache_rd_req,
    input  wire [ 2:0]  dcache_rd_type,
    input  wire [31:0]  dcache_rd_addr,
    output wire         dcache_rd_rdy,
    output wire         dcache_return_valid,
    output wire         dcache_return_last,
    output wire [31:0]  dcache_return_data,
    input  wire         dcache_wr_req,
    input  wire [ 2:0]  dcache_wr_type,
    input  wire [31:0]  dcache_wr_addr,
    input  wire [ 3:0]  dcache_wr_wstrb,
    input  wire [127:0] dcache_wr_data,
    output wire         dcache_wr_rdy,
    output wire         dcache_wr_done,

    // AXI3 Master 读地址通道
    output wire [ 3:0]  arid,
    output wire [31:0]  araddr,
    output wire [ 7:0]  arlen,
    output wire [ 2:0]  arsize,
    output wire [ 1:0]  arburst,
    output wire [ 1:0]  arlock,
    output wire [ 3:0]  arcache,
    output wire [ 2:0]  arprot,
    output wire         arvalid,
    input  wire         arready,
    // AXI3 Master 读数据通道
    input  wire [ 3:0]  rid,
    input  wire [31:0]  rdata,
    input  wire [ 1:0]  rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,
    // AXI3 Master 写地址通道
    output wire [ 3:0]  awid,
    output wire [31:0]  awaddr,
    output wire [ 7:0]  awlen,
    output wire [ 2:0]  awsize,
    output wire [ 1:0]  awburst,
    output wire [ 1:0]  awlock,
    output wire [ 3:0]  awcache,
    output wire [ 2:0]  awprot,
    output wire         awvalid,
    input  wire         awready,
    // AXI3 Master 写数据通道
    output wire [ 3:0]  wid,
    output wire [31:0]  wdata,
    output wire [ 3:0]  wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    // AXI3 Master 写响应通道
    input  wire [ 3:0]  bid,
    input  wire [ 1:0]  bresp,
    input  wire         bvalid,
    output wire         bready
);

    // ============================================================
    // ICache 读 Buffer
    // ============================================================
    reg         ic_rd_buf_valid;
    reg  [ 2:0] ic_rd_buf_type;
    reg  [31:0] ic_rd_buf_addr;

    // ============================================================
    // DCache 读 Buffer
    // ============================================================
    reg         dc_rd_buf_valid;
    reg  [ 2:0] dc_rd_buf_type;
    reg  [31:0] dc_rd_buf_addr;

    // ============================================================
    // DCache 写 Buffer
    // ============================================================
    reg         dc_wr_buf_valid;
    reg  [ 2:0] dc_wr_buf_type;
    reg  [31:0] dc_wr_buf_addr;
    reg  [ 3:0] dc_wr_buf_wstrb;
    reg  [127:0] dc_wr_buf_data;

    // ========== Buffer Burst 检测 ==========
    wire is_ic_rd_burst_buf;
    wire is_dc_rd_burst_buf;
    wire is_dc_wr_burst_buf;
    assign is_ic_rd_burst_buf  = (ic_rd_buf_type  == 3'b100);
    assign is_dc_rd_burst_buf  = (dc_rd_buf_type  == 3'b100);
    assign is_dc_wr_burst_buf  = (dc_wr_buf_type  == 3'b100);


    // ============================================================
    // 写追踪 FIFO — 记录已发但 B 未回的写，供读冲突检测
    // ============================================================
    reg  [31:0] wr_pend_addr  [0:3];
    reg  [ 5:0] wr_pend_bytes [0:3];
    reg  [ 1:0] wr_pend_wptr;
    reg  [ 1:0] wr_pend_rptr;
    reg  [ 2:0] wr_pend_cnt;

    wire wr_pend_full;
    wire wr_pend_empty;
    assign wr_pend_full  = (wr_pend_cnt == 3'd4);
    assign wr_pend_empty = (wr_pend_cnt == 3'd0);

    // ========== 写总字节数 ==========
    function [5:0] wr_total_bytes;
        input [2:0] wr_type;
        case (wr_type)
            3'b100:  wr_total_bytes = 6'd16;
            3'b010:  wr_total_bytes = 6'd4;
            3'b001:  wr_total_bytes = 6'd2;
            3'b000:  wr_total_bytes = 6'd1;
            default: wr_total_bytes = 6'd4;
        endcase
    endfunction

    // ============================================================
    // 写→读冲突检测 — 全在 AR 输出侧，用 Buffer 地址
    // 检测范围：FIFO + Write Buffer + Burst 数据传输中
    // ============================================================
    function rd_wr_conflict;
        input [31:0] rd_addr;
        input [ 5:0] rd_bytes;
        reg   [31:0] rd_end;
        reg   [31:0] wr_end;
        reg   [31:0] same_wr_end;
        integer      k;
        begin
            rd_end = rd_addr + {27'd0, rd_bytes} - 32'd1;
            rd_wr_conflict = 1'b0;

            // 检查写追踪 FIFO
            for (k = 0; k < 4; k = k + 1) begin
                if (((k[1:0] - wr_pend_rptr) & 2'd3) < wr_pend_cnt) begin
                    wr_end = wr_pend_addr[k] + {27'd0, wr_pend_bytes[k]} - 32'd1;
                    if (!(rd_end < wr_pend_addr[k] || rd_addr > wr_end)) begin
                        rd_wr_conflict = 1'b1;
                    end
                end
            end

            // 检查 Buffer 内尚未入 FIFO 的写
            if (dc_wr_buf_valid) begin
                same_wr_end = dc_wr_buf_addr + {27'd0, wr_total_bytes(dc_wr_buf_type)} - 32'd1;
                if (!(rd_end < dc_wr_buf_addr || rd_addr > same_wr_end))
                    rd_wr_conflict = 1'b1;
            end
        end
    endfunction

    wire ic_rd_buf_conflict;
    wire dc_rd_buf_conflict;
    assign ic_rd_buf_conflict = rd_wr_conflict(ic_rd_buf_addr, is_ic_rd_burst_buf ? 6'd16 : 6'd4);
    assign dc_rd_buf_conflict = rd_wr_conflict(dc_rd_buf_addr, is_dc_rd_burst_buf ? 6'd16 : 6'd4);

    // ============================================================
    // Cache 侧握手 — 纯解耦，仅看 buffer 是否空
    // ============================================================
    assign icache_rd_rdy = !ic_rd_buf_valid;
    assign dcache_rd_rdy = !dc_rd_buf_valid;
    assign dcache_wr_rdy  = !dc_wr_buf_valid && !wr_pend_full;


    // ============================================================
    // 读 Buffer — 时序
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            ic_rd_buf_valid <= 1'b0;
            ic_rd_buf_type  <= 3'b010;
            ic_rd_buf_addr  <= 32'b0;
        end
        else if ((icache_rd_req && icache_rd_rdy)) begin
            ic_rd_buf_valid <= 1'b1;
            ic_rd_buf_type  <= icache_rd_type;
            ic_rd_buf_addr  <= icache_rd_addr;
        end
        else if (ic_rd_buf_valid && arready && ic_rd_buf_win)
            ic_rd_buf_valid <= 1'b0;
    end

    always @(posedge clk) begin
        if (reset) begin
            dc_rd_buf_valid <= 1'b0;
            dc_rd_buf_type  <= 3'b010;
            dc_rd_buf_addr  <= 32'b0;
        end
        else if ((dcache_rd_req && dcache_rd_rdy)) begin
            dc_rd_buf_valid <= 1'b1;
            dc_rd_buf_type  <= dcache_rd_type;
            dc_rd_buf_addr  <= dcache_rd_addr;
        end
        else if (dc_rd_buf_valid && arready && dc_rd_buf_win)
            dc_rd_buf_valid <= 1'b0;
    end

    // ============================================================
    // 读路径 — 仲裁与 AR 通道（Buffer 输出侧，冲突检测在这里）
    // ============================================================
    // ar_pending 锁：arvalid 拉高后冻结仲裁，防止数据被其他请求夺走
    // arready 握手完成后释放，允许下一笔仲裁
    reg         ar_pending;
    reg         ar_winner_is_dc;

    always @(posedge clk) begin
        if (reset) begin
            ar_pending      <= 1'b0;
            ar_winner_is_dc <= 1'b0;
        end
        else if (arvalid && arready) begin
            ar_pending <= 1'b0;
        end
        else if (arvalid && !ar_pending) begin
            ar_pending      <= 1'b1;
            ar_winner_is_dc <= dc_rd_buf_win;
        end
    end

    wire dc_rd_buf_win;
    wire ic_rd_buf_win;
    assign dc_rd_buf_win = ar_pending ? ar_winner_is_dc
                                      : (dc_rd_buf_valid && !dc_rd_buf_conflict);
    assign ic_rd_buf_win = ar_pending ? !ar_winner_is_dc
                                      : (ic_rd_buf_valid && !ic_rd_buf_conflict && !dc_rd_buf_win);

    assign arvalid = dc_rd_buf_win || ic_rd_buf_win;
    assign arid    = dc_rd_buf_win ? 4'd1 : 4'd0;
    assign araddr  = dc_rd_buf_win ? dc_rd_buf_addr : ic_rd_buf_addr;
    assign arsize  = 3'b010;
    assign arlen   = dc_rd_buf_win ? (is_dc_rd_burst_buf ? 8'h03 : 8'h00)
                                    : (is_ic_rd_burst_buf  ? 8'h03 : 8'h00);

    // ============================================================
    // 读响应 — 直通，按 rid 分发
    // ============================================================
    assign rready = 1'b1;

    assign icache_return_valid = rvalid && (rid == 4'd0);
    assign icache_return_data  = rdata;
    assign icache_return_last  = rlast;

    assign dcache_return_valid = rvalid && (rid == 4'd1);
    assign dcache_return_data  = rdata;
    assign dcache_return_last  = rlast;

    // ========== 写握手寄存器 ==========
    reg         wr_aw_done_r;  // AW 已握手
    reg         wr_w_done_r;   // W  已完成（单拍=一拍/ Burst=最后一拍）
    reg  [ 1:0] wr_beat;       // W beat 计数（0..3）

    // ============================================================
    // 写路径 — 握手（Buffer → 总线）
    // ============================================================
    wire aw_done;
    assign aw_done = (dc_wr_buf_valid && awready && !wr_pend_full) || wr_aw_done_r;

    wire w_done;
    assign w_done = (dc_wr_buf_valid && wready && !wr_pend_full
                     && (is_dc_wr_burst_buf ? (wr_beat == 2'd3) : 1'b1))
                     || wr_w_done_r;

    wire single_wr_done;
    assign single_wr_done = aw_done && w_done && !is_dc_wr_burst_buf;

    // ========== 握手寄存器 — 时序 ==========
    always @(posedge clk) begin
        if (reset) begin
            wr_aw_done_r <= 1'b0;
            wr_w_done_r  <= 1'b0;
            wr_beat      <= 2'd0;
        end
        else begin
            if (dc_wr_buf_valid && awready && !wr_pend_full && !wr_aw_done_r)
                wr_aw_done_r <= 1'b1;
            if (dc_wr_buf_valid && wready && !wr_pend_full
                && (is_dc_wr_burst_buf ? (wr_beat == 2'd3) : 1'b1)
                && !wr_w_done_r)
                wr_w_done_r <= 1'b1;
            if ((aw_done && w_done)) begin
                wr_aw_done_r <= 1'b0;
                wr_w_done_r  <= 1'b0;
            end
            if (dc_wr_buf_valid && wready && !wr_pend_full && is_dc_wr_burst_buf && wr_beat != 2'd3)
                wr_beat <= wr_beat + 2'd1;
            else if ((aw_done && w_done))
                wr_beat <= 2'd0;
        end
    end

    // ========== 写 Buffer — 时序 ==========
    always @(posedge clk) begin
        if (reset) begin
            dc_wr_buf_valid <= 1'b0;
            dc_wr_buf_type  <= 3'b010;
            dc_wr_buf_addr  <= 32'b0;
            dc_wr_buf_wstrb <= 4'b0;
            dc_wr_buf_data  <= 128'b0;
        end
        else if ((dcache_wr_req && dcache_wr_rdy)) begin
            dc_wr_buf_valid <= 1'b1;
            dc_wr_buf_type  <= dcache_wr_type;
            dc_wr_buf_addr  <= dcache_wr_addr;
            dc_wr_buf_wstrb <= dcache_wr_wstrb;
            dc_wr_buf_data  <= dcache_wr_data;
        end
        else if ((aw_done && w_done))
            dc_wr_buf_valid <= 1'b0;
    end

    // ============================================================
    // 写路径 — AW/W 通道（全部从 Buffer 驱动）
    // ============================================================
    assign awid    = 4'd1;
    assign awvalid = dc_wr_buf_valid && !wr_aw_done_r && !wr_pend_full;
    assign awaddr  = dc_wr_buf_valid ? dc_wr_buf_addr : 32'b0;
    assign awsize  = dc_wr_buf_valid ? (is_dc_wr_burst_buf ? 3'b010 : dc_wr_buf_type) : 3'b010;
    assign awlen   = dc_wr_buf_valid ? (is_dc_wr_burst_buf ? 8'h03 : 8'h00) : 8'h00;

    assign wid    = 4'd1;
    assign wvalid = dc_wr_buf_valid && !wr_pend_full
                  && (is_dc_wr_burst_buf || !wr_w_done_r);
    assign wdata  = dc_wr_buf_valid ? dc_wr_buf_data[wr_beat * 32 +: 32] : 32'b0;
    assign wstrb  = dc_wr_buf_valid ? dc_wr_buf_wstrb : 4'b0;
    assign wlast  = dc_wr_buf_valid ? (is_dc_wr_burst_buf ? (wr_beat == 2'd3) : 1'b1) : 1'b0;

    // ========== 写完成检测 ==========
    wire wr_complete;
    assign wr_complete = single_wr_done
                       || ((aw_done && w_done) && is_dc_wr_burst_buf);

    // ============================================================
    // 写追踪 FIFO — push / pop 时序
    // ============================================================
    integer pp;
    always @(posedge clk) begin
        if (reset) begin
            wr_pend_wptr <= 2'd0;
            wr_pend_rptr <= 2'd0;
            wr_pend_cnt  <= 3'd0;
            for (pp = 0; pp < 4; pp = pp + 1) begin
                wr_pend_addr[pp]  <= 32'b0;
                wr_pend_bytes[pp] <= 6'd4;
            end
        end
        else begin
            case ({wr_complete, (bvalid && bready)})
                2'b10: begin
                    wr_pend_addr[wr_pend_wptr]  <= dc_wr_buf_addr;
                    wr_pend_bytes[wr_pend_wptr] <= single_wr_done
                                                  ? wr_total_bytes(dc_wr_buf_type)
                                                  : 6'd16;
                    wr_pend_wptr <= wr_pend_wptr + 2'd1;
                    wr_pend_cnt  <= wr_pend_cnt  + 3'd1;
                end
                2'b01: begin
                    wr_pend_rptr <= wr_pend_rptr + 2'd1;
                    wr_pend_cnt  <= wr_pend_cnt  - 3'd1;
                end
                2'b11: begin
                    wr_pend_addr[wr_pend_wptr]  <= dc_wr_buf_addr;
                    wr_pend_bytes[wr_pend_wptr] <= single_wr_done
                                                  ? wr_total_bytes(dc_wr_buf_type)
                                                  : 6'd16;
                    wr_pend_wptr <= wr_pend_wptr + 2'd1;
                    wr_pend_rptr <= wr_pend_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // 写响应
    // ============================================================
    assign bready = !wr_pend_empty;
    assign dcache_wr_done = bvalid && bready;

    // ============================================================
    // AXI 常量信号
    // ============================================================
    assign arburst = 2'b01;
    assign arlock  = 2'b00;
    assign arcache = 4'h0;
    assign arprot  = 3'h0;

    assign awburst = 2'b01;
    assign awlock  = 2'b00;
    assign awcache = 4'h0;
    assign awprot  = 3'h0;

endmodule
