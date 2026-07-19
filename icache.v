`include "mycpu.h"

module icache (
    // 时钟与复位
    input  wire                 clk,
    input  wire                 resetn,

    // CPU 流水线接口（只读）
    input  wire                    cpu_req,
    input  wire [`INDEX_WIDTH-1:0]  cpu_index,
    input  wire [ `TAG_WIDTH-1:0]   cpu_tag,
    input  wire [`OFFSET_WIDTH-1:0] cpu_offset,
    input  wire                    cpu_cached,
    output wire                    cpu_addr_ok,
    output wire                    cpu_data_ok,
    output wire [31:0]             cpu_rdata,
    input  wire                    cpu_accept,

    // AXI 读接口
    output wire                 rd_req,
    output wire [ 2:0]          rd_type,
    output wire [31:0]          rd_addr,
    input  wire                 rd_rdy,
    input  wire                 return_valid,
    input  wire                 return_last,
    input  wire [31:0]          return_data,
    output wire                 bus_accept,

    // CACOP 接口
    input  wire                    cacop_en,
    input  wire [ 4:0]             cacop_code,
    input  wire [31:0]             cacop_va,
    input  wire [`TAG_WIDTH-1:0]   cacop_tag,
    output wire                    cacop_rdy
);

    // ========== 局部参数 ==========
    localparam INDEX_DEPTH = 1 << `INDEX_WIDTH;
    localparam BANK_NUM    = 4;
    localparam WAY_IDX_W   = $clog2(`WAY_NUM);
    localparam PLRU_W      = `WAY_NUM - 1;
    localparam TAGV_BYTES  = (`TAG_WIDTH + 1 + 7) / 8;

    // I-cache 独热码：4 状态（无 SWAP——无 store 无 WB 碰撞）
    localparam MAIN_IDLE    = 4'b0001;
    localparam MAIN_LOOKUP  = 4'b0010;
    localparam MAIN_REPLACE = 4'b0100;
    localparam MAIN_REFILL  = 4'b1000;

    // ========== RAM 存储阵列 ==========
    reg                 d_ram    [0:`WAY_NUM-1][0:INDEX_DEPTH-1];
    wire [`TAG_WIDTH:0] tagv_rdata [0:`WAY_NUM-1];
    reg                 d_rdata    [0:`WAY_NUM-1];
    wire [31:0]         bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];

    // ========== 统一 RAM 读地址 ==========
    wire [`INDEX_WIDTH-1:0] ram_raddr_req;
    assign ram_raddr_req = (cacop_is_index || cacop_is_hit) ? cacop_index : cpu_index;

    // 预取发起
    wire launch_prefetch_idle;
    wire launch_prefetch_lookup;
    wire launch_prefetch;
    wire lookup_prefetch_cond;
    assign lookup_prefetch_cond = main_lookup && !prefetch_active && !cpu_req && !cacop_en;

    assign launch_prefetch_idle   = main_idle && prefetch_pending
                                  && !cpu_req && !cacop_en;
    assign launch_prefetch_lookup = lookup_prefetch_cond && cache_hit;
    assign launch_prefetch = launch_prefetch_idle || launch_prefetch_lookup;

    wire [31:0] next_line_addr;
    wire [31:0] launch_addr;
    assign next_line_addr = {req_tag, req_index, {`OFFSET_WIDTH{1'b0}}} + 32'd16;
    assign launch_addr    = launch_prefetch_lookup ? next_line_addr : prefetch_addr;

    wire ram_read_en;
    assign ram_read_en = accept_new_req || launch_prefetch;

    wire [`INDEX_WIDTH-1:0] ram_raddr;
    assign ram_raddr = launch_prefetch ? launch_addr[`OFFSET_WIDTH +: `INDEX_WIDTH]
                                       : ram_raddr_req;

    // ========== CACOP 逻辑 ==========
    wire cacop_is_index;
    wire cacop_is_hit;
    wire [`INDEX_WIDTH-1:0] cacop_index;
    wire [WAY_IDX_W-1:0] cacop_way;
    assign cacop_is_index  = cacop_en && (cacop_code[4:3] != 2'b10);
    assign cacop_is_hit    = cacop_en && (cacop_code[4:3] == 2'b10);
    assign cacop_index = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign cacop_way = cacop_va[WAY_IDX_W-1:0];

    // ========== 状态寄存器 ==========
    reg  [3:0] main_state;
    reg  [3:0] main_next;

    // ========== Request Buffer ==========
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`TAG_WIDTH-1:0]   req_tag;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg                     req_cached;
    reg                     cacop_en_r;
    reg  [4:0]              cacop_code_r;
    reg  [WAY_IDX_W-1:0]    cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;

    // ========== Miss Buffer ==========
    reg  [WAY_IDX_W-1:0] miss_replace_way;
    reg  [ 1:0] miss_refill_cnt;

    // ========== Refill Buffer ==========
    reg  [31:0] refill_buffer [0:BANK_NUM-1];

    // ========== Prefetch 寄存器 ==========
    reg         prefetch_pending;
    reg         prefetch_active;
    reg  [31:0] prefetch_addr;

    // ========== 树状伪 LRU ==========
    reg  [PLRU_W-1:0] plru [0:INDEX_DEPTH-1];

    // ========== 状态机节点 ==========
    wire main_idle    = (main_state == MAIN_IDLE);
    wire main_lookup  = (main_state == MAIN_LOOKUP);
    wire main_replace = (main_state == MAIN_REPLACE);
    wire main_refill  = (main_state == MAIN_REFILL);

    // ========== Prefetch 组合逻辑 ==========
    wire prefetch_cpu_match;
    assign prefetch_cpu_match = prefetch_active && cpu_req && cpu_cached
                              && (cpu_tag == req_tag) && (cpu_index == req_index);

    wire prefetch_mismatch;
    assign prefetch_mismatch = prefetch_active && cpu_req && !prefetch_cpu_match;

    wire prefetch_abort_req;
    assign prefetch_abort_req = prefetch_mismatch || (prefetch_active && cacop_en);

    wire prefetch_wr_kill;
    assign prefetch_wr_kill = prefetch_mismatch;

    // ========== Tag 比较与命中判断 ==========
    wire [`WAY_NUM-1:0] way_hit;
    genvar gh;
    generate
        for (gh = 0; gh < `WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign way_hit[gh] = tagv_rdata[gh][0]
                               && (tagv_rdata[gh][`TAG_WIDTH:1] == req_tag)
                               && (req_cached || cacop_en_r);
        end
    endgenerate

    wire cache_hit;
    assign cache_hit = (|way_hit) && !cacop_en_r;

    // ========== 替换 helper ==========
    reg  [WAY_IDX_W-1:0] hit_way_idx;
    integer hwi;
    always @(*) begin
        hit_way_idx = {WAY_IDX_W{1'b0}};
        for (hwi = 0; hwi < `WAY_NUM; hwi = hwi + 1)
            if (way_hit[hwi]) hit_way_idx = hwi[WAY_IDX_W-1:0];
    end

    reg  [WAY_IDX_W-1:0] invalid_way;
    reg                  has_invalid;
    integer vwi;
    always @(*) begin
        has_invalid = 1'b0;
        invalid_way = {WAY_IDX_W{1'b0}};
        for (vwi = `WAY_NUM-1; vwi >= 0; vwi = vwi - 1)
            if (!tagv_rdata[vwi][0]) begin
                has_invalid = 1'b1;
                invalid_way = vwi[WAY_IDX_W-1:0];
            end
    end

    // ========== 树状伪 LRU - 替换路预计算 ==========
    wire pre_plru_en;
    wire [`INDEX_WIDTH-1:0] pre_plru_index;
    assign pre_plru_en    = accept_new_req || launch_prefetch;
    assign pre_plru_index = launch_prefetch ? launch_addr[`OFFSET_WIDTH +: `INDEX_WIDTH]
                                            : ram_raddr_req;

    reg  [WAY_IDX_W:0]   plru_node_pre;
    integer plv_pre;
    always @(*) begin
        plru_node_pre = 1;
        for (plv_pre = 0; plv_pre < WAY_IDX_W; plv_pre = plv_pre + 1)
            plru_node_pre = (plru_node_pre << 1) + plru[pre_plru_index][plru_node_pre-1];
    end
    wire [WAY_IDX_W-1:0] plru_victim_pre;
    assign plru_victim_pre = plru_node_pre - `WAY_NUM;

    reg  [WAY_IDX_W-1:0] plru_victim_r;
    always @(posedge clk) begin
        if (~resetn) begin
            plru_victim_r <= {WAY_IDX_W{1'b0}};
        end
        else if (pre_plru_en) begin
            plru_victim_r <= plru_victim_pre;
        end
    end

    wire [WAY_IDX_W-1:0] victim_way;
    assign victim_way = has_invalid ? invalid_way : plru_victim_r;

    // I-cache 无 VC、无 store → 目标行永远干净，无 WB 碰撞
    wire need_bus_rd;
    assign need_bus_rd = !cacop_en_r;

    // ========== 新请求接受标志 ==========
    wire lookup_accept_cond;
    assign lookup_accept_cond = main_lookup && accept_ok && (cpu_req || cacop_en);

    wire prefetch_abort_accept;
    assign prefetch_abort_accept = (main_lookup  && !cache_hit && prefetch_abort_req)
                                || (main_replace && prefetch_abort_req)
                                || (main_refill  && return_valid && return_last && prefetch_wr_kill);

    wire accept_new_req;
    assign accept_new_req = (main_idle && accept_ok && (cpu_req || cacop_en))
                         || (lookup_accept_cond && cache_hit)
                         || (prefetch_abort_accept && accept_ok);

    // ========== 主状态机 - 时序 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            main_state <= MAIN_IDLE;
        end
        else begin
            main_state <= main_next;
        end
    end

    // ========== 主状态机 - 下一状态逻辑（I-cache：无 SWAP、无 store、无 VC） ==========
    wire rd_req_lookup;
    assign rd_req_lookup = main_lookup && !cache_hit
                         && need_bus_rd
                         && !prefetch_abort_req;

    always @(*) begin
        case (main_state)
            MAIN_IDLE: begin
                if (accept_new_req) begin
                    main_next = MAIN_LOOKUP;
                end
                else if (launch_prefetch_idle) begin
                    main_next = MAIN_LOOKUP;
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_LOOKUP: begin
                if (!cache_hit && prefetch_abort_req) begin
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                // clean miss + rd 直通
                else if (rd_req_lookup && rd_rdy) begin
                    main_next = MAIN_REFILL;
                end
                else if (!cache_hit) begin
                    main_next = MAIN_REPLACE;
                end
                else if (accept_new_req || launch_prefetch_lookup) begin
                    main_next = MAIN_LOOKUP;
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_REPLACE: begin
                if (prefetch_abort_req) begin
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                else if (need_bus_rd) begin
                    main_next = rd_rdy ? MAIN_REFILL : MAIN_REPLACE;
                end
                else if (cacop_en_r) begin
                    main_next = MAIN_REFILL;
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_REFILL: begin
                if (return_valid && return_last || cacop_en_r) begin
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                else begin
                    main_next = MAIN_REFILL;
                end
            end
            default: begin
                main_next = MAIN_IDLE;
            end
        endcase
    end

    // ========== 树状伪 LRU - 命中/填充时标 MRU ==========
    wire                 plru_upd_en;
    wire [WAY_IDX_W-1:0] plru_upd_way;
    assign plru_upd_en  = (main_lookup && cache_hit && !prefetch_active)
                        || refill_d_we;
    assign plru_upd_way = (main_lookup && cache_hit) ? hit_way_idx
                                                     : miss_replace_way;

    integer pnode, pparent, pui, prst;
    always @(posedge clk) begin
        if (~resetn) begin
            for (prst = 0; prst < INDEX_DEPTH; prst = prst + 1)
                plru[prst] <= {PLRU_W{1'b0}};
        end
        else if (plru_upd_en) begin
            pnode = `WAY_NUM + plru_upd_way;
            for (pui = 0; pui < WAY_IDX_W; pui = pui + 1) begin
                pparent = pnode >> 1;
                plru[req_index][pparent-1] <= ~pnode[0];
                pnode = pparent;
            end
        end
    end

    // ========== Request Buffer ==========
    always @(posedge clk) begin
        if (accept_new_req) begin
            req_index   <= cacop_en ? cacop_index : cpu_index;
            req_tag     <= (cacop_en && cacop_is_hit) ? cacop_tag : cpu_tag;
            req_offset  <= cpu_offset;
            req_cached  <= cpu_cached;
            cacop_en_r  <= cacop_en;
            cacop_code_r    <= cacop_code;
            cacop_way_r     <= cacop_way;
            cacop_index_r   <= cacop_index;
            cacop_is_index_r <= cacop_is_index;
            cacop_is_hit_r   <= cacop_is_hit;
        end
        else if (launch_prefetch) begin
            req_index   <= launch_addr[`OFFSET_WIDTH +: `INDEX_WIDTH];
            req_tag     <= launch_addr[`INDEX_WIDTH + `OFFSET_WIDTH +: `TAG_WIDTH];
            req_offset  <= 4'b0;
            req_cached  <= 1'b1;
            cacop_en_r  <= 1'b0;
            cacop_code_r    <= 5'b0;
            cacop_way_r     <= {WAY_IDX_W{1'b0}};
            cacop_index_r   <= {`INDEX_WIDTH{1'b0}};
            cacop_is_index_r <= 1'b0;
            cacop_is_hit_r   <= 1'b0;
        end
        if (main_refill && cacop_en_r) begin
            cacop_en_r <= 1'b0;
        end
    end

    // ========== Miss Buffer ==========
    always @(posedge clk) begin
        if (~resetn) begin
            miss_replace_way <= {WAY_IDX_W{1'b0}};
            miss_refill_cnt  <= 2'd0;
        end
        else begin
            if (main_lookup && !cache_hit) begin
                if (cacop_en_r) begin
                    if (cacop_code_r[4:3] == 2'b10)
                        miss_replace_way <= hit_way_idx;
                    else
                        miss_replace_way <= cacop_way_r;
                end
                else begin
                    miss_replace_way <= victim_way;
                end
            end
            if ((main_lookup && rd_req_lookup && rd_rdy)
             || (main_replace && need_bus_rd && rd_rdy)) begin
                miss_refill_cnt <= 2'd0;
            end
            else if (main_refill && return_valid) begin
                miss_refill_cnt <= miss_refill_cnt + 2'd1;
            end
        end
    end

    // ========== Prefetch 状态管理 ==========
    wire set_prefetch_pending;
    assign set_prefetch_pending = !prefetch_active
        && ((main_lookup && cache_hit && main_next == MAIN_IDLE)
         || (main_refill && return_valid && return_last && main_next == MAIN_IDLE));

    always @(posedge clk) begin
        if (~resetn) begin
            prefetch_pending    <= 1'b0;
            prefetch_active     <= 1'b0;
            prefetch_addr       <= 32'b0;
        end
        else begin
            if (set_prefetch_pending) begin
                prefetch_pending <= 1'b1;
                prefetch_addr    <= next_line_addr;
            end
            else if (accept_new_req || launch_prefetch) begin
                prefetch_pending <= 1'b0;
            end

            if (launch_prefetch) begin
                prefetch_active <= 1'b1;
            end
            else if (accept_new_req || (main_next == MAIN_IDLE)) begin
                prefetch_active <= 1'b0;
            end
        end
    end

    // ========== Data Select - 命中路选字 ==========
    wire [31:0] hit_word;
    assign hit_word = bank_rdata[hit_way_idx][req_offset[3:2]];

    // ========== Refill Buffer ==========
    always @(posedge clk) begin
        if (main_refill && return_valid && req_cached) begin
            refill_buffer[miss_refill_cnt] <= return_data;
        end
    end

    // ========== {Tag, V} RAM ==========
    wire refill_tagv_we;
    assign refill_tagv_we = (main_refill && return_valid && return_last && req_cached
                          || main_refill && cacop_en_r);

    wire cacop_code00 = cacop_en_r && (cacop_code_r[4:3] == 2'b00);
    wire cacop_code01 = cacop_en_r && (cacop_code_r[4:3] == 2'b01);
    wire cacop_code10 = cacop_en_r && (cacop_code_r[4:3] == 2'b10);

    wire tagv_do_write;
    assign tagv_do_write = refill_tagv_we
                         && ( !cacop_en_r
                            || cacop_code00
                            || cacop_code01
                            || (cacop_code10 && (|way_hit)) );

    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel;
    wire [ 3:0]            tagv_wmask_sel;
    wire [`TAG_WIDTH:0]     tagv_wdata_sel;
    assign tagv_waddr_sel = (cacop_code00 || cacop_code01) ? cacop_index_r : req_index;
    assign tagv_wmask_sel = (cacop_code01 || cacop_code10) ? 4'b0001
                                                           : {TAGV_BYTES{1'b1}};
    assign tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }
                                       : {req_tag, 1'b1};

    wire                    tagv_en   [0:`WAY_NUM-1];
    wire [ 3:0]            tagv_wen  [0:`WAY_NUM-1];
    wire [`INDEX_WIDTH-1:0] tagv_addr [0:`WAY_NUM-1];

    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire tagv_wr = tagv_do_write && (miss_replace_way == gt);
            assign tagv_en[gt]   = tagv_wr || ram_read_en;
            assign tagv_wen[gt]  = tagv_wr ? tagv_wmask_sel : 4'b0;
            assign tagv_addr[gt] = tagv_wr ? tagv_waddr_sel : ram_raddr;

            sp_ram #(
                .WIDTH (`TAG_WIDTH + 1),
                .DEPTH (INDEX_DEPTH),
                .ADDRW (`INDEX_WIDTH)
            ) u_tagv_ram (
                .clk   (clk),
                .en    (tagv_en[gt]),
                .wen   (tagv_wen[gt]),
                .addr  (tagv_addr[gt]),
                .wdata ({ {32-(`TAG_WIDTH+1){1'b0}}, tagv_wdata_sel }),
                .rdata (tagv_rdata[gt])
            );
        end
    endgenerate

    // ========== D RAM - I-cache 永远干净（只存储 0，保持结构一致） ==========
    wire refill_d_we;
    assign refill_d_we = main_refill && return_valid && return_last && req_cached;

    integer d_wi;
    integer d_idx;
    always @(posedge clk) begin
        if (~resetn) begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                for (d_idx = 0; d_idx < INDEX_DEPTH; d_idx = d_idx + 1) begin
                    d_ram[d_wi][d_idx] <= 1'b0;
                end
            end
        end
        else begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                // I-cache 无 store → d 永远 0，REFILL 也写 0
                if (ram_read_en) begin
                    d_rdata[d_wi] <= d_ram[d_wi][ram_raddr];
                end
            end
        end
    end

    // ========== Data Bank RAM ==========
    wire                    bank_wr_refill [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire                    bank_en        [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [ 3:0]             bank_wen       [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [`INDEX_WIDTH-1:0] bank_addr      [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [31:0]             bank_wdata     [0:`WAY_NUM-1][0:BANK_NUM-1];

    genvar gw, gb;
    generate
        for (gw = 0; gw < `WAY_NUM; gw = gw + 1) begin : bank_ram_way
            for (gb = 0; gb < BANK_NUM; gb = gb + 1) begin : bank_ram_col
                assign bank_wr_refill[gw][gb] = main_refill && return_valid && return_last
                                              && (miss_replace_way == gw)
                                              && req_cached;

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb] || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 4'b1111 : 4'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? req_index : ram_raddr;
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb]
                                          ? ((miss_refill_cnt == gb) ? return_data : refill_buffer[gb])
                                          : 32'b0;

                sp_ram #(
                    .WIDTH (32),
                    .DEPTH (INDEX_DEPTH),
                    .ADDRW (`INDEX_WIDTH)
                ) u_bank_ram (
                    .clk   (clk),
                    .en    (bank_en[gw][gb]),
                    .wen   (bank_wen[gw][gb]),
                    .addr  (bank_addr[gw][gb]),
                    .wdata (bank_wdata[gw][gb]),
                    .rdata (bank_rdata[gw][gb])
                );
            end
        end
    endgenerate

    // ========== 输出 FIFO ==========
    reg  [31:0] cpu_fifo_mem [0:3];
    reg  [ 1:0] cpu_fifo_wptr;
    reg  [ 1:0] cpu_fifo_rptr;
    reg  [ 2:0] cpu_fifo_cnt;

    wire cpu_fifo_full;
    wire cpu_fifo_empty;
    wire cpu_fifo_we;
    wire cpu_fifo_re;
    assign cpu_fifo_full  = (cpu_fifo_cnt == 3'd4);
    assign cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);

    wire read_hit_done;
    wire read_miss_done;
    assign read_hit_done  = main_lookup && cache_hit && !prefetch_active;
    assign read_miss_done = main_refill && return_valid && !prefetch_active
                          && (miss_refill_cnt == req_offset[3:2] || !req_cached);

    wire read_result_ready;
    wire [31:0] live_rdata;
    assign read_result_ready = read_hit_done || read_miss_done;
    assign live_rdata = read_hit_done  ? hit_word
                      : read_miss_done ? return_data
                                       : 32'd0;

    wire cpu_takes_live;
    assign cpu_takes_live = cpu_accept && cpu_fifo_empty && read_result_ready;
    assign cpu_fifo_we    = read_result_ready && !cpu_takes_live;
    assign cpu_fifo_re    = cpu_accept && !cpu_fifo_empty;

    // I-cache 只读 → FIFO 空位只需 ≥ 2（当前请求 + 新请求）
    wire accept_ok;
    assign accept_ok = (cpu_fifo_cnt < 3'd3);

    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign bus_accept  = 1'b1;
    assign cpu_data_ok = read_result_ready || !cpu_fifo_empty;
    assign cpu_rdata   = cpu_fifo_empty ? live_rdata : cpu_fifo_mem[cpu_fifo_rptr];

    integer oi;
    always @(posedge clk) begin
        if (~resetn) begin
            cpu_fifo_wptr <= 2'd0;
            cpu_fifo_rptr <= 2'd0;
            cpu_fifo_cnt  <= 3'd0;
            for (oi = 0; oi < 4; oi = oi + 1)
                cpu_fifo_mem[oi] <= 32'b0;
        end
        else begin
            case ({cpu_fifo_we, cpu_fifo_re})
                2'b10: begin
                    cpu_fifo_mem[cpu_fifo_wptr] <= live_rdata;
                    cpu_fifo_wptr <= cpu_fifo_wptr + 2'd1;
                    cpu_fifo_cnt  <= cpu_fifo_cnt  + 3'd1;
                end
                2'b01: begin
                    cpu_fifo_rptr <= cpu_fifo_rptr + 2'd1;
                    cpu_fifo_cnt  <= cpu_fifo_cnt  - 3'd1;
                end
                2'b11: begin
                    cpu_fifo_mem[cpu_fifo_wptr] <= live_rdata;
                    cpu_fifo_wptr <= cpu_fifo_wptr + 2'd1;
                    cpu_fifo_rptr <= cpu_fifo_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    // ========== AXI 读请求 ==========
    assign rd_req = rd_req_lookup
                  || (main_replace && need_bus_rd && !prefetch_abort_req);

    assign rd_type = req_cached ? 3'b100 : 3'b010;   // I-cache 只发 cached burst 或 uncached 字
    assign rd_addr = req_cached
                   ? {req_tag, req_index, 4'b0000}
                   : {req_tag, req_index, req_offset};

`ifndef SYNTHESIS
    // ========== 仿真断言 ==========
    always @(posedge clk) begin
        if (resetn && main_lookup && req_cached && !cacop_en_r) begin
            // no-op: I-cache 无 VC，无 L1∩VC 不变量需检查
        end
    end
`endif

    // ========== 性能计数器 ==========
    reg [31:0] perf_total_req  /*verilator public*/;
    reg [31:0] perf_access_cnt /*verilator public*/;
    reg [31:0] perf_miss_cnt   /*verilator public*/;
    reg [31:0] perf_real_miss_cnt /*verilator public*/;
    reg [31:0] perf_prefetch_launch /*verilator public*/;
    reg [31:0] perf_prefetch_abort  /*verilator public*/;
    reg [31:0] perf_prefetch_fill   /*verilator public*/;
    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
            perf_prefetch_launch  <= 32'd0;
            perf_prefetch_abort   <= 32'd0;
            perf_prefetch_fill    <= 32'd0;
        end
        else begin
            if (accept_new_req) begin
                perf_total_req <= perf_total_req + 32'd1;
            end
            if (main_lookup && req_cached && !cacop_en_r && !prefetch_active) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit) begin
                    perf_miss_cnt <= perf_miss_cnt + 32'd1;
                    perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
                end
            end
            if (launch_prefetch) begin
                perf_prefetch_launch <= perf_prefetch_launch + 32'd1;
            end
            if (prefetch_active) begin
                if ((main_lookup  && !cache_hit && prefetch_abort_req)
                 || (main_replace && prefetch_abort_req)) begin
                    perf_prefetch_abort <= perf_prefetch_abort + 32'd1;
                end
                else if (main_refill && return_valid && return_last && req_cached) begin
                    perf_prefetch_fill <= perf_prefetch_fill + 32'd1;
                end
            end
        end
   end
endmodule
