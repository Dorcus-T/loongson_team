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
    output wire         data_sram_data_ok_wr,
    output wire         data_sram_data_ok_rd,
    output wire [31:0]  data_sram_rdata,

    // CPU 可接受读数据（取指/访存各自独立）
    input  wire         inst_cpu_accept,
    input  wire         data_cpu_accept,

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

    // ========== 写请求追踪器（4项 FIFO，用于地址冲突检测） ==========
    reg [31:0] wr_pend_addr [0:3];
    reg [ 2:0] wr_pend_size [0:3];
    reg [ 3:0] wr_pend_wstrb[0:3];
    reg [ 1:0] wr_pend_wptr;
    reg [ 1:0] wr_pend_rptr;
    reg [ 2:0] wr_pend_cnt;
    wire       wr_pend_full;
    wire       wr_pend_empty;
    wire       wr_pend_push;
    wire       wr_pend_pop;
    wire       aw_w_done;

    assign wr_pend_full  = (wr_pend_cnt == 3'd4);
    assign wr_pend_empty = (wr_pend_cnt == 3'd0);

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
        integer       k;
        begin
            addr_conflict = 1'b0;
            rd_end = rd_addr + size_bytes(rd_size) - 1;
            for (k = 0; k < 4; k = k + 1) begin
                if (((k - wr_pend_rptr) & 2'd3) < wr_pend_cnt) begin
                    wr_end = wr_pend_addr[k] + size_bytes(wr_pend_size[k]) - 1;
                    if (!(rd_end < wr_pend_addr[k] || rd_addr > wr_end)) begin
                        addr_conflict = 1'b1;
                    end
                end
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

    // ========== inst 读响应 FIFO（4项） ==========
    reg [31:0] inst_fifo_mem [0:3];
    reg [ 1:0] inst_fifo_wptr;
    reg [ 1:0] inst_fifo_rptr;
    reg [ 2:0] inst_fifo_cnt;

    wire       inst_fifo_full;
    wire       inst_fifo_empty;
    wire       inst_fifo_we;
    wire       inst_fifo_re;

    assign inst_fifo_full  = (inst_fifo_cnt == 3'd4);
    assign inst_fifo_empty = (inst_fifo_cnt == 3'd0);

    // FIFO 写：AXI 返回取指数据，FIFO 空且 CPU 可接受时直通、否则缓冲
    assign inst_fifo_we = rvalid && rready && (rid == 4'd0) && !inst_cpu_accept;

    // FIFO 读：CPU 可接受且 FIFO 非空（消费时弹出）
    assign inst_fifo_re = inst_cpu_accept && !inst_fifo_empty;

    // ========== data 读响应 FIFO（4项） ==========
    reg [31:0] data_fifo_mem [0:3];
    reg [ 1:0] data_fifo_wptr;
    reg [ 1:0] data_fifo_rptr;
    reg [ 2:0] data_fifo_cnt;

    wire       data_fifo_full;
    wire       data_fifo_empty;
    wire       data_fifo_we;
    wire       data_fifo_re;

    assign data_fifo_full  = (data_fifo_cnt == 3'd4);
    assign data_fifo_empty = (data_fifo_cnt == 3'd0);

    // FIFO 写：AXI 返回访存数据，FIFO 空且 CPU 可接受时直通、否则缓冲
    assign data_fifo_we = rvalid && rready && (rid == 4'd1) && !data_cpu_accept;

    // FIFO 读：CPU 可接受且 FIFO 非空（消费时弹出）
    assign data_fifo_re = data_cpu_accept && !data_fifo_empty;

    // ========== rready：两侧都能接数据时才拉高 ==========
    wire inst_ready = !inst_fifo_full || inst_cpu_accept;
    wire data_ready = !data_fifo_full || data_cpu_accept;
    assign rready = inst_ready && data_ready;

    // ========== 写请求相关信号 ==========
    localparam AW_W_IDLE = 2'd0;
    localparam AW_W_BUSY = 2'd1;

    reg  [ 1:0] aw_w_state, aw_w_next;
    reg         aw_done_r;
    reg         w_done_r;
    wire        data_sram_addr_ok_wr;

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

    // ============================================================
    // inst 读响应 FIFO 控制
    // ============================================================
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            inst_fifo_wptr <= 2'd0;
            inst_fifo_rptr <= 2'd0;
            inst_fifo_cnt  <= 3'd0;
            for (i = 0; i < 4; i = i + 1)
                inst_fifo_mem[i] <= 32'b0;
        end
        else begin
            case ({inst_fifo_we, inst_fifo_re})
                2'b10: begin
                    inst_fifo_mem[inst_fifo_wptr] <= rdata;
                    inst_fifo_wptr <= inst_fifo_wptr + 2'd1;
                    inst_fifo_cnt  <= inst_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    inst_fifo_rptr <= inst_fifo_rptr + 2'd1;
                    inst_fifo_cnt  <= inst_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    inst_fifo_mem[inst_fifo_wptr] <= rdata;
                    inst_fifo_wptr <= inst_fifo_wptr + 2'd1;
                    inst_fifo_rptr <= inst_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // data 读响应 FIFO 控制
    // ============================================================
    integer j;
    always @(posedge clk) begin
        if (reset) begin
            data_fifo_wptr <= 2'd0;
            data_fifo_rptr <= 2'd0;
            data_fifo_cnt  <= 3'd0;
            for (j = 0; j < 4; j = j + 1)
                data_fifo_mem[j] <= 32'b0;
        end
        else begin
            case ({data_fifo_we, data_fifo_re})
                2'b10: begin
                    data_fifo_mem[data_fifo_wptr] <= rdata;
                    data_fifo_wptr <= data_fifo_wptr + 2'd1;
                    data_fifo_cnt  <= data_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    data_fifo_rptr <= data_fifo_rptr + 2'd1;
                    data_fifo_cnt  <= data_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    data_fifo_mem[data_fifo_wptr] <= rdata;
                    data_fifo_wptr <= data_fifo_wptr + 2'd1;
                    data_fifo_rptr <= data_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ============================================================
    // 读响应输出（纯数据可用性，不依赖 cpu_accept）
    // ============================================================
    assign inst_sram_data_ok = !inst_fifo_empty || (rvalid && (rid == 4'd0));
    assign inst_sram_rdata   = inst_fifo_empty ? rdata : inst_fifo_mem[inst_fifo_rptr];
    assign data_sram_data_ok_rd = !data_fifo_empty || (rvalid && (rid == 4'd1));
    assign data_sram_rdata      = data_fifo_empty ? rdata : data_fifo_mem[data_fifo_rptr];

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

    assign data_sram_addr_ok_wr = (aw_w_state == AW_W_IDLE) && !wr_pend_full;

    // ========== 写请求追踪器 ==========
    // 写请求和写数据已经握手的信号
    assign aw_w_done = (aw_w_state == AW_W_BUSY) &&
                       (aw_done_r || (awvalid_r && awready)) &&
                       (w_done_r  || (wvalid_r && wready));

    assign wr_pend_push = aw_w_done;
    assign wr_pend_pop  = bvalid && bready;

    integer p;
    always @(posedge clk) begin
        if (reset) begin
            wr_pend_wptr <= 2'd0;
            wr_pend_rptr <= 2'd0;
            wr_pend_cnt  <= 3'd0;
            for (p = 0; p < 4; p = p + 1) begin
                wr_pend_addr[p]  <= 32'b0;
                wr_pend_size[p]  <= 3'b010;
                wr_pend_wstrb[p] <= 4'b0;
            end
        end
        else begin
            case ({wr_pend_push, wr_pend_pop})
                2'b10: begin
                    wr_pend_addr[wr_pend_wptr]  <= awaddr_r;
                    wr_pend_size[wr_pend_wptr]  <= awsize_r;
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
                    wr_pend_size[wr_pend_wptr]  <= awsize_r;
                    wr_pend_wstrb[wr_pend_wptr] <= wstrb_r;
                    wr_pend_wptr <= wr_pend_wptr + 2'd1;
                    wr_pend_rptr <= wr_pend_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ========== 写响应相关实现 ==========
    assign bready = !wr_pend_empty;

    // 写有关data_ok生成
    assign data_sram_data_ok_wr = bvalid && bready && !wr_pend_empty;

endmodule
