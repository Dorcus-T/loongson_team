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

    // ============================================================
    // 局部参数
    // ============================================================
    localparam INDEX_DEPTH = 1 << `INDEX_WIDTH;
    localparam BANK_NUM    = 4;
    localparam WAY_IDX_W   = $clog2(`WAY_NUM);
    localparam PLRU_W      = `WAY_NUM - 1;
    localparam TAGV_BYTES  = (`TAG_WIDTH + 1 + 7) / 8;

    localparam MAIN_IDLE   = 4'b0001;
    localparam MAIN_LOOKUP = 4'b0010;
    localparam MAIN_WAITRD = 4'b0100;
    localparam MAIN_REFILL = 4'b1000;

    // ============================================================
    // RAM 存储阵列
    // ============================================================
    wire [`TAG_WIDTH:0] tagv_rdata [0:`WAY_NUM-1];
    wire [31:0]         bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];

    // ============================================================
    // 状态寄存器
    // ============================================================
    reg  [3:0] main_state;
    reg  [3:0] main_next;

    // ============================================================
    // 状态机节点
    // ============================================================
    wire main_idle   = (main_state == MAIN_IDLE);
    wire main_lookup = (main_state == MAIN_LOOKUP);
    wire main_waitrd = (main_state == MAIN_WAITRD);
    wire main_refill = (main_state == MAIN_REFILL);

    // ============================================================
    // Request Buffer — accept_new_req 时更新
    // ============================================================
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`TAG_WIDTH-1:0]   req_tag;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg                     req_cached;
    reg                     req_is_prefetch;
    reg                     cacop_en_r;
    reg  [4:0]              cacop_code_r;
    reg  [WAY_IDX_W-1:0]    cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;

    // ============================================================
    // Refill Buffer — enter_refill 时从 Request Buffer 快照，REFILL 期间不变
    // ============================================================
    reg  [`INDEX_WIDTH-1:0]  refill_index;
    reg  [`TAG_WIDTH-1:0]   refill_tag;
    reg  [`OFFSET_WIDTH-1:0] refill_offset;
    reg                     refill_cached;
    reg                     refill_is_prefetch;
    reg  [WAY_IDX_W-1:0]    refill_replace_way;
    reg  [ 1:0]             refill_cnt;
    reg  [31:0]             refill_line [0:BANK_NUM-1];

    // ============================================================
    // 顶层标志
    // ============================================================
    reg  refill_already_accept_new_req; // REFILL 期间 accept 了一个新请求，待 REFILL 后进 LOOKUP

    // ============================================================
    // 树状伪 LRU
    // ============================================================
    reg  [PLRU_W-1:0] plru [0:INDEX_DEPTH-1];

    // ============================================================
    // CACOP 辅助信号
    // ============================================================
    wire cacop_is_index;
    wire cacop_is_hit;
    wire [`INDEX_WIDTH-1:0] cacop_index;
    wire [WAY_IDX_W-1:0]    cacop_way;
    assign cacop_is_index = cacop_en && (cacop_code[4:3] != 2'b10);
    assign cacop_is_hit   = cacop_en && (cacop_code[4:3] == 2'b10);
    assign cacop_index    = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign cacop_way      = cacop_va[WAY_IDX_W-1:0];

    // ============================================================
    // 统一 RAM 读地址
    // ============================================================
    wire [`INDEX_WIDTH-1:0] ram_raddr_req;
    assign ram_raddr_req = (cacop_is_index || cacop_is_hit) ? cacop_index : cpu_index;

    // ============================================================
    // prefetch 预取
    // ============================================================
    wire prefetch_idle;
    wire prefetch_lookup;
    assign prefetch_idle   = main_idle && !cpu_req && !cacop_en && !refill_is_prefetch;
    assign prefetch_lookup = main_lookup && cache_inst_hit && !cpu_req && !cacop_en && !req_is_prefetch;

    wire last_offset;
    assign last_offset = prefetch_lookup ? (req_offset[3:2] == 2'b11)
                                         : (refill_offset[3:2] == 2'b11);
    wire launch_prefetch_idle;
    wire launch_prefetch_lookup;
    wire launch_prefetch;
    assign launch_prefetch_idle   = prefetch_idle && last_offset;
    assign launch_prefetch_lookup = prefetch_lookup && last_offset;
    assign launch_prefetch        = launch_prefetch_idle || launch_prefetch_lookup;

    // 下一行地址 = {tag, index, 4'b0} + 16
    wire [31:0] prefetch_base_addr;
    wire [31:0] prefetch_next_addr;
    assign prefetch_base_addr = prefetch_lookup
                              ? {req_tag, req_index, {`OFFSET_WIDTH{1'b0}}}
                              : {refill_tag, refill_index, {`OFFSET_WIDTH{1'b0}}};
    assign prefetch_next_addr = prefetch_base_addr + 32'd16;

    wire [`INDEX_WIDTH-1:0]  prefetch_index;
    wire [`TAG_WIDTH-1:0]    prefetch_tag;
    wire [`OFFSET_WIDTH-1:0] prefetch_offset;
    assign prefetch_index  = prefetch_next_addr[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign prefetch_tag    = prefetch_next_addr[`INDEX_WIDTH + `OFFSET_WIDTH +: `TAG_WIDTH];
    assign prefetch_offset = {`OFFSET_WIDTH{1'b0}};

    wire prefetch_match_after_shake;
    wire prefetch_can_cancel;
    assign prefetch_match_after_shake = main_refill && refill_is_prefetch
                                      && (refill_index == cpu_index)
                                      && (refill_tag   == cpu_tag)
                                      && !cacop_en && cpu_req && cpu_cached;
    assign prefetch_can_cancel = (main_lookup || main_waitrd) && req_is_prefetch
                               && ((cpu_req && cpu_cached) || cacop_en);

    // ============================================================
    // accept_new_req
    // ============================================================
    wire idle_accept;
    wire hit_accept;
    wire refill_early_accept;

    assign idle_accept   = main_idle && (cpu_req || cacop_en);
    assign hit_accept    = main_lookup && cache_inst_hit && (cpu_req || cacop_en);
    assign refill_early_accept = main_refill && !refill_last
                               && !refill_is_prefetch
                               && !refill_already_accept_new_req
                               && !cacop_en_r
                               && !cacop_en
                               && cpu_req
                               && req_cached;

    wire accept_new_req;
    assign accept_new_req = (idle_accept && accept_ok)
                         || (hit_accept && accept_ok)
                         || (refill_early_accept && accept_ok)
                         || (launch_prefetch && accept_ok)
                         || (prefetch_can_cancel && accept_ok);

    // ============================================================
    // RAM 读控制
    // ============================================================
    wire ram_read_en;
    assign ram_read_en = accept_new_req;

    wire [`INDEX_WIDTH-1:0] ram_raddr;
    assign ram_raddr = launch_prefetch ? prefetch_index : ram_raddr_req;

    // ============================================================
    // REFILL 节拍
    // ============================================================
    wire refill_last;
    assign refill_last = main_refill && return_valid && return_last;

    // ============================================================
    // enter_refill — 状态转换条件
    // ============================================================
    wire enter_refill;
    assign enter_refill = (main_lookup && cacop_en_r)
                        || (main_lookup && !cache_inst_hit && rd_rdy)
                        || (main_waitrd && rd_rdy);

    // ============================================================
    // 主状态机 — 时序
    // ============================================================
    always @(posedge clk) begin
        if (~resetn)
            main_state <= MAIN_IDLE;
        else
            main_state <= main_next;
    end

    // ============================================================
    // 主状态机 — 下一状态逻辑
    // ============================================================
    always @(*) begin
        case (main_state)
            MAIN_IDLE: begin
                if (accept_new_req)
                    main_next = MAIN_LOOKUP;
                else
                    main_next = MAIN_IDLE;
            end
            MAIN_LOOKUP: begin
                if (cacop_en_r)
                    main_next = MAIN_REFILL;
                else if (prefetch_can_cancel)
                    main_next = MAIN_LOOKUP;
                else if (!cache_inst_hit && rd_rdy)
                    main_next = MAIN_REFILL;
                else if (!cache_inst_hit)
                    main_next = MAIN_WAITRD;
                else if (accept_new_req)
                    main_next = MAIN_LOOKUP;
                else
                    main_next = MAIN_IDLE;
            end
            MAIN_WAITRD: begin
                if (prefetch_can_cancel)
                    main_next = MAIN_LOOKUP;
                else if (rd_rdy)
                    main_next = MAIN_REFILL;
                else
                    main_next = MAIN_WAITRD;
            end
            MAIN_REFILL: begin
                if (refill_last || cacop_en_r) begin
                    if (cacop_en_r || !refill_cached)
                        main_next = MAIN_IDLE;
                    else if (refill_already_accept_new_req)
                        main_next = MAIN_LOOKUP;
                    else
                        main_next = MAIN_IDLE;
                end
                else
                    main_next = MAIN_REFILL;
            end
            default: main_next = MAIN_IDLE;
        endcase
    end

    // ============================================================
    // Tag/Data Bypass — LOOKUP-from-early-accept 时用 refill 数据替代过期 RAM 输出
    // ============================================================
    wire bypass_active;
    assign bypass_active = main_lookup && refill_already_accept_new_req
                         && (req_index == refill_index);

    wire [`TAG_WIDTH:0] tagv_lookup [0:`WAY_NUM-1];
    genvar gb_byp;
    generate
        for (gb_byp = 0; gb_byp < `WAY_NUM; gb_byp = gb_byp + 1) begin : tagv_bypass_gen
            assign tagv_lookup[gb_byp] = (bypass_active && (gb_byp[WAY_IDX_W-1:0] == refill_replace_way))
                                      ? {refill_tag, 1'b1}
                                      : tagv_rdata[gb_byp];
        end
    endgenerate

    // ============================================================
    // Tag 比较与命中判断
    // ============================================================
    wire [`WAY_NUM-1:0] way_hit;
    genvar gh;
    generate
        for (gh = 0; gh < `WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign way_hit[gh] = tagv_lookup[gh][0]
                               && (tagv_lookup[gh][`TAG_WIDTH:1] == req_tag)
                               && (req_cached || cacop_en_r);
        end
    endgenerate

    wire cache_inst_hit;
    assign cache_inst_hit = (|way_hit) && !cacop_en_r;

    // ============================================================
    // 命中路号编码
    // ============================================================
    reg  [WAY_IDX_W-1:0] hit_way_idx;
    integer hwi;
    always @(*) begin
        hit_way_idx = {WAY_IDX_W{1'b0}};
        for (hwi = 0; hwi < `WAY_NUM; hwi = hwi + 1)
            if (way_hit[hwi]) hit_way_idx = hwi[WAY_IDX_W-1:0];
    end

    // ============================================================
    // 无效路查找（使用 bypass 后的 tagv 视图）
    // ============================================================
    reg  [WAY_IDX_W-1:0] invalid_way;
    reg                  has_invalid;
    integer vwi;
    always @(*) begin
        has_invalid = 1'b0;
        invalid_way = {WAY_IDX_W{1'b0}};
        for (vwi = `WAY_NUM-1; vwi >= 0; vwi = vwi - 1)
            if (!tagv_lookup[vwi][0]) begin
                has_invalid = 1'b1;
                invalid_way = vwi[WAY_IDX_W-1:0];
            end
    end

    // ============================================================
    // 受害者路号 — LOOKUP 拍组合逻辑
    // ============================================================
    wire [WAY_IDX_W-1:0] victim_way;
    assign victim_way = cacop_en_r
                      ? (cacop_is_hit_r ? hit_way_idx : cacop_way_r)
                      : has_invalid ? invalid_way
                      : plru_victim_r;

    // ============================================================
    // PLRU 预计算 — accept 拍遍历 PLRU 树
    // ============================================================
    wire                 pre_plru_en;
    wire [`INDEX_WIDTH-1:0] pre_plru_index;
    assign pre_plru_en    = accept_new_req;
    assign pre_plru_index = launch_prefetch ? prefetch_index : ram_raddr_req;

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
        if (~resetn)
            plru_victim_r <= {WAY_IDX_W{1'b0}};
        else if (pre_plru_en)
            plru_victim_r <= plru_victim_pre;
    end

    // ============================================================
    // PLRU 更新 — 命中 / 填充时标 MRU
    // ============================================================
    wire                 plru_upd_en;
    wire [WAY_IDX_W-1:0] plru_upd_way;
    wire [`INDEX_WIDTH-1:0] plru_upd_index;
    assign plru_upd_en    = (main_lookup && cache_inst_hit && !req_is_prefetch)
                          || refill_tagv_we;
    assign plru_upd_way   = (main_lookup && cache_inst_hit) ? hit_way_idx
                                                       : refill_replace_way;
    assign plru_upd_index = refill_tagv_we ? refill_index : req_index;

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
                plru[plru_upd_index][pparent-1] <= ~pnode[0];
                pnode = pparent;
            end
        end
    end

    // ============================================================
    // Request Buffer — 时序更新
    // ============================================================
    always @(posedge clk) begin
        if (~resetn) begin
            req_index        <= {`INDEX_WIDTH{1'b0}};
            req_tag          <= {`TAG_WIDTH{1'b0}};
            req_offset       <= {`OFFSET_WIDTH{1'b0}};
            req_cached       <= 1'b0;
            req_is_prefetch  <= 1'b0;
            cacop_en_r       <= 1'b0;
            cacop_code_r     <= 5'b0;
            cacop_way_r      <= {WAY_IDX_W{1'b0}};
            cacop_index_r    <= {`INDEX_WIDTH{1'b0}};
            cacop_is_index_r <= 1'b0;
            cacop_is_hit_r   <= 1'b0;
        end
        else if (accept_new_req) begin
            req_index        <= cacop_en ? cacop_index : (launch_prefetch ? prefetch_index : cpu_index);
            req_tag          <= (cacop_en && cacop_is_hit) ? cacop_tag : (launch_prefetch ? prefetch_tag : cpu_tag);
            req_offset       <= launch_prefetch ? prefetch_offset : cpu_offset;
            req_cached       <= launch_prefetch ? 1'b1 : cpu_cached;
            req_is_prefetch  <= launch_prefetch;
            cacop_en_r       <= launch_prefetch ? 1'b0 : cacop_en;
            cacop_code_r     <= cacop_code;
            cacop_way_r      <= cacop_way;
            cacop_index_r    <= cacop_index;
            cacop_is_index_r <= cacop_is_index;
            cacop_is_hit_r   <= cacop_is_hit;
        end
        else if (main_refill && cacop_en_r) begin
            cacop_en_r <= 1'b0;
        end
    end

    // ============================================================
    // Refill Buffer — LOOKUP miss 拍一次性锁存，整个 REFILL 期间不变
    // ============================================================
    always @(posedge clk) begin
        if (main_lookup && !cache_inst_hit) begin
            refill_index        <= req_index;
            refill_tag          <= req_tag;
            refill_offset       <= req_offset;
            refill_cached       <= req_cached;
            refill_is_prefetch  <= req_is_prefetch;
            refill_replace_way  <= victim_way;
            refill_cnt          <= 2'd0;
        end
        else if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= return_data;
        end
        else if (main_idle) begin
            refill_is_prefetch <= 1'b0;
        end
    end

    // ============================================================
    // refill_already_accept_new_req — 时序
    // ============================================================
    always @(posedge clk) begin
        if (~resetn)
            refill_already_accept_new_req <= 1'b0;
        else if (refill_early_accept && accept_ok)
            refill_already_accept_new_req <= 1'b1;
        else if (main_lookup || main_idle)
            refill_already_accept_new_req <= 1'b0;
    end

    // ============================================================
    // 数据选择 — 命中路选字
    // ============================================================
    wire [31:0] hit_word;
    assign hit_word = (bypass_active && (hit_way_idx == refill_replace_way))
                    ? refill_line[req_offset[3:2]]
                    : bank_rdata[hit_way_idx][req_offset[3:2]];

    // ============================================================
    // 读结果就绪判断
    // ============================================================
    wire read_hit_done;
    wire read_miss_done;
    assign read_hit_done  = main_lookup && cache_inst_hit && !req_is_prefetch;
    assign read_miss_done = main_refill && return_valid && !refill_is_prefetch
                          && (refill_cnt == refill_offset[3:2] || !refill_cached);

    wire prefetch_match_data_ready;
    wire [31:0] prefetch_match_rdata;
    assign prefetch_match_data_ready = main_refill && return_valid && return_last
                                     && refill_is_prefetch && prefetch_match_after_shake;
    assign prefetch_match_rdata = (cpu_offset[3:2] == refill_cnt) ? return_data
                                                                  : refill_line[cpu_offset[3:2]];

    wire read_result_ready;
    assign read_result_ready = read_hit_done || read_miss_done || prefetch_match_data_ready;

    // ============================================================
    // 实时数据通路
    // ============================================================
    wire [31:0] live_rdata;
    assign live_rdata = read_hit_done              ? hit_word
                      : read_miss_done             ? return_data
                      : prefetch_match_data_ready  ? prefetch_match_rdata
                      : 32'd0;

    wire live_data_ready;
    assign live_data_ready = read_result_ready;

    wire cpu_takes_live;
    assign cpu_takes_live = cpu_accept && cpu_fifo_empty && live_data_ready;
    wire cpu_fifo_we;
    assign cpu_fifo_we = live_data_ready && !cpu_takes_live;
    wire cpu_fifo_re;
    assign cpu_fifo_re = cpu_accept && !cpu_fifo_empty;

    // ============================================================
    // accept_ok — FIFO 至少留 2 个空位（当前 + 下一请求）
    // ============================================================
    wire accept_ok;
    assign accept_ok = (cpu_fifo_cnt < 3'd3);

    // ============================================================
    // CPU / CACOP 接口
    // ============================================================
    assign cpu_addr_ok = (accept_new_req && !cacop_en)
                        || (main_refill && return_last && prefetch_match_after_shake && accept_ok);
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign bus_accept  = 1'b1;

    wire cpu_data_ok_comb;
    assign cpu_data_ok_comb = live_data_ready;
    assign cpu_data_ok = cpu_data_ok_comb || !cpu_fifo_empty;

    assign cpu_rdata = cpu_fifo_empty ? live_rdata
                                      : cpu_fifo_mem[cpu_fifo_rptr];

    // ============================================================
    // 输出 FIFO
    // ============================================================
    reg  [31:0] cpu_fifo_mem [0:3];
    reg  [ 1:0] cpu_fifo_wptr;
    reg  [ 1:0] cpu_fifo_rptr;
    reg  [ 2:0] cpu_fifo_cnt;

    wire cpu_fifo_full;
    wire cpu_fifo_empty;
    assign cpu_fifo_full  = (cpu_fifo_cnt == 3'd4);
    assign cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);

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

    // ============================================================
    // {Tag, V} RAM 写控制
    // ============================================================
    wire refill_tagv_we;
    assign refill_tagv_we = (main_refill && return_valid && return_last && refill_cached)
                          || (main_refill && cacop_en_r);

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
    assign tagv_waddr_sel = (cacop_code00 || cacop_code01) ? cacop_index_r : refill_index;
    assign tagv_wmask_sel = (cacop_code01 || cacop_code10) ? 4'b0001
                                                           : {TAGV_BYTES{1'b1}};
    assign tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }
                                       : {refill_tag, 1'b1};

    // ============================================================
    // {Tag, V} RAM 例化
    // ============================================================
    wire                    tagv_en   [0:`WAY_NUM-1];
    wire [ 3:0]            tagv_wen  [0:`WAY_NUM-1];
    wire [`INDEX_WIDTH-1:0] tagv_addr [0:`WAY_NUM-1];

    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire tagv_wr = tagv_do_write && (refill_replace_way == gt);
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

    // ============================================================
    // Data Bank RAM 例化
    // ============================================================
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
                                              && (refill_replace_way == gw)
                                              && refill_cached;

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb] || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 4'b1111 : 4'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? refill_index : ram_raddr;
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb]
                                          ? ((refill_cnt == gb) ? return_data : refill_line[gb])
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

    // ============================================================
    // AXI 读请求
    // ============================================================
    assign rd_req = ((main_lookup && !cache_inst_hit && !cacop_en_r)
                  || main_waitrd) && !prefetch_can_cancel;

    assign rd_type = req_cached ? 3'b100 : 3'b010;
    assign rd_addr = req_cached
                   ? {req_tag, req_index, 4'b0000}
                   : {req_tag, req_index, req_offset};

    // ============================================================
    // 性能计数器
    // ============================================================
    reg [31:0] perf_total_req     /*verilator public*/;
    reg [31:0] perf_access_cnt    /*verilator public*/;
    reg [31:0] perf_miss_cnt      /*verilator public*/;
    reg [31:0] perf_real_miss_cnt /*verilator public*/;
    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req     <= 32'd0;
            perf_access_cnt    <= 32'd0;
            perf_miss_cnt      <= 32'd0;
            perf_real_miss_cnt <= 32'd0;
        end
        else begin
            if (accept_new_req)
                perf_total_req <= perf_total_req + 32'd1;
            if (main_lookup && req_cached && !cacop_en_r) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_inst_hit) begin
                    perf_miss_cnt      <= perf_miss_cnt      + 32'd1;
                    perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
                end
            end
        end
    end

endmodule
