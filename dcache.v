`include "mycpu.h"

module dcache (
    // 时钟与复位
    input  wire                 clk,
    input  wire                 resetn,

    // CPU 流水线接口
    input  wire                    cpu_req,
    input  wire                    cpu_op,
    input  wire [`INDEX_WIDTH-1:0]  cpu_index,
    input  wire [ `TAG_WIDTH-1:0]   cpu_tag,
    input  wire [`OFFSET_WIDTH-1:0] cpu_offset,
    input  wire [ 3:0]             cpu_wstrb,
    input  wire [31:0]             cpu_wdata,
    input  wire                    cpu_cached,
    output wire                    cpu_addr_ok,
    output wire                    cpu_data_ok,
    output wire [31:0]             cpu_rdata,
    input  wire                    cpu_accept,

    // AXI 总线接口
    output wire                 rd_req,
    output wire [ 2:0]          rd_type,
    output wire [31:0]          rd_addr,
    input  wire                 rd_rdy,
    input  wire                 return_valid,
    input  wire                 return_last,
    input  wire [31:0]          return_data,
    output wire                 wr_req,
    output wire [ 2:0]          wr_type,
    output wire [31:0]          wr_addr,
    output wire [ 3:0]          wr_wstrb,
    output wire [127:0]         wr_data,
    input  wire                 wr_rdy,
    input  wire                 wr_done,
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

    localparam MAIN_IDLE   = 6'b000001;
    localparam MAIN_LOOKUP = 6'b000010;
    localparam MAIN_WAITRD = 6'b000100;
    localparam MAIN_REFILL = 6'b001000;
    localparam MAIN_WAITWR = 6'b010000;
    localparam MAIN_WAITWB = 6'b100000;

    localparam WB_IDLE  = 1'd0;
    localparam WB_WRITE = 1'd1;

    parameter VC_DEPTH  = 4;
    parameter VC_EN     = 0;

    localparam VC_IDX_W = (VC_DEPTH > 1) ? $clog2(VC_DEPTH) : 1;

    // ============================================================
    // RAM 存储阵列
    // ============================================================
    wire [`TAG_WIDTH:0]  tagv_rdata [0:`WAY_NUM-1];
    reg                  d_rdata    [0:`WAY_NUM-1];
    wire [31:0]          bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];
    reg                  d_ram      [0:`WAY_NUM-1][0:INDEX_DEPTH-1];

    // ============================================================
    // 状态寄存器
    // ============================================================
    reg  [5:0] main_state;
    reg  [5:0] main_next;
    reg        wb_state;
    reg        wb_next;

    // ============================================================
    // 状态机节点
    // ============================================================
    wire main_idle   = (main_state == MAIN_IDLE);
    wire main_lookup = (main_state == MAIN_LOOKUP);
    wire main_waitrd = (main_state == MAIN_WAITRD);
    wire main_refill = (main_state == MAIN_REFILL);
    wire main_waitwr = (main_state == MAIN_WAITWR);
    wire main_waitwb = (main_state == MAIN_WAITWB);
    wire wb_idle     = (wb_state == WB_IDLE);
    wire wb_write    = (wb_state == WB_WRITE);

    // ============================================================
    // Request Buffer — accept_new_req 时更新，LOOKUP 期间保持
    // ============================================================
    reg                     req_op;
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`TAG_WIDTH-1:0]   req_tag;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg  [31:0]             req_wstrb_mask;
    reg  [31:0]             req_wdata;
    reg                     req_cached;
    reg                     cacop_en_r;
    reg  [4:0]              cacop_code_r;
    reg  [WAY_IDX_W-1:0]    cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;

    // ============================================================
    // Refill Buffer — LOOKUP miss 拍一次性锁存，整个 REFILL 期间不变
    // ============================================================
    reg  [`INDEX_WIDTH-1:0]  refill_index;
    reg  [`TAG_WIDTH-1:0]   refill_tag;
    reg  [`OFFSET_WIDTH-1:0] refill_offset;
    reg                     refill_cached;
    reg                     refill_op;
    reg  [WAY_IDX_W-1:0]    refill_replace_way;
    reg  [ 1:0]             refill_cnt;
    reg  [31:0]             refill_line [0:BANK_NUM-1];
    reg  [31:0]             refill_victim_line [0:BANK_NUM-1];
    reg  [`TAG_WIDTH-1:0]  refill_victim_tag;
    reg  [31:0]             refill_wdata;
    reg  [31:0]             refill_wstrb_mask;

    // ============================================================
    // VC 服务上下文 — VC hit L1 miss 时锁存，WAITWB 期间保持
    // ============================================================
    reg                  vc_serve_r;
    reg  [VC_IDX_W-1:0]  vc_hit_idx_r;
    reg                  vc_victim_dirty_r;
    reg  [127:0]         vc_serve_line;

    // ============================================================
    // 顶层标志
    // ============================================================
    reg  refill_already_accept_new_req; // REFILL 期间 accept 了一个新请求，待 REFILL 后进 LOOKUP

    // ============================================================
    // Write Buffer — 命中 store 的写缓冲，写入 bank RAM
    // ============================================================
    reg                  wb_valid;
    reg  [`WAY_NUM-1:0]   wb_way_hit;
    reg  [`INDEX_WIDTH-1:0] wb_index;
    reg  [ 1:0]          wb_bank;
    reg  [31:0]          wb_wstrb_mask;
    reg  [31:0]          wb_wdata;

    // ============================================================
    // Writeback Buffer — LOOKUP miss 拍一次性锁存 AXI 写回信息
    // ============================================================
    reg                  wr_pending;
    reg                  wr_handshaked;
    reg                  wr_is_uncached;
    reg  [31:0]          wr_wb_addr;
    reg  [127:0]         wr_wb_data;
    reg  [ 3:0]          wr_wb_wstrb;
    reg  [ 2:0]          wr_wb_type;

    // ============================================================
    // Victim Cache 存储
    // ============================================================
    reg                  vc_valid [0:VC_DEPTH-1];
    reg  [`TAG_WIDTH+`INDEX_WIDTH-1:0] vc_addr [0:VC_DEPTH-1];
    reg  [127:0]         vc_data  [0:VC_DEPTH-1];
    reg  [VC_IDX_W-1:0]  vc_fifo_ptr;

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
    assign cacop_is_index  = cacop_en && (cacop_code[4:3] != 2'b10);
    assign cacop_is_hit    = cacop_en && (cacop_code[4:3] == 2'b10);
    assign cacop_index     = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign cacop_way       = cacop_va[WAY_IDX_W-1:0];

    // ============================================================
    // 统一 RAM 读地址
    // ============================================================
    wire [`INDEX_WIDTH-1:0] ram_raddr_req;
    assign ram_raddr_req = (cacop_is_index || cacop_is_hit) ? cacop_index : cpu_index;

    wire ram_read_en;
    assign ram_read_en = accept_new_req;

    wire [`INDEX_WIDTH-1:0] ram_raddr;
    assign ram_raddr = ram_raddr_req;

    // ============================================================
    // accept_new_req
    // ============================================================
    wire idle_accept;
    wire hit_accept;
    wire refill_early_accept;

    assign idle_accept   = main_idle && (cpu_req || cacop_en);
    assign hit_accept    = main_lookup && !hit_write_block && cache_hit && (cpu_req || cacop_en);
    assign refill_early_accept = main_refill && !refill_last
                               && !refill_already_accept_new_req
                               && !cacop_en_r && !cacop_en
                               && cpu_req
                               && refill_cached
                               && !wr_pending;

    wire accept_new_req;
    assign accept_new_req = (idle_accept && accept_ok)
                         || (hit_accept && accept_ok)
                         || (refill_early_accept && accept_ok)
                         || (main_waitwr && wr_handshaked && (!wr_is_uncached || wr_done) && accept_ok && (cpu_req || cacop_en));

    // ============================================================
    // enter_refill — LOOKUP miss 且 rd_rdy，或 WAITRD 等到 rd_rdy
    // ============================================================
    wire enter_refill;
    assign enter_refill = (main_lookup && !cache_hit && rd_rdy)
                        || (main_lookup && cacop_en_r)
                        || (main_waitrd && rd_rdy);

    // ============================================================
    // REFILL 节拍
    // ============================================================
    wire refill_last;
    assign refill_last = main_refill && return_valid && return_last;

    // ============================================================
    // Hit Write 冲突检测
    // ============================================================
    // WB 被 RAM 读抢端口时暂缓写入
    wire wb_stall;
    assign wb_stall = wb_write && ram_read_en;

    // LOOKUP st 命中 + WB 忙 + 新请求 → 阻塞（防止 WB 数据被覆盖）
    wire hit_write_block;
    assign hit_write_block = wb_write && (cpu_req || cacop_en)
                           && main_lookup && cache_hit && req_op;

    // WB 前推：当前 LOOKUP 是 ld 且 WB 有未写入的同 index/way/bank 数据
    wire wb_fwd_active;
    assign wb_fwd_active = main_lookup && wb_write && !req_op
                         && (wb_index == req_index)
                         && wb_way_hit[hit_way_idx]
                         && (wb_bank == req_offset[3:2]);

    wire [31:0] wb_fwd_data;
    assign wb_fwd_data = (wb_wdata & wb_wstrb_mask)
                       | (bank_rdata[hit_way_idx][req_offset[3:2]] & ~wb_wstrb_mask);

    // WB 导致某路在 LOOKUP 当前行变为脏 — 综合到 victim/cacop 脏位判定
    wire [`WAY_NUM-1:0] wb_line_dirty;
    assign wb_line_dirty = ({`WAY_NUM{wb_write && (wb_index == req_index)}} & wb_way_hit);

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
    // D Bypass — LOOKUP-from-early-accept 时用 refill_op 替代过期的 d_rdata
    // ============================================================
    reg  d_lookup [0:`WAY_NUM-1];
    integer dbp;
    always @(*) begin
        for (dbp = 0; dbp < `WAY_NUM; dbp = dbp + 1)
            d_lookup[dbp] = (bypass_active && (dbp[WAY_IDX_W-1:0] == refill_replace_way))
                          ? refill_op
                          : d_rdata[dbp];
    end

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

    wire cache_hit;
    assign cache_hit = (|way_hit) && !cacop_en_r;

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
    // 无效路查找
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
    // PLRU 预计算
    // ============================================================
    wire pre_plru_en;
    wire [`INDEX_WIDTH-1:0] pre_plru_index;
    assign pre_plru_en    = accept_new_req;
    assign pre_plru_index = ram_raddr_req;

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
    // 替换路号（CACOP 用目标路，普通 miss 用 PLRU）
    // ============================================================
    wire [WAY_IDX_W-1:0] replace_way;
    assign replace_way = cacop_en_r
                       ? ((cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r)
                       : (has_invalid ? invalid_way : plru_victim_r);

    // ============================================================
    // VC 查找
    // ============================================================
    wire [VC_DEPTH-1:0] vc_match;
    genvar gv;
    generate
        for (gv = 0; gv < VC_DEPTH; gv = gv + 1) begin : vc_match_gen
            assign vc_match[gv] = vc_valid[gv]
                                && (vc_addr[gv] == {req_tag, req_index});
        end
    endgenerate

    wire vc_hit;
    assign vc_hit = (|vc_match) && req_cached && !cacop_en_r && VC_EN;

    reg  [VC_IDX_W-1:0] vc_hit_idx;
    integer vhi;
    always @(*) begin
        vc_hit_idx = {VC_IDX_W{1'b0}};
        for (vhi = 0; vhi < VC_DEPTH; vhi = vhi + 1)
            if (vc_match[vhi]) vc_hit_idx = vhi[VC_IDX_W-1:0];
    end

    wire vc_active;
    assign vc_active = (main_lookup && vc_hit) || vc_fill_lookup;
    reg  [127:0] vc_line;
    reg  [31:0]  vc_word;
    integer vli;
    always @(*) begin
        vc_line = 128'b0;
        vc_word = 32'b0;
        if (vc_active) begin
            for (vli = 0; vli < VC_DEPTH; vli = vli + 1) begin
                vc_line = vc_line | ({128{vc_match[vli]}} & vc_data[vli]);
                vc_word = vc_word | ({32{vc_match[vli]}} & vc_data[vli][{req_offset[3:2], 5'b0} +: 32]);
            end
        end
    end

    wire vc_serve;
    assign vc_serve = main_lookup && !cache_hit && vc_hit;

    // VC serve + WB 忙 → 进 WAITWB 等 WB 写完后做 VC↔L1 交换
    wire vc_serve_wb_busy;
    assign vc_serve_wb_busy = vc_serve && wb_write;

    // VC↔L1 交换：LOOKUP + WB idle，或 WAITWB 末尾 WB 刚完成
    wire vc_exchange;
    assign vc_exchange = (main_lookup && vc_serve && !wb_write)
                       || (main_waitwb && !wb_write);

    // ============================================================
    // LOOKUP 决策信号
    // ============================================================
    wire lookup_store_hit;
    assign lookup_store_hit = main_lookup && cache_hit && req_op;

    wire is_uncached_store;
    assign is_uncached_store = !req_cached && req_op && !cacop_en_r;

    wire need_bus_rd;
    assign need_bus_rd = (req_cached || !req_op) && !cacop_en_r;

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
                if (vc_serve_wb_busy)
                    main_next = MAIN_WAITWB;
                else if (vc_serve && !victim_dirty)
                    main_next = MAIN_IDLE;
                else if (vc_serve && victim_dirty)
                    main_next = MAIN_WAITWR;
                else if (is_uncached_store)
                    main_next = MAIN_WAITWR;
                else if (cacop_en_r)
                    main_next = MAIN_REFILL;
                else if (!cache_hit && rd_rdy)
                    main_next = MAIN_REFILL;
                else if (!cache_hit)
                    main_next = MAIN_WAITRD;
                else if (accept_new_req)
                    main_next = MAIN_LOOKUP;
                else
                    main_next = MAIN_IDLE;
            end
            MAIN_WAITRD: begin
                if (rd_rdy)
                    main_next = MAIN_REFILL;
                else
                    main_next = MAIN_WAITRD;
            end
            MAIN_REFILL: begin
                if (refill_last || cacop_en_r) begin
                    if (!refill_cached && !cacop_en_r)
                        main_next = MAIN_IDLE;
                    else if (wr_pending && !wr_handshaked)
                        main_next = MAIN_WAITWR;
                    else if (refill_already_accept_new_req)
                        main_next = MAIN_LOOKUP;
                    else
                        main_next = MAIN_IDLE;
                end
                else
                    main_next = MAIN_REFILL;
            end
            MAIN_WAITWR: begin
                if (!wr_handshaked)
                    main_next = MAIN_WAITWR;
                else if (wr_is_uncached && !wr_done)
                    main_next = MAIN_WAITWR;
                else if (accept_new_req)
                    main_next = MAIN_LOOKUP;
                else
                    main_next = MAIN_IDLE;
            end
            MAIN_WAITWB: begin
                if (wb_write)
                    main_next = MAIN_WAITWB;
                else if (vc_victim_dirty_r && !wr_handshaked)
                    main_next = MAIN_WAITWR;
                else if (accept_new_req)
                    main_next = MAIN_LOOKUP;
                else
                    main_next = MAIN_IDLE;
            end
            default: main_next = MAIN_IDLE;
        endcase
    end

    // ============================================================
    // Write Buffer 状态机 — 时序
    // ============================================================
    always @(posedge clk) begin
        if (~resetn)
            wb_state <= WB_IDLE;
        else
            wb_state <= wb_next;
    end

    // ============================================================
    // Write Buffer 状态机 — 下一状态逻辑
    // ============================================================
    wire wb_new_store_hit;
    assign wb_new_store_hit = main_lookup && lookup_store_hit;

    always @(*) begin
        case (wb_state)
            WB_IDLE: begin
                wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            end
            WB_WRITE: begin
                wb_next = wb_stall ? WB_WRITE
                       : wb_new_store_hit ? WB_WRITE
                       : WB_IDLE;
            end
            default: wb_next = WB_IDLE;
        endcase
    end

    // ============================================================
    // PLRU 更新
    // ============================================================
    wire                 plru_upd_en;
    wire [WAY_IDX_W-1:0] plru_upd_way;
    wire [`INDEX_WIDTH-1:0] plru_upd_index;
    assign plru_upd_en    = (main_lookup && cache_hit)
                          || refill_tagv_we;
    assign plru_upd_way   = (main_lookup && cache_hit) ? hit_way_idx
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
            req_op           <= 1'b0;
            req_index        <= {`INDEX_WIDTH{1'b0}};
            req_tag          <= {`TAG_WIDTH{1'b0}};
            req_offset       <= {`OFFSET_WIDTH{1'b0}};
            req_wstrb_mask   <= 32'd0;
            req_wdata        <= 32'd0;
            req_cached       <= 1'b0;
            cacop_en_r       <= 1'b0;
            cacop_code_r     <= 5'b0;
            cacop_way_r      <= {WAY_IDX_W{1'b0}};
            cacop_index_r    <= {`INDEX_WIDTH{1'b0}};
            cacop_is_index_r <= 1'b0;
            cacop_is_hit_r   <= 1'b0;
        end
        else if (accept_new_req) begin
            req_op           <= cpu_op;
            req_index        <= cacop_en ? cacop_index : cpu_index;
            req_tag          <= (cacop_en && cacop_is_hit) ? cacop_tag : cpu_tag;
            req_offset       <= cpu_offset;
            req_wstrb_mask   <= { {8{cpu_wstrb[3]}}, {8{cpu_wstrb[2]}},
                                  {8{cpu_wstrb[1]}}, {8{cpu_wstrb[0]}} };
            req_wdata        <= cpu_wdata;
            req_cached       <= cpu_cached;
            cacop_en_r       <= cacop_en;
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
    // Write Buffer — 时序更新
    // ============================================================
    always @(posedge clk) begin
        if (main_lookup && lookup_store_hit) begin
            wb_valid   <= 1'b1;
            wb_way_hit <= way_hit;
            wb_index   <= req_index;
            wb_bank    <= req_offset[3:2];
            wb_wstrb_mask <= req_wstrb_mask;
            wb_wdata   <= req_wdata;
        end
        else if (wb_write && !wb_stall && !wb_new_store_hit) begin
            wb_valid <= 1'b0;
        end
    end

    // ============================================================
    // Refill Buffer — LOOKUP miss 拍一次性锁存
    // ============================================================
    always @(posedge clk) begin
        if (main_lookup && !cache_hit) begin
            refill_index       <= req_index;
            refill_tag         <= req_tag;
            refill_offset      <= req_offset;
            refill_cached      <= req_cached;
            refill_op          <= req_op;
            refill_wdata       <= req_wdata;
            refill_wstrb_mask  <= req_wstrb_mask;
            refill_replace_way <= replace_way;
            refill_cnt         <= 2'd0;
            refill_victim_tag  <= tagv_lookup[replace_way][`TAG_WIDTH:1];
            // 始终保存 victim 行数据：脏时供 writeback，干净时供 VC insert
            if (tagv_lookup[replace_way][0]) begin
                refill_victim_line[0] <= lookup_wr_bank[0];
                refill_victim_line[1] <= lookup_wr_bank[1];
                refill_victim_line[2] <= lookup_wr_bank[2];
                refill_victim_line[3] <= lookup_wr_bank[3];
            end
        end
        else if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= refill_merged_word;
        end
    end

    // ============================================================
    // VC 服务上下文 — LOOKUP VC hit 时锁存，exchange 后清除
    // ============================================================
    always @(posedge clk) begin
        if (~resetn)
            vc_serve_r <= 1'b0;
        else if (main_lookup && vc_serve) begin
            vc_serve_r        <= 1'b1;
            vc_hit_idx_r      <= vc_hit_idx;
            vc_victim_dirty_r <= victim_dirty;
            vc_serve_line     <= vc_data[vc_hit_idx];
        end
        else if (vc_exchange)
            vc_serve_r <= 1'b0;
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
    // Writeback Buffer — LOOKUP miss + 需写回时锁存
    // ============================================================
    always @(posedge clk) begin
        if (~resetn) begin
            wr_pending    <= 1'b0;
            wr_handshaked <= 1'b0;
        end
        else begin
            if (main_lookup && !cache_hit && miss_needs_write) begin
                wr_pending    <= 1'b1;
                wr_handshaked <= 1'b0;
                wr_is_uncached <= is_uncached_store;
                wr_wb_type     <= (req_cached || cacop_en_r) ? 3'b100 : uncached_rd_type;
                wr_wb_wstrb    <= (req_cached || cacop_en_r) ? 4'b1111 : req_wstrb_4b;
                if (is_uncached_store) begin
                    wr_wb_addr <= {req_tag, req_index, req_offset};
                    wr_wb_data <= {96'd0, req_wdata};
                end
                else begin
                    wr_wb_addr <= {tagv_rdata[replace_way][`TAG_WIDTH:1], req_index, 4'b0000};
                    wr_wb_data <= {lookup_wr_bank[3], lookup_wr_bank[2],
                                   lookup_wr_bank[1], lookup_wr_bank[0]};
                end
            end
            else if (wr_pending && !wr_handshaked && wr_rdy) begin
                wr_handshaked <= 1'b1;
            end
            else if (wr_pending && wr_handshaked && (!wr_is_uncached || wr_done)) begin
                wr_pending <= 1'b0;
            end
        end
    end

    // ============================================================
    // VC 交换写
    // ============================================================
    // VC→L1: 永远在 vc_exchange 拍执行
    // L1→VC: 仅在 victim 干净时
    wire vc_fill_lookup;
    wire vc_fill;
    assign vc_fill_lookup  = vc_exchange && !vc_victim_dirty_r;
    assign vc_fill         = vc_exchange;

    wire [WAY_IDX_W-1:0] vc_fill_way;
    assign vc_fill_way = refill_replace_way;

    // L1→VC 数据源：Refill Buffer 中的 victim 行（含 live_fwd），不再读 bank_rdata
    wire [31:0] vc_fill_word [0:BANK_NUM-1];
    genvar gf;
    generate
        for (gf = 0; gf < BANK_NUM; gf = gf + 1) begin : vc_fill_word_gen
            assign vc_fill_word[gf] = (req_op && (req_offset[3:2] == gf))
                                    ? ((req_wdata & req_wstrb_mask) | (refill_victim_line[gf] & ~req_wstrb_mask))
                                    : refill_victim_line[gf];
        end
    endgenerate

    // VC→L1 数据：LOOKUP 拍锁存的 vc_serve_line，store 时合并 wdata
    wire [31:0] vc_serve_bank_word [0:BANK_NUM-1];
    genvar gvs;
    generate
        for (gvs = 0; gvs < BANK_NUM; gvs = gvs + 1) begin : vc_serve_bank_gen
            assign vc_serve_bank_word[gvs] = (refill_op && (refill_offset[3:2] == gvs))
                                           ? ((refill_wdata & refill_wstrb_mask) | (vc_serve_line[gvs*32 +: 32] & ~refill_wstrb_mask))
                                           : vc_serve_line[gvs*32 +: 32];
        end
    endgenerate

    // ============================================================
    // VC 存储更新
    // ============================================================
    wire vc_insert;
    assign vc_insert = refill_d_we && VC_EN
                     && tagv_rdata[refill_replace_way][0]
                     && !d_rdata[refill_replace_way];

    integer vci;
    always @(posedge clk) begin
        if (~resetn) begin
            for (vci = 0; vci < VC_DEPTH; vci = vci + 1)
                vc_valid[vci] <= 1'b0;
            vc_fifo_ptr <= {VC_IDX_W{1'b0}};
        end
        else begin
            if (main_lookup && cacop_en_r && cacop_code_r[4:3] != 2'b11 && VC_EN) begin
                for (vci = 0; vci < VC_DEPTH; vci = vci + 1) begin
                    if (vc_valid[vci]
                     && (cacop_is_hit_r ? (vc_addr[vci] == {req_tag, req_index})
                                        : (vc_addr[vci][`INDEX_WIDTH-1:0] == req_index)))
                        vc_valid[vci] <= 1'b0;
                end
            end
            if (vc_fill_lookup) begin
                vc_addr[vc_hit_idx_r]  <= {refill_victim_tag, refill_index};
                vc_data[vc_hit_idx_r]  <= {refill_victim_line[3], refill_victim_line[2],
                                           refill_victim_line[1], refill_victim_line[0]};
                vc_valid[vc_hit_idx_r] <= 1'b1;
            end
            if (vc_insert) begin
                vc_valid[vc_fifo_ptr] <= 1'b1;
                vc_addr[vc_fifo_ptr]  <= {tagv_rdata[refill_replace_way][`TAG_WIDTH:1], refill_index};
                vc_data[vc_fifo_ptr]  <= {refill_victim_line[3], refill_victim_line[2],
                                          refill_victim_line[1], refill_victim_line[0]};
                vc_fifo_ptr <= vc_fifo_ptr + 1'b1;
            end
        end
    end

    // ============================================================
    // 数据选择
    // ============================================================
    wire [31:0] hit_word;
    assign hit_word = (bypass_active && (hit_way_idx == refill_replace_way))
                    ? refill_line[req_offset[3:2]]
                    : bank_rdata[hit_way_idx][req_offset[3:2]];

    wire [31:0] lookup_rdata;
    assign lookup_rdata = wb_fwd_active ? wb_fwd_data : hit_word;

    // ============================================================
    // REFILL 合并写数据
    // ============================================================
    wire [3:0] req_wstrb_4b;
    assign req_wstrb_4b = {req_wstrb_mask[31], req_wstrb_mask[23],
                           req_wstrb_mask[15], req_wstrb_mask[ 7]};

    wire is_refill_store_target;
    assign is_refill_store_target = refill_op && (refill_cnt == refill_offset[3:2]);

    wire [31:0] refill_merged_word;
    assign refill_merged_word = is_refill_store_target
                              ? ((refill_wdata & refill_wstrb_mask) | (return_data & ~refill_wstrb_mask))
                              : return_data;

    // ============================================================
    // {Tag, V} RAM 写控制
    // ============================================================
    wire refill_tagv_we;
    assign refill_tagv_we = (main_refill && return_valid && return_last && refill_cached
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
    assign tagv_waddr_sel = vc_fill ? req_index
                          : (cacop_code00 || cacop_code01) ? cacop_index_r
                          : refill_index;
    assign tagv_wmask_sel = (cacop_code01 || cacop_code10) ? 4'b0001
                                                           : {TAGV_BYTES{1'b1}};
    wire [`TAG_WIDTH:0] vc_serve_tagv_wdata;
    assign vc_serve_tagv_wdata = {vc_addr[vc_hit_idx_r][`TAG_WIDTH+`INDEX_WIDTH-1:`INDEX_WIDTH], 1'b1};
    assign tagv_wdata_sel = vc_fill ? vc_serve_tagv_wdata
                          : cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }
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
            wire tagv_wr = (tagv_do_write && (refill_replace_way == gt))
                         || (vc_fill && (vc_fill_way == gt));
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
    // D RAM
    // ============================================================
    wire refill_d_we;
    assign refill_d_we = main_refill && return_valid && return_last && refill_cached;

    integer d_wi;
    integer d_idx;
    always @(posedge clk) begin
        if (~resetn) begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                for (d_idx = 0; d_idx < INDEX_DEPTH; d_idx = d_idx + 1)
                    d_ram[d_wi][d_idx] <= 1'b0;
            end
        end
        else begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                if (refill_d_we && (refill_replace_way == d_wi))
                    d_ram[d_wi][refill_index] <= refill_op;
                else if (vc_fill && (vc_fill_way == d_wi))
                    d_ram[d_wi][req_index] <= req_op;
                else if (wb_write && wb_way_hit[d_wi] && !wb_stall)
                    d_ram[d_wi][wb_index] <= 1'b1;
                if (ram_read_en)
                    d_rdata[d_wi] <= d_ram[d_wi][ram_raddr];
            end
        end
    end

    // ============================================================
    // Data Bank RAM 例化
    // ============================================================
    wire                    bank_wr_refill [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire                    bank_wr_vcf    [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire                    bank_wr_hit    [0:`WAY_NUM-1][0:BANK_NUM-1];
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
                assign bank_wr_vcf[gw][gb]    = vc_fill && (vc_fill_way == gw);
                assign bank_wr_hit[gw][gb]    = wb_write && wb_way_hit[gw] && (wb_bank == gb) && !ram_read_en;

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb]
                                          || bank_wr_vcf[gw][gb]
                                          || bank_wr_hit[gw][gb]
                                          || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 4'b1111
                                          : bank_wr_vcf[gw][gb]    ? 4'b1111
                                          : bank_wr_hit[gw][gb]    ? {wb_wstrb_mask[24], wb_wstrb_mask[16], wb_wstrb_mask[8], wb_wstrb_mask[0]}
                                                                   : 4'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? refill_index
                                          : bank_wr_vcf[gw][gb]    ? req_index
                                          : bank_wr_hit[gw][gb]    ? wb_index
                                                                   : ram_raddr;
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb]
                                          ? ((refill_cnt == gb) ? refill_merged_word : refill_line[gb])
                                          : bank_wr_vcf[gw][gb] ? vc_serve_bank_word[gb]
                                                                : wb_wdata;

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
    // 输出 FIFO
    // ============================================================
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
    wire vc_read_done;
    wire write_done;
    wire read_miss_done;
    assign read_hit_done  = main_lookup && cache_hit && !req_op;
    assign vc_read_done   = vc_serve && !req_op;
    assign write_done     = main_lookup && req_op;
    assign read_miss_done = main_refill && return_valid && !refill_op
                          && (refill_cnt == refill_offset[3:2] || !refill_cached);

    wire read_result_ready;
    wire [31:0] live_rdata;
    assign read_result_ready = read_hit_done || vc_read_done || read_miss_done;
    assign live_rdata = read_hit_done  ? lookup_rdata
                      : vc_read_done   ? vc_word
                      : read_miss_done ? return_data
                                       : 32'd0;

    wire cpu_takes_live;
    assign cpu_takes_live = cpu_accept && cpu_fifo_empty && read_result_ready;
    assign cpu_fifo_we    = read_result_ready && !cpu_takes_live;
    assign cpu_fifo_re    = cpu_accept && !cpu_fifo_empty;

    wire accept_ok;
    assign accept_ok = cpu_op
                     || (cpu_fifo_cnt < 3'd3)
                     || (cpu_fifo_cnt == 3'd3 && req_op);

    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign bus_accept  = 1'b1;
    assign cpu_data_ok = read_result_ready || !cpu_fifo_empty || write_done;
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

    // ============================================================
    // AXI 读请求
    // ============================================================
    wire rd_req_lookup;
    assign rd_req_lookup = main_lookup && !cache_hit
                         && need_bus_rd
                         && !vc_hit;

    assign rd_req = rd_req_lookup || main_waitrd;

    wire wstrb_hw;
    assign wstrb_hw = (req_wstrb_4b == 4'b0011) || (req_wstrb_4b == 4'b1100);

    wire [2:0] uncached_rd_type;
    assign uncached_rd_type = !req_op             ? 3'b010
                            : (&req_wstrb_4b)     ? 3'b010
                            : wstrb_hw            ? 3'b001
                                                  : 3'b000;

    assign rd_type = req_cached ? 3'b100 : uncached_rd_type;
    assign rd_addr = req_cached
                   ? {req_tag, req_index, 4'b0000}
                   : {req_tag, req_index, req_offset};

    // ============================================================
    // CACOP 辅助
    // ============================================================
    wire cacop_wb_index;
    wire cacop_wb_hit;
    wire cacop_wb;
    assign cacop_wb_index = cacop_en_r && (cacop_code_r[4:3] == 2'b01);
    assign cacop_wb_hit   = cacop_en_r && (cacop_code_r[4:3] == 2'b10) && (|way_hit);
    assign cacop_wb       = cacop_wb_index || cacop_wb_hit;

    // ============================================================
    // 脏位 / 写回判定
    // ============================================================
    wire victim_dirty;
    wire cacop_dirty;
    assign victim_dirty = (d_lookup[replace_way] || wb_line_dirty[replace_way])
                        && tagv_lookup[replace_way][0];
    assign cacop_dirty  = (cacop_code_r[4:3] == 2'b10)
                        ? ((d_lookup[hit_way_idx] || wb_line_dirty[hit_way_idx])
                           && tagv_lookup[hit_way_idx][0])
                        : ((d_lookup[cacop_way_r] || wb_line_dirty[cacop_way_r])
                           && tagv_lookup[cacop_way_r][0]);

    wire miss_needs_write;
    assign miss_needs_write = cacop_en_r ? (cacop_wb && cacop_dirty)
                            : ((req_cached && victim_dirty) || is_uncached_store);

    // ============================================================
    // victim 行数据（LOOKUP miss 时含 live_fwd WB 前推，供 Refill/Writeback Buffer 锁存）
    // ============================================================
    wire [31:0] lookup_wr_bank [0:BANK_NUM-1];
    genvar glw;
    generate
        for (glw = 0; glw < BANK_NUM; glw = glw + 1) begin : lookup_wr_bank_gen
            wire live_fwd = wb_write && wb_way_hit[replace_way]
                         && (wb_index == req_index) && (wb_bank == glw);
            assign lookup_wr_bank[glw] = live_fwd
                ? ((wb_wdata & wb_wstrb_mask) | (bank_rdata[replace_way][glw] & ~wb_wstrb_mask))
                : (bypass_active && (replace_way == refill_replace_way))
                    ? refill_line[glw]
                    : bank_rdata[replace_way][glw];
        end
    endgenerate

    // ============================================================
    // AXI 写请求 — 来自 Writeback Buffer
    // ============================================================
    assign wr_req   = wr_pending && !wr_handshaked;
    assign wr_type  = wr_wb_type;
    assign wr_addr  = wr_wb_addr;
    assign wr_wstrb = wr_wb_wstrb;
    assign wr_data  = wr_wb_data;

`ifndef SYNTHESIS
    // ============================================================
    // 仿真断言
    // ============================================================
    always @(posedge clk) begin
        if (resetn && main_lookup && req_cached && !cacop_en_r) begin
            if (cache_hit && (|vc_match))
                $display("[%m] ASSERT FAIL: line in both L1 and VC, tag=%h index=%h",
                         req_tag, req_index);
            if ((|vc_match) && ((vc_match & (vc_match - 1)) != {VC_DEPTH{1'b0}}))
                $display("[%m] ASSERT WARN: duplicate VC entries, tag=%h index=%h",
                         req_tag, req_index);
        end
    end
`endif

    // ============================================================
    // 性能计数器
    // ============================================================
    reg [31:0] perf_total_req       /*verilator public*/;
    reg [31:0] perf_access_cnt      /*verilator public*/;
    reg [31:0] perf_miss_cnt        /*verilator public*/;
    reg [31:0] perf_real_miss_cnt   /*verilator public*/;
    reg [31:0] perf_vc_hit_cnt      /*verilator public*/;
    reg [31:0] perf_vc_insert_cnt   /*verilator public*/;
    reg [31:0] perf_vc_fill_cnt     /*verilator public*/;
    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
            perf_vc_hit_cnt       <= 32'd0;
            perf_vc_insert_cnt    <= 32'd0;
            perf_vc_fill_cnt      <= 32'd0;
        end
        else begin
            if (accept_new_req)
                perf_total_req <= perf_total_req + 32'd1;
            if (main_lookup && req_cached && !cacop_en_r) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit)
                    perf_miss_cnt <= perf_miss_cnt + 32'd1;
                if (!cache_hit && vc_hit)
                    perf_vc_hit_cnt <= perf_vc_hit_cnt + 32'd1;
                if (!cache_hit && !vc_hit)
                    perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
            end
            if (vc_insert)
                perf_vc_insert_cnt <= perf_vc_insert_cnt + 32'd1;
            if (vc_fill)
                perf_vc_fill_cnt <= perf_vc_fill_cnt + 32'd1;
        end
    end

endmodule
