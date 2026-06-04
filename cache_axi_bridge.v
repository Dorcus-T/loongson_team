// ========== Cache-AXI 转接桥 ==========
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
    input  wire         icache_accept,
    input  wire         icache_wr_req,
    input  wire [ 2:0]  icache_wr_type,
    input  wire [31:0]  icache_wr_addr,
    input  wire [ 3:0]  icache_wr_wstrb,
    input  wire [127:0] icache_wr_data,
    output wire         icache_wr_rdy,

    // DCache 读写接口
    input  wire         dcache_rd_req,
    input  wire [ 2:0]  dcache_rd_type,
    input  wire [31:0]  dcache_rd_addr,
    output wire         dcache_rd_rdy,
    output wire         dcache_return_valid,
    output wire         dcache_return_last,
    output wire [31:0]  dcache_return_data,
    input  wire         dcache_accept,
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

    // ========== Burst 检测 ==========
    wire is_icache_burst;
    wire is_dcache_rd_burst;
    wire is_dcache_wr_burst;
    assign is_icache_burst    = (icache_rd_type == 3'b100);
    assign is_dcache_rd_burst = (dcache_rd_type == 3'b100);
    assign is_dcache_wr_burst = (dcache_wr_type == 3'b100);

    // ================================================================
    // 读请求处理 — 仲裁、冲突检测、状态机、AXI 读地址输出
    // ================================================================

    // ---------- 传输字节数 ----------
    wire [ 5:0] icache_rd_bytes;
    wire [ 5:0] dcache_rd_bytes;
    assign icache_rd_bytes = is_icache_burst    ? 6'd16 : 6'd4;
    assign dcache_rd_bytes = is_dcache_rd_burst ? 6'd16 : 6'd4;

    // ---------- 地址冲突检测 ----------
    // 写追踪器寄存器（读路径也依赖，提前在这里声明）
    reg  [31:0] wr_pend_addr  [0:3];
    reg  [ 5:0] wr_pend_bytes [0:3];
    reg  [ 3:0] wr_pend_wstrb [0:3];
    reg  [ 1:0] wr_pend_wptr;
    reg  [ 1:0] wr_pend_rptr;
    reg  [ 2:0] wr_pend_cnt;

    function addr_conflict;
        input [31:0] rd_addr;
        input [ 5:0] rd_total_bytes;
        reg   [31:0] rd_end;
        reg   [31:0] wr_end;
        integer       k;
        begin
            addr_conflict = 1'b0;
            rd_end = rd_addr + {27'd0, rd_total_bytes} - 32'd1;
            for (k = 0; k < 4; k = k + 1) begin
                if (((k - wr_pend_rptr) & 2'd3) < wr_pend_cnt) begin
                    wr_end = wr_pend_addr[k] + {27'd0, wr_pend_bytes[k]} - 32'd1;
                    if (!(rd_end < wr_pend_addr[k] || rd_addr > wr_end)) begin
                        addr_conflict = 1'b1;
                    end
                end
            end
        end
    endfunction

    // ---------- 仲裁 + 冲突判断 ----------
    wire icache_conflict;
    wire dcache_conflict;
    assign icache_conflict = addr_conflict(icache_rd_addr, icache_rd_bytes);
    assign dcache_conflict = addr_conflict(dcache_rd_addr, dcache_rd_bytes);

    // DCache 读优先级高于 ICache（load 比取指更紧急）
    // FIFO 满时拒绝接受新读请求，防溢出
    assign dcache_rd_rdy = (ar_state == AR_IDLE) && !dcache_conflict && !dcache_fifo_full;
    assign icache_rd_rdy = (ar_state == AR_IDLE) && !icache_conflict
                          && !(dcache_rd_req && !dcache_conflict) && !icache_fifo_full;

    // ---------- 状态机 ----------
    localparam AR_IDLE = 2'd0;
    localparam AR_REQ  = 2'd1;

    reg  [ 1:0] ar_state, ar_next;

    always @(posedge clk) begin
        if (reset) begin
            ar_state <= AR_IDLE;
        end
        else begin
            ar_state <= ar_next;
        end
    end

    always @(*) begin
        ar_next = ar_state;
        case (ar_state)
            AR_IDLE: begin
                if ((dcache_rd_req && dcache_rd_rdy) || (icache_rd_req && icache_rd_rdy))
                    ar_next = AR_REQ;
            end
            AR_REQ: begin
                if (arvalid_r && arready)
                    ar_next = AR_IDLE;
            end
        endcase
    end

    // ---------- 读地址通道寄存器 + AXI 输出 ----------
    reg         arvalid_r;
    reg  [ 3:0] arid_r;
    reg  [31:0] araddr_r;
    reg  [ 2:0] arsize_r;
    reg  [ 7:0] arlen_r;

    assign arvalid = arvalid_r;
    assign arid    = arid_r;
    assign araddr  = araddr_r;
    assign arsize  = arsize_r;
    assign arlen   = arlen_r;

    always @(posedge clk) begin
        if (reset) begin
            arvalid_r <= 1'b0;
            arid_r    <= 4'd0;
            araddr_r  <= 32'b0;
            arsize_r  <= 3'b010;
            arlen_r   <= 8'h00;
        end
        else begin
            if (ar_state == AR_IDLE) begin
                if (dcache_rd_req && dcache_rd_rdy) begin
                    arvalid_r <= 1'b1;
                    arid_r    <= 4'd1;
                    araddr_r  <= dcache_rd_addr;
                    arsize_r  <= 3'b010;
                    arlen_r   <= is_dcache_rd_burst ? 8'h03 : 8'h00;
                end
                else if (icache_rd_req && icache_rd_rdy) begin
                    arvalid_r <= 1'b1;
                    arid_r    <= 4'd0;
                    araddr_r  <= icache_rd_addr;
                    arsize_r  <= 3'b010;
                    arlen_r   <= is_icache_burst ? 8'h03 : 8'h00;
                end
            end
            else if (ar_state == AR_REQ && arvalid_r && arready) begin
                arvalid_r <= 1'b0;
            end
        end
    end

    // ================================================================
    // 读响应处理 — ICache/DCache FIFO、rready、return 输出
    // ================================================================

    // ---------- ICache 读响应 FIFO ----------
    reg  [32:0] icache_fifo_mem [0:3];
    reg  [ 1:0] icache_fifo_wptr;
    reg  [ 1:0] icache_fifo_rptr;
    reg  [ 2:0] icache_fifo_cnt;

    wire icache_fifo_full;
    wire icache_fifo_empty;
    wire icache_fifo_we;
    wire icache_fifo_re;
    assign icache_fifo_full  = (icache_fifo_cnt == 3'd4);
    assign icache_fifo_empty = (icache_fifo_cnt == 3'd0);
    assign icache_fifo_we    = rvalid && rready && (rid == 4'd0) && !icache_accept;
    assign icache_fifo_re    = icache_accept && !icache_fifo_empty;

    integer ii;
    always @(posedge clk) begin
        if (reset) begin
            icache_fifo_wptr <= 2'd0;
            icache_fifo_rptr <= 2'd0;
            icache_fifo_cnt  <= 3'd0;
            for (ii = 0; ii < 4; ii = ii + 1)
                icache_fifo_mem[ii] <= 33'b0;
        end
        else begin
            case ({icache_fifo_we, icache_fifo_re})
                2'b10: begin
                    icache_fifo_mem[icache_fifo_wptr] <= {rlast, rdata};
                    icache_fifo_wptr <= icache_fifo_wptr + 2'd1;
                    icache_fifo_cnt  <= icache_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    icache_fifo_rptr <= icache_fifo_rptr + 2'd1;
                    icache_fifo_cnt  <= icache_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    icache_fifo_mem[icache_fifo_wptr] <= {rlast, rdata};
                    icache_fifo_wptr <= icache_fifo_wptr + 2'd1;
                    icache_fifo_rptr <= icache_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ---------- DCache 读响应 FIFO ----------
    reg  [32:0] dcache_fifo_mem [0:3];
    reg  [ 1:0] dcache_fifo_wptr;
    reg  [ 1:0] dcache_fifo_rptr;
    reg  [ 2:0] dcache_fifo_cnt;

    wire dcache_fifo_full;
    wire dcache_fifo_empty;
    wire dcache_fifo_we;
    wire dcache_fifo_re;
    assign dcache_fifo_full  = (dcache_fifo_cnt == 3'd4);
    assign dcache_fifo_empty = (dcache_fifo_cnt == 3'd0);
    assign dcache_fifo_we    = rvalid && rready && (rid == 4'd1) && !dcache_accept;
    assign dcache_fifo_re    = dcache_accept && !dcache_fifo_empty;

    integer jj;
    always @(posedge clk) begin
        if (reset) begin
            dcache_fifo_wptr <= 2'd0;
            dcache_fifo_rptr <= 2'd0;
            dcache_fifo_cnt  <= 3'd0;
            for (jj = 0; jj < 4; jj = jj + 1)
                dcache_fifo_mem[jj] <= 33'b0;
        end
        else begin
            case ({dcache_fifo_we, dcache_fifo_re})
                2'b10: begin
                    dcache_fifo_mem[dcache_fifo_wptr] <= {rlast, rdata};
                    dcache_fifo_wptr <= dcache_fifo_wptr + 2'd1;
                    dcache_fifo_cnt  <= dcache_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    dcache_fifo_rptr <= dcache_fifo_rptr + 2'd1;
                    dcache_fifo_cnt  <= dcache_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    dcache_fifo_mem[dcache_fifo_wptr] <= {rlast, rdata};
                    dcache_fifo_wptr <= dcache_fifo_wptr + 2'd1;
                    dcache_fifo_rptr <= dcache_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ---------- rready ----------
    wire icache_ready;
    wire dcache_ready;
    assign icache_ready = !icache_fifo_full || icache_accept;
    assign dcache_ready = !dcache_fifo_full || dcache_accept;
    assign rready = icache_ready && dcache_ready;

    // ---------- 读响应输出 ----------
    assign icache_return_valid = !icache_fifo_empty || (rvalid && rready && (rid == 4'd0));
    assign icache_return_data  = icache_fifo_empty ? rdata : icache_fifo_mem[icache_fifo_rptr][31:0];
    assign icache_return_last  = icache_fifo_empty ? rlast : icache_fifo_mem[icache_fifo_rptr][32];

    assign dcache_return_valid = !dcache_fifo_empty || (rvalid && rready && (rid == 4'd1));
    assign dcache_return_data  = dcache_fifo_empty ? rdata : dcache_fifo_mem[dcache_fifo_rptr][31:0];
    assign dcache_return_last  = dcache_fifo_empty ? rlast : dcache_fifo_mem[dcache_fifo_rptr][32];

    // ================================================================
    // 写请求处理 — 状态机、写数据分拍、写追踪器、写响应、AXI 写输出
    // ================================================================

    // ---------- 状态机 ----------
    localparam AW_W_IDLE = 2'd0;
    localparam AW_W_BUSY = 2'd1;

    reg  [ 1:0] aw_w_state, aw_w_next;
    reg         aw_done_r;
    reg         w_done_r;

    wire is_last_w_beat;
    assign is_last_w_beat = (w_beat_cnt == awlen_r[1:0]);

    assign dcache_wr_rdy = (aw_w_state == AW_W_IDLE) && !wr_pend_full;

    always @(posedge clk) begin
        if (reset) begin
            aw_w_state <= AW_W_IDLE;
        end
        else begin
            aw_w_state <= aw_w_next;
        end
    end

    always @(*) begin
        aw_w_next = aw_w_state;
        case (aw_w_state)
            AW_W_IDLE: begin
                if (dcache_wr_req && dcache_wr_rdy)
                    aw_w_next = AW_W_BUSY;
            end
            AW_W_BUSY: begin
                if ((aw_done_r || (awvalid_r && awready)) &&
                    (w_done_r  || (wvalid_r && wready && is_last_w_beat)))
                    aw_w_next = AW_W_IDLE;
            end
        endcase
    end

    // ---------- 写地址/数据通道寄存器 + AXI 输出 ----------
    reg         awvalid_r;
    reg  [31:0] awaddr_r;
    reg  [ 2:0] awsize_r;
    reg  [ 7:0] awlen_r;
    reg         wvalid_r;
    reg  [31:0] wdata_r;
    reg  [ 3:0] wstrb_r;
    reg  [ 1:0] w_beat_cnt;
    reg  [127:0] wr_data_latched;

    assign awid    = 4'd1;
    assign awvalid = awvalid_r;
    assign awaddr  = awaddr_r;
    assign awsize  = awsize_r;
    assign awlen   = awlen_r;

    assign wid     = 4'd1;
    assign wvalid  = wvalid_r;
    assign wdata   = wdata_r;
    assign wstrb   = wstrb_r;
    assign wlast   = (w_beat_cnt == awlen_r[1:0]);

    always @(posedge clk) begin
        if (reset) begin
            awvalid_r       <= 1'b0;
            awaddr_r        <= 32'b0;
            awsize_r        <= 3'b010;
            awlen_r         <= 8'h00;
            wvalid_r        <= 1'b0;
            wdata_r         <= 32'b0;
            wstrb_r         <= 4'b0;
            w_beat_cnt      <= 2'd0;
            aw_done_r       <= 1'b0;
            w_done_r        <= 1'b0;
            wr_data_latched <= 128'b0;
        end
        else begin
            if (aw_w_state == AW_W_IDLE && dcache_wr_req && dcache_wr_rdy) begin
                awvalid_r       <= 1'b1;
                awaddr_r        <= dcache_wr_addr;
                awsize_r        <= is_dcache_wr_burst ? 3'b010 : dcache_wr_type;
                awlen_r         <= is_dcache_wr_burst ? 8'h03 : 8'h00;
                wvalid_r        <= 1'b1;
                wdata_r         <= dcache_wr_data[31:0];
                wstrb_r         <= dcache_wr_wstrb;
                w_beat_cnt      <= 2'd0;
                aw_done_r       <= 1'b0;
                w_done_r        <= 1'b0;
                wr_data_latched <= dcache_wr_data;
            end
            else if (aw_w_state == AW_W_BUSY) begin
                if (awvalid_r && awready) begin
                    awvalid_r <= 1'b0;
                    aw_done_r <= 1'b1;
                end
                if (wvalid_r && wready) begin
                    if (is_last_w_beat) begin
                        wvalid_r  <= 1'b0;
                        w_done_r  <= 1'b1;
                    end
                    else begin
                        w_beat_cnt <= w_beat_cnt + 2'd1;
                        case (w_beat_cnt)
                            2'd0: wdata_r <= wr_data_latched[63:32];
                            2'd1: wdata_r <= wr_data_latched[95:64];
                            2'd2: wdata_r <= wr_data_latched[127:96];
                        endcase
                    end
                end
                if ((aw_done_r || (awvalid_r && awready)) &&
                    (w_done_r  || (wvalid_r && wready && is_last_w_beat))) begin
                    aw_done_r <= 1'b0;
                    w_done_r  <= 1'b0;
                end
            end
        end
    end

    // ---------- 写请求追踪器 ----------
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

    wire wr_pend_full;
    wire wr_pend_empty;
    wire wr_pend_push;
    wire wr_pend_pop;
    wire aw_w_done;
    assign wr_pend_full  = (wr_pend_cnt == 3'd4);
    assign wr_pend_empty = (wr_pend_cnt == 3'd0);
    assign aw_w_done     = (aw_w_state == AW_W_BUSY) &&
                           (aw_done_r || (awvalid_r && awready)) &&
                           (w_done_r  || (wvalid_r && wready && is_last_w_beat));
    assign wr_pend_push  = aw_w_done;
    assign wr_pend_pop   = bvalid && bready;

    integer pp;
    always @(posedge clk) begin
        if (reset) begin
            wr_pend_wptr <= 2'd0;
            wr_pend_rptr <= 2'd0;
            wr_pend_cnt  <= 3'd0;
            for (pp = 0; pp < 4; pp = pp + 1) begin
                wr_pend_addr[pp]  <= 32'b0;
                wr_pend_bytes[pp] <= 6'd4;
                wr_pend_wstrb[pp] <= 4'b0;
            end
        end
        else begin
            case ({wr_pend_push, wr_pend_pop})
                2'b10: begin
                    wr_pend_addr[wr_pend_wptr]  <= awaddr_r;
                    wr_pend_bytes[wr_pend_wptr] <= (awlen_r == 8'h03) ? 6'd16 : wr_total_bytes(awsize_r);
                    wr_pend_wstrb[wr_pend_wptr] <= wstrb_r;
                    wr_pend_wptr <= wr_pend_wptr + 2'd1;
                    wr_pend_cnt  <= wr_pend_cnt  + 3'd1;
                end
                2'b01: begin
                    wr_pend_rptr <= wr_pend_rptr + 2'd1;
                    wr_pend_cnt  <= wr_pend_cnt  - 3'd1;
                end
                2'b11: begin
                    wr_pend_addr[wr_pend_wptr]  <= awaddr_r;
                    wr_pend_bytes[wr_pend_wptr] <= (awlen_r == 8'h03) ? 6'd16 : wr_total_bytes(awsize_r);
                    wr_pend_wstrb[wr_pend_wptr] <= wstrb_r;
                    wr_pend_wptr <= wr_pend_wptr + 2'd1;
                    wr_pend_rptr <= wr_pend_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ---------- 写响应 ----------
    assign bready = !wr_pend_empty;
    assign dcache_wr_done = bvalid && bready;

    // ================================================================
    // AXI 常量信号
    // ================================================================
    assign arburst = 2'b01;
    assign arlock  = 2'b00;
    assign arcache = 4'h0;
    assign arprot  = 3'h0;

    assign awburst = 2'b01;
    assign awlock  = 2'b00;
    assign awcache = 4'h0;
    assign awprot  = 3'h0;

endmodule
