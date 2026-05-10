module sram_to_axi_bridge (
    input  wire         clk,
    input  wire         reset,

    // 取指类 SRAM
    input  wire         inst_sram_req,
    input  wire         inst_sram_wr,
    input  wire [ 1:0]  inst_sram_size,
    input  wire [ 3:0]  inst_sram_wstrb,
    input  wire [31:0]  inst_sram_addr,
    input  wire [31:0]  inst_sram_wdata,
    output wire         inst_sram_addr_ok,
    output wire         inst_sram_data_ok,
    output wire [31:0]  inst_sram_rdata,

    // 访存类 SRAM
    input  wire         data_sram_req,
    input  wire         data_sram_wr,
    input  wire [ 1:0]  data_sram_size,
    input  wire [ 3:0]  data_sram_wstrb,
    input  wire [31:0]  data_sram_addr,
    input  wire [31:0]  data_sram_wdata,
    output wire         data_sram_addr_ok,
    output wire         data_sram_data_ok,
    output wire [31:0]  data_sram_rdata,

    // AXI3 Master
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
    // 读数据
    input  wire [ 3:0]  rid,
    input  wire [31:0]  rdata,
    input  wire [ 1:0]  rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,
    // 写地址
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
    // 写数据
    output wire [ 3:0]  wid,
    output wire [31:0]  wdata,
    output wire [ 3:0]  wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    // 写响应
    input  wire [ 3:0]  bid,
    input  wire [ 1:0]  bresp,
    input  wire         bvalid,
    output wire         bready
);

    // ========== 寄存器输出数据 ==========
    reg         arvalid_r;
    reg  [ 3:0] arid_r;
    reg  [31:0] araddr_r;
    reg  [ 2:0] arsize_r;

    reg         awvalid_r;
    reg  [31:0] awaddr_r;
    reg  [ 2:0] awsize_r;

    reg         wvalid_r;
    reg  [31:0] wdata_r;
    reg  [ 3:0] wstrb_r;

    reg         rready_r;
    reg         bready_r;

    // ========== 写请求追踪器（用于地址冲突检测） ==========
    reg         wr_pend0_valid, wr_pend1_valid;
    reg  [31:0] wr_pend0_addr,  wr_pend1_addr;
    reg  [ 2:0] wr_pend0_size,  wr_pend1_size;
    reg  [ 3:0] wr_pend0_wstrb, wr_pend1_wstrb;
    wire        aw_w_done;

    // ========== 尺寸映射 ==========
    function [2:0] map_size;
        input [1:0] sz;
        case (sz)
            2'b00:   map_size = 3'b000;
            2'b01:   map_size = 3'b001;
            default: map_size = 3'b010;
        endcase
    endfunction

    // ========== 地址范围（处理冲突） ==========
    function [2:0] size_bytes;
        input [2:0] axsize;
        case (axsize)
            3'b000: size_bytes = 3'd1;
            3'b001: size_bytes = 3'd2;
            3'b010: size_bytes = 3'd4;
            default: size_bytes = 3'd4;
        endcase
    endfunction

    // ========== 地址冲突检测函数 ==========
    function addr_conflict;
        input [31:0] rd_addr;
        input [ 2:0] rd_size;
        input [ 3:0] rd_wstrb;
        reg   [31:0] rd_end;
        reg   [31:0] wr_end;
        begin
            addr_conflict = 1'b0;
            rd_end = rd_addr + size_bytes(rd_size) - 1;

            if (wr_pend0_valid) begin
                wr_end = wr_pend0_addr + size_bytes(wr_pend0_size) - 1;
                if (!(rd_end < wr_pend0_addr || rd_addr > wr_end))
                    addr_conflict = 1'b1;
            end

            if (wr_pend1_valid && !addr_conflict) begin
                wr_end = wr_pend1_addr + size_bytes(wr_pend1_size) - 1;
                if (!(rd_end < wr_pend1_addr || rd_addr > wr_end))
                    addr_conflict = 1'b1;
            end
        end
    endfunction

    // ========== 读请求相关信号 ==========
    localparam AR_IDLE = 2'd0;
    localparam AR_REQ  = 2'd1;

    reg  [ 1:0] ar_state, ar_next;

    wire if_rd_req;
    wire mem_rd_req;
    wire mem_wr_req;
    wire if_conflict;
    wire mem_conflict;
    wire data_sram_addr_ok_rd;

    // ========== 读响应相关信号 ==========
    reg         inst_data_valid;    // 取指读数据就绪
    reg  [31:0] inst_data_r;        // 取指读数据锁存

    reg         mem_data_valid;     // 访存读数据就绪
    reg  [31:0] mem_data_r;         // 访存读数据锁存

    wire        data_sram_data_ok_rd;

    // ========== 写请求相关信号 ==========
    localparam AW_W_IDLE = 2'd0;
    localparam AW_W_BUSY = 2'd1;

    reg  [ 1:0] aw_w_state, aw_w_next;
    reg         aw_done_r;
    reg         w_done_r;
    wire        data_sram_addr_ok_wr;

    // ========== 写响应相关信号 ==========
    reg  [ 1:0] b_pending_cnt;
    wire        data_sram_data_ok_wr;

    // ========== 常量axi信号 ==========
    assign arlen   = 8'h00;
    assign arburst = 2'b01;
    assign arlock  = 2'b00;
    assign arcache = 4'h0;
    assign arprot  = 3'h0;

    assign awid    = 4'd1;
    assign awlen   = 8'h00;
    assign awburst = 2'b01;
    assign awlock  = 2'b00;
    assign awcache = 4'h0;
    assign awprot  = 3'h0;

    assign wid     = 4'd1;
    assign wlast   = 1'b1;

    // ========== 寄存器输出数据 ==========
    assign arvalid = arvalid_r;
    assign arid    = arid_r;
    assign araddr  = araddr_r;
    assign arsize  = arsize_r;

    assign awvalid = awvalid_r;
    assign awaddr  = awaddr_r;
    assign awsize  = awsize_r;

    assign wvalid  = wvalid_r;
    assign wdata   = wdata_r;
    assign wstrb   = wstrb_r;

    assign rready  = rready_r;
    assign bready  = bready_r;

    // ========== 读请求相关实现 ==========
    assign if_rd_req  = inst_sram_req;
    assign mem_rd_req = data_sram_req && !data_sram_wr;
    assign mem_wr_req = data_sram_req && data_sram_wr;

    assign if_conflict  = addr_conflict(inst_sram_addr, map_size(inst_sram_size), inst_sram_wstrb);
    assign mem_conflict = addr_conflict(data_sram_addr, map_size(data_sram_size), data_sram_wstrb);

    assign inst_sram_addr_ok = (ar_state == AR_IDLE) && !if_conflict
                             && !(mem_rd_req && !mem_conflict);

    assign data_sram_addr_ok_rd = (ar_state == AR_IDLE) && !mem_conflict;
    assign data_sram_addr_ok    = data_sram_wr ? data_sram_addr_ok_wr : data_sram_addr_ok_rd;

    // 读请求状态机
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
                if ((mem_rd_req && data_sram_addr_ok_rd) || (if_rd_req && inst_sram_addr_ok))
                    ar_next = AR_REQ;
            end
            AR_REQ: begin
                if (arvalid_r && arready)
                    ar_next = AR_IDLE;
            end
        endcase
    end

    // 读请求相关数据寄存，与状态机同步
    always @(posedge clk) begin
        if (reset) begin
            arvalid_r <= 1'b0;
            arid_r    <= 4'd0;
            araddr_r  <= 32'b0;
            arsize_r  <= 3'b010;
        end
        else begin
            if (ar_state == AR_IDLE) begin
                if (mem_rd_req && data_sram_addr_ok_rd) begin
                    arvalid_r <= 1'b1;
                    arid_r    <= 4'd1;
                    araddr_r  <= data_sram_addr;
                    arsize_r  <= map_size(data_sram_size);
                end
                else if (if_rd_req && inst_sram_addr_ok) begin
                    arvalid_r <= 1'b1;
                    arid_r    <= 4'd0;
                    araddr_r  <= inst_sram_addr;
                    arsize_r  <= map_size(inst_sram_size);
                end
            end
            else if (ar_state == AR_REQ && arvalid_r && arready) begin
                arvalid_r <= 1'b0;
            end
        end
    end

    // ========== 读响应相关实现 ==========
    always @(posedge clk) begin
        if (reset) begin
            rready_r <= 1'b1;
        end
        else begin
            rready_r <= 1'b1;
        end
    end

    // 读出数据寄存一次再送给cpu
    always @(posedge clk) begin
        if (reset) begin
            inst_data_valid <= 1'b0;
            inst_data_r     <= 32'b0;
            mem_data_valid  <= 1'b0;
            mem_data_r      <= 32'b0;
        end
        else begin
            if (rvalid && rready_r && rid == 4'd0) begin
                inst_data_valid <= 1'b1;
                inst_data_r     <= rdata;
            end
            else if (inst_data_valid) begin
                inst_data_valid <= 1'b0;
            end

            if (rvalid && rready_r && rid == 4'd1) begin
                mem_data_valid <= 1'b1;
                mem_data_r     <= rdata;
            end
            else if (mem_data_valid) begin
                mem_data_valid <= 1'b0;
            end
        end
    end

    // 读相关的data_ok
    assign inst_sram_rdata      = inst_data_r;
    assign inst_sram_data_ok    = inst_data_valid;
    assign data_sram_data_ok_rd = mem_data_valid;
    assign data_sram_rdata      = mem_data_r;

    // ========== 写请求相关实现 ==========
    always @(posedge clk) begin
        if (reset) begin
            aw_w_state <= AW_W_IDLE;
        end
        else begin
            aw_w_state <= aw_w_next;
        end
    end

    // 写请求状态机
    always @(*) begin
        aw_w_next = aw_w_state;
        case (aw_w_state)
            AW_W_IDLE: begin
                if (mem_wr_req && data_sram_addr_ok_wr)
                    aw_w_next = AW_W_BUSY;
            end
            AW_W_BUSY: begin
                if ((aw_done_r || (awvalid_r && awready)) &&
                    (w_done_r  || (wvalid_r && wready)))
                    aw_w_next = AW_W_IDLE;
            end
        endcase
    end

    // 写请求相关数据寄存（与状态机同步）
    always @(posedge clk) begin
        if (reset) begin
            awvalid_r <= 1'b0;
            awaddr_r  <= 32'b0;
            awsize_r  <= 3'b010;
            wvalid_r  <= 1'b0;
            wdata_r   <= 32'b0;
            wstrb_r   <= 4'b0;
            aw_done_r <= 1'b0;
            w_done_r  <= 1'b0;
        end
        else begin
            if (aw_w_state == AW_W_IDLE && mem_wr_req && data_sram_addr_ok_wr) begin
                awvalid_r <= 1'b1;
                awaddr_r  <= data_sram_addr;
                awsize_r  <= map_size(data_sram_size);
                wvalid_r  <= 1'b1;
                wdata_r   <= data_sram_wdata;
                wstrb_r   <= data_sram_wstrb;
                aw_done_r <= 1'b0;
                w_done_r  <= 1'b0;
            end
            else if (aw_w_state == AW_W_BUSY) begin
                if (awvalid_r && awready) begin
                    awvalid_r <= 1'b0;
                    aw_done_r <= 1'b1;
                end
                if (wvalid_r && wready) begin
                    wvalid_r <= 1'b0;
                    w_done_r  <= 1'b1;
                end
                if ((aw_done_r || (awvalid_r && awready)) &&
                    (w_done_r  || (wvalid_r && wready))) begin
                    aw_done_r <= 1'b0;
                    w_done_r  <= 1'b0;
                end
            end
        end
    end

    assign data_sram_addr_ok_wr = (aw_w_state == AW_W_IDLE);

    // ========== 写请求追踪器（用于地址冲突检测） ==========
    // 写请求和写数据已经握手的信号
    assign aw_w_done = (aw_w_state == AW_W_BUSY) &&
                       (aw_done_r || (awvalid_r && awready)) &&
                       (w_done_r  || (wvalid_r && wready));

    always @(posedge clk) begin
        if (reset) begin
            wr_pend0_valid <= 1'b0;
            wr_pend1_valid <= 1'b0;
            wr_pend0_addr  <= 32'b0;
            wr_pend1_addr  <= 32'b0;
            wr_pend0_size  <= 3'b010;
            wr_pend1_size  <= 3'b010;
            wr_pend0_wstrb <= 4'b0;
            wr_pend1_wstrb <= 4'b0;
        end
        else begin
            // 写请求和数据握手成功，就存入追踪器
            if (aw_w_done) begin
                if (!wr_pend0_valid) begin
                    wr_pend0_valid <= 1'b1;
                    wr_pend0_addr  <= awaddr_r;
                    wr_pend0_size  <= awsize_r;
                    wr_pend0_wstrb <= wstrb_r;
                end
                else if (!wr_pend1_valid) begin
                    wr_pend1_valid <= 1'b1;
                    wr_pend1_addr  <= awaddr_r;
                    wr_pend1_size  <= awsize_r;
                    wr_pend1_wstrb <= wstrb_r;
                end
            end

            // 写响应握手就释放一次
            if (bvalid && bready_r) begin
                if (wr_pend0_valid)
                    wr_pend0_valid <= 1'b0;
                else if (wr_pend1_valid)
                    wr_pend1_valid <= 1'b0;
            end
        end
    end

    // ========== 写响应相关实现 ==========
    always @(posedge clk) begin
        if (reset) begin
            b_pending_cnt <= 2'd0;
            bready_r      <= 1'b1;
        end
        else begin
            bready_r <= 1'b1;

            case ({aw_w_done, bvalid && bready_r})
                2'b10: b_pending_cnt <= b_pending_cnt + 2'd1;
                2'b01: b_pending_cnt <= b_pending_cnt - 2'd1;
                2'b11: b_pending_cnt <= b_pending_cnt;
                default: b_pending_cnt <= b_pending_cnt;
            endcase
        end
    end

    // 写有关data_ok生成
    assign data_sram_data_ok_wr = bvalid && bready_r && (b_pending_cnt > 0);
    assign data_sram_data_ok    = data_sram_data_ok_rd || data_sram_data_ok_wr;

endmodule