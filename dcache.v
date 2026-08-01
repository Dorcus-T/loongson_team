`include "mycpu.h"

module dcache (
    // 时钟与复位
    input  wire                 clk,
    input  wire                 resetn,

    // CPU 流水线接口
    input  wire                    cpu_req,
    input  wire                    cpu_op,
    input  wire [`INDEX_WIDTH-1:0]  cpu_index,
    input  wire [ `TAG_WIDTH-1:0]   mmu_tag,
    input  wire [`OFFSET_WIDTH-1:0] cpu_offset,
    input  wire [ 3:0]             cpu_wstrb,
    input  wire [31:0]             cpu_wdata,
    input  wire                    mmu_cached,
    input  wire                    mmu_cancel,
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

    // CACOP 接口
    input  wire                    cacop_en,
    input  wire [ 4:0]             cacop_code,
    input  wire [31:0]             cacop_va,
    input  wire [`TAG_WIDTH-1:0]   cacop_tag,
    output wire                    cacop_rdy,

    // debug
    output wire [ 5:0]              debug_main_state,
    output wire                     debug_rd_req,
    output wire [`TAG_WIDTH-1:0]    debug_mmu_tag,
    output wire [`INDEX_WIDTH-1:0]  debug_cpu_index,
    output wire                     debug_refill_cached,
    output wire [`INDEX_WIDTH-1:0]  debug_refill_index,
    output wire [`INDEX_WIDTH-1:0]  debug_req_index
);

    // ============================================================
    // 局部参数
    // ============================================================
    localparam INDEX_DEPTH = 1 << `INDEX_WIDTH;
    localparam BANK_NUM    = 4;
    localparam WAY_IDX_W   = $clog2(`WAY_NUM);
    localparam PLRU_W      = `WAY_NUM - 1;
    localparam TAGV_BYTES  = (`TAG_WIDTH + 1 + 7) / 8;

    localparam MAIN_IDLE       = 7'b0000001;
    localparam MAIN_LOOKUP     = 7'b0000010;
    localparam MAIN_REREAD     = 7'b0000100;
    localparam MAIN_WAITWR     = 7'b0001000;
    localparam MAIN_WAIT_WR_DONE = 7'b0010000;
    localparam MAIN_WAITRD     = 7'b0100000;
    localparam MAIN_REFILL     = 7'b1000000;

    localparam WB_IDLE  = 1'd0;
    localparam WB_WRITE = 1'd1;

    // ============================================================
    // RAM 存储阵列
    // ============================================================
    wire [`TAG_WIDTH:0]  tagv_rdata [0:`WAY_NUM-1];
    reg                  d_rdata    [0:`WAY_NUM-1];
    wire [31:0]          bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];
    reg                  d_ram      [0:`WAY_NUM-1][0:INDEX_DEPTH-1];
    reg  [`TAG_WIDTH:0]  vc_tagv    [0:3];
    reg  [`INDEX_WIDTH-1:0] vc_index [0:3];   // VC 条目 index — 命中需 tag+index 双匹配
    reg  [31:0]          vc_bank    [0:3][0:BANK_NUM-1];

    // ============================================================
    // 状态机有关，主状态机和wb状态机
    // ============================================================
    // 状态寄存器
    reg  [6:0] main_state;
    reg  [6:0] main_next;
    reg        wb_state;
    reg        wb_next;
    
    // 状态机节点
    wire main_idle   = (main_state == MAIN_IDLE);
    wire main_lookup = (main_state == MAIN_LOOKUP);
    wire main_reread = (main_state == MAIN_REREAD);
    wire main_waitwr     = (main_state == MAIN_WAITWR);
    wire main_wait_wr_done = (main_state == MAIN_WAIT_WR_DONE);
    wire main_waitrd     = (main_state == MAIN_WAITRD);
    wire main_refill = (main_state == MAIN_REFILL);
    wire wb_idle     = (wb_state == WB_IDLE);
    wire wb_write    = (wb_state == WB_WRITE);

    // ============================================================
    // 各个buffer的声明
    // ============================================================
    // Request Buffer — accept_new_req 时更新，miss 处理期间稳定
    reg                      req_op;
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg  [31:0]              req_wstrb_mask;
    reg  [31:0]              req_wdata;
    reg                      cacop_en_r;
    reg  [4:0]               cacop_code_r;
    reg  [WAY_IDX_W-1:0]     cacop_way_r;
    reg  [`INDEX_WIDTH-1:0]  cacop_index_r;
    reg                      cacop_is_index_r;
    reg                      cacop_is_hit_r;

    // Refill Buffer — 总线读上下文 + REFILL 拼装（6 信号）
    reg  [`INDEX_WIDTH-1:0]  refill_index;
    reg  [`TAG_WIDTH-1:0]    refill_tag;
    reg                      refill_cached;
    reg  [`OFFSET_WIDTH-1:0] refill_offset;
    reg  [WAY_IDX_W-1:0]     refill_replace_way;
    reg  [ 1:0]              refill_cnt;
    reg  [31:0]              refill_line [0:BANK_NUM-1];
    reg  [`WAY_NUM-1:0]      refill_way_hit_r;
    reg  [3:0]               refill_vc_way_hit_r;
    reg  [1:0]               refill_vc_hitway_idx_r;

    // Write Buffer — 命中 store 时写入，延迟写入 bank RAM
    reg                     wb_valid;
    reg  [`WAY_NUM-1:0]     wb_way_hit;
    reg  [`INDEX_WIDTH-1:0] wb_index;
    reg  [ 1:0]             wb_bank;
    reg  [31:0]             wb_wstrb_mask;
    reg  [31:0]             wb_wdata;

    // ============================================================
    // CACOP 组合译码
    // ============================================================
    wire cacop_is_index  = cacop_en && (cacop_code[4:3] != 2'b10);
    wire cacop_is_hit    = cacop_en && (cacop_code[4:3] == 2'b10);
    wire [`INDEX_WIDTH-1:0] cacop_index = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    wire [WAY_IDX_W-1:0]    cacop_way   = cacop_va[WAY_IDX_W-1:0];
     
     // ============================================================
    // 一些重要信号生成
    // ============================================================
    // 统一 RAM 读控制
    wire ram_read_en = accept_new_req || main_reread;
    wire [`INDEX_WIDTH-1:0] ram_raddr = main_reread ? refill_index
                                      : cacop_en    ? cacop_index
                                                    : cpu_index;

    // accept_new_req — (IDLE || LOOKUP hit) && !冲突 && accept_ok
    wire accept_new_req = accept_ok && (cpu_req || cacop_en) && (main_idle || (main_lookup && cache_hit)) 
                                    && !(wb_write && !cpu_op && (wb_bank == cpu_offset[3:2]));

    // REFILL 节拍
    wire refill_last = main_refill && return_valid && return_last;
    
    //lookup以后阶段判定是否是uncache store指令
    wire is_uncached_store = !refill_cached && req_op && !cacop_en_r;

    // VC→L1 交换使能 — WAITWR 拍 VC 命中时写 L1
    wire vc_write_cache = main_waitwr && |refill_vc_way_hit_r && !cacop_en_r;

    // 写回需求 — WAITWR 拍组合判定
    wire wr_needs_write = cacop_en_r ? (cacop_code_r[4:3]==2'b00 || cacop_code_r[4:3]==2'b01 || (cacop_code_r[4:3]==2'b10 && |refill_way_hit_r)) && d_rdata[replace_way]    
                                     : ((refill_cached && d_rdata[refill_replace_way]) || is_uncached_store);
    // ============================================================
    // Tag 比较与命中判断 — XOR 树实现（强制 LUT，避免 CARRY4 减法器）
    // ============================================================
    wire                  lookup_cached = cacop_en_r ? 1'b1        : mmu_cached;

    wire [`TAG_WIDTH-1:0] tag_diff     [0:`WAY_NUM-1];
    wire                  tag_match    [0:`WAY_NUM-1];
    wire [`WAY_NUM-1:0]   way_hit;
    genvar gh;
    generate
        for (gh = 0; gh < `WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign tag_diff[gh]  = tagv_rdata[gh][`TAG_WIDTH:1] ^ mmu_tag;
            assign tag_match[gh] = ~(|tag_diff[gh]);
            assign way_hit[gh]   = tagv_rdata[gh][0]
                                 && tag_match[gh]
                                 && (lookup_cached || cacop_en_r);
        end
    endgenerate

    wire cache_hit = (|way_hit) && !cacop_en_r && !mmu_cancel;

    // VC 命中判断 — XOR 树同时比较 tag（20-bit）和 index（8-bit）
    wire [`TAG_WIDTH-1:0] vc_tag_diff    [0:3];
    wire                  vc_tag_match   [0:3];
    wire [`INDEX_WIDTH-1:0] vc_idx_diff  [0:3];
    wire                  vc_idx_match   [0:3];
    wire [3:0] vc_way_hit;
    genvar gvc;
    generate
        for (gvc = 0; gvc < 4; gvc = gvc + 1) begin : vc_hit_gen
            assign vc_tag_diff[gvc]  = vc_tagv[gvc][`TAG_WIDTH:1] ^ mmu_tag;
            assign vc_tag_match[gvc] = ~(|vc_tag_diff[gvc]);
            assign vc_idx_diff[gvc]  = vc_index[gvc] ^ req_index;
            assign vc_idx_match[gvc] = ~(|vc_idx_diff[gvc]);
            assign vc_way_hit[gvc]   = vc_tagv[gvc][0]
                                    && vc_tag_match[gvc]
                                    && vc_idx_match[gvc]
                                    && (lookup_cached || cacop_en_r);
        end
    endgenerate

    wire vc_way_hit_any = |vc_way_hit && !cacop_en_r && !mmu_cancel;
    
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

    // LOOKUP 拍组合 VC 索引（供 load 数据选择）
    wire [1:0] vc_hitway_idx = vc_way_hit[0] ? 2'd0 : vc_way_hit[1] ? 2'd1 :
                               vc_way_hit[2] ? 2'd2 : 2'd3;

    // ============================================================
    // 替换路号计算
    // ============================================================   
    // 无效路计算
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

    // PLRU 预计算
    reg  [PLRU_W-1:0] plru [0:INDEX_DEPTH-1];
    reg  [WAY_IDX_W:0]   plru_node_pre;
    integer plv_pre;
    always @(*) begin
        plru_node_pre = 1;
        for (plv_pre = 0; plv_pre < WAY_IDX_W; plv_pre = plv_pre + 1)
            plru_node_pre = (plru_node_pre << 1) + plru[ram_raddr][plru_node_pre-1];
    end
    wire [WAY_IDX_W-1:0] plru_victim_pre = plru_node_pre - `WAY_NUM;

    reg  [WAY_IDX_W-1:0] plru_victim_r;
    always @(posedge clk) begin
        if (~resetn)
            plru_victim_r <= {WAY_IDX_W{1'b0}};
        else if (accept_new_req)
            plru_victim_r <= plru_victim_pre;
    end

    // 替换路号
    wire [WAY_IDX_W-1:0] replace_way = cacop_en_r ? ((cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r)
                                                  : (has_invalid ? invalid_way : plru_victim_r);

    // ============================================================
    // VC 更新
    // ============================================================
    // VC 更新 — 仅干净 victim 且 VC 未命中时追加（命中做交换，不走 FIFO）
    wire cache_write_vc = main_waitwr && tagv_rdata[refill_replace_way][0] && !d_rdata[refill_replace_way] && refill_cached && !cacop_en_r;
    wire cacop_write_vc = main_refill && cacop_en_r && (cacop_code_r[4:3] == 2'b10) && |refill_vc_way_hit_r;
    wire vc_invalidate = vc_write_cache && !(cache_write_vc && (vc_fifo_ptr == refill_vc_hitway_idx_r));
    reg  [1:0] vc_fifo_ptr;
    
    always @(posedge clk) begin
        if (~resetn) begin
            vc_fifo_ptr <= 2'd0;
            // VC 条目复位清 V — 否则 V 位为 x，x 会经 vc_way_hit 传播到
            // lookup_bank_data / lookup_read_hit_done 等数据选择路径
            vc_tagv[0]   <= {(`TAG_WIDTH+1){1'b0}};
            vc_tagv[1]   <= {(`TAG_WIDTH+1){1'b0}};
            vc_tagv[2]   <= {(`TAG_WIDTH+1){1'b0}};
            vc_tagv[3]   <= {(`TAG_WIDTH+1){1'b0}};
        end
        else begin
            if (cache_write_vc) begin
                vc_tagv[vc_fifo_ptr]       <= {tagv_rdata[refill_replace_way][`TAG_WIDTH:1], 1'b1};
                vc_index[vc_fifo_ptr]      <= refill_index;
                vc_bank[vc_fifo_ptr][0]    <= bank_rdata[refill_replace_way][0];
                vc_bank[vc_fifo_ptr][1]    <= bank_rdata[refill_replace_way][1];
                vc_bank[vc_fifo_ptr][2]    <= bank_rdata[refill_replace_way][2];
                vc_bank[vc_fifo_ptr][3]    <= bank_rdata[refill_replace_way][3];
                vc_fifo_ptr                <= vc_fifo_ptr + 2'd1;
            end
            if (vc_invalidate) begin
                vc_tagv[refill_vc_hitway_idx_r][0] <= 1'b0;
            end
            else if (cacop_write_vc) begin
                vc_tagv[refill_vc_hitway_idx_r][0] <= 1'b0;
            end
        end
    end

    // ============================================================
    // 各状态机变化 — 时序
    // ============================================================
    // 主状态机时序变化
    always @(posedge clk) begin
        if (~resetn)
            main_state <= MAIN_IDLE;
        else
            main_state <= main_next;
    end

    // ============================================================
    // 主状态机 — 下一状态逻辑（并行 assign，消除 case 级联延迟）
    // ============================================================
    wire cache_miss = !cache_hit;

    wire main_idle_lookup   = main_idle   && accept_new_req;

    wire main_lookup_reread = main_lookup && cache_miss && !mmu_cancel;
    wire main_lookup_lookup = main_lookup && cache_hit && accept_new_req;

    wire main_reread_waitwr = main_reread;

    wire main_waitwr_vc_idle   = main_waitwr && vc_write_cache
                               && (!wr_needs_write || wr_rdy);
    wire main_waitwr_vc_stay   = main_waitwr && vc_write_cache
                               && wr_needs_write && !wr_rdy;
    wire main_waitwr_waitdone  = main_waitwr && !vc_write_cache
                               && is_uncached_store && wr_rdy;
    wire main_waitwr_refill    = main_waitwr && !vc_write_cache
                               && !is_uncached_store
                               && (!wr_needs_write || wr_rdy) && cacop_en_r;
    wire main_waitwr_waitrd    = main_waitwr && !vc_write_cache
                               && !is_uncached_store
                               && (!wr_needs_write || wr_rdy) && !cacop_en_r;
    wire main_waitwr_stay      = main_waitwr && !vc_write_cache
                               && (is_uncached_store ? !wr_rdy
                                   : wr_needs_write && !wr_rdy);

    wire main_waitdone_idle   = main_wait_wr_done && wr_done;
    wire main_waitdone_stay   = main_wait_wr_done && !wr_done;

    wire main_waitrd_refill   = main_waitrd && rd_rdy;
    wire main_waitrd_stay     = main_waitrd && !rd_rdy;

    wire main_refill_idle     = main_refill && (refill_last || cacop_en_r);
    wire main_refill_stay     = main_refill && !refill_last && !cacop_en_r;

    always @(*) begin
        main_next = MAIN_IDLE;
        if (main_idle_lookup)                              main_next = MAIN_LOOKUP;
        if (main_lookup_lookup)                            main_next = MAIN_LOOKUP;
        if (main_lookup_reread)                            main_next = MAIN_REREAD;
        if (main_reread_waitwr)                            main_next = MAIN_WAITWR;
        if (main_waitwr_vc_idle)                           main_next = MAIN_IDLE;
        if (main_waitwr_refill)                            main_next = MAIN_REFILL;
        if (main_waitwr_waitrd)                            main_next = MAIN_WAITRD;
        if (main_waitwr_waitdone)                          main_next = MAIN_WAIT_WR_DONE;
        if (main_waitwr_vc_stay)                           main_next = MAIN_WAITWR;
        if (main_waitwr_stay)                              main_next = MAIN_WAITWR;
        if (main_waitdone_idle)                            main_next = MAIN_IDLE;
        if (main_waitdone_stay)                            main_next = MAIN_WAIT_WR_DONE;
        if (main_waitrd_refill)                            main_next = MAIN_REFILL;
        if (main_waitrd_stay)                              main_next = MAIN_WAITRD;
        if (main_refill_idle)                              main_next = MAIN_IDLE;
        if (main_refill_stay)                              main_next = MAIN_REFILL;
    end

    // Write Buffer 状态机 — 时序
    always @(posedge clk) begin
        if (~resetn)
            wb_state <= WB_IDLE;
        else
            wb_state <= wb_next;
    end

    wire wb_new_store_hit = main_lookup && cache_hit && req_op;

    always @(*) begin
        case (wb_state)
            WB_IDLE:   wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            WB_WRITE:  wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            default:   wb_next = WB_IDLE;
        endcase
    end

    // ============================================================
    // PLRU 更新
    // ============================================================
    wire                 plru_upd_en    = (main_lookup && cache_hit) || refill_tagv_we;
    wire [WAY_IDX_W-1:0] plru_upd_way   = (main_lookup && cache_hit) ? hit_way_idx : refill_replace_way;
    wire [`INDEX_WIDTH-1:0] plru_upd_index = refill_tagv_we ? (cacop_en_r ? cacop_index_r : refill_index) : req_index;

    integer pnode, pparent, pui, prst;
    always @(posedge clk) begin
        if (~resetn) begin
            for (prst = 0; prst < INDEX_DEPTH; prst = prst + 1)
                plru[prst] = {PLRU_W{1'b0}};
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
    // 各个buffer的更新
    // ============================================================
    // request buffer
    always @(posedge clk) begin
        if (~resetn) begin
            req_op           <= 1'b0;
            req_index        <= {`INDEX_WIDTH{1'b0}};
            req_offset       <= {`OFFSET_WIDTH{1'b0}};
            req_wstrb_mask   <= 32'd0;
            req_wdata        <= 32'd0;
            cacop_en_r       <= 1'b0;
            cacop_code_r     <= 5'b0;
            cacop_way_r      <= {WAY_IDX_W{1'b0}};
            cacop_index_r    <= {`INDEX_WIDTH{1'b0}};
            cacop_is_index_r <= 1'b0;
            cacop_is_hit_r   <= 1'b0;
        end
        else if (accept_new_req) begin
            req_op           <= cpu_op;
            req_index        <= cpu_index;
            req_offset       <= cpu_offset;
            req_wstrb_mask   <= { {8{cpu_wstrb[3]}}, {8{cpu_wstrb[2]}},
                                  {8{cpu_wstrb[1]}}, {8{cpu_wstrb[0]}} };
            req_wdata        <= cpu_wdata;
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

    // Write Buffer — 时序更新
    always @(posedge clk) begin
        if (wb_new_store_hit) begin
            wb_valid       <= 1'b1;
            wb_way_hit     <= way_hit;
            wb_index       <= req_index;
            wb_bank        <= req_offset[3:2];
            wb_wstrb_mask  <= req_wstrb_mask;
            wb_wdata       <= req_wdata;
        end
        else if (wb_write && !wb_new_store_hit) begin
            wb_valid <= 1'b0;
        end
    end

    // Refill Buffer — LOOKUP miss 锁存，REFILL 拼装
    always @(posedge clk) begin
        // LOOKUP miss: 锁存总线读上下文 + 牺牲路号
        if (main_lookup && !cache_hit && !mmu_cancel) begin
            refill_index       <= req_index;
            refill_tag         <= mmu_tag;
            refill_cached      <= lookup_cached;
            refill_offset      <= req_offset;
            refill_replace_way <= replace_way;
            refill_cnt         <= 2'd0;
            refill_way_hit_r    <= way_hit;
            refill_vc_way_hit_r  <= vc_way_hit;
            refill_vc_hitway_idx_r <= vc_hitway_idx;
        end
        // REFILL 计数
        if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= refill_merged_word;
        end
    end

    // ============================================================
    // 数据处理
    // ============================================================
    // lookup返回数据
    wire [31:0] lookup_bank_data = vc_way_hit_any ? vc_bank[vc_hitway_idx][req_offset[3:2]] : bank_rdata[hit_way_idx][req_offset[3:2]];

    wire [31:0] lookup_rdata = (main_lookup && wb_write && !req_op && !vc_way_hit_any && (wb_index == req_index) && wb_way_hit[hit_way_idx] && (wb_bank == req_offset[3:2])) ?
                               ((wb_wdata & wb_wstrb_mask) | (lookup_bank_data & ~wb_wstrb_mask)) : lookup_bank_data;

    // REFILL 合并写数据
    wire [3:0] req_wstrb_4b = {req_wstrb_mask[31], req_wstrb_mask[23], req_wstrb_mask[15], req_wstrb_mask[ 7]};
    wire wstrb_hw = (req_wstrb_4b == 4'b0011) || (req_wstrb_4b == 4'b1100);
    wire [31:0] refill_merged_word = (req_op && (refill_cnt == refill_offset[3:2]))
                                     ? ((req_wdata & req_wstrb_mask) | (return_data & ~req_wstrb_mask))
                                     : return_data;

    // ============================================================
    // 存储数据管理
    // ============================================================
    // TagV相关逻辑
    wire refill_tagv_we = main_refill && ((return_valid && return_last && refill_cached) || (cacop_en_r && ((cacop_code_r[4:3] == 2'b00)|| (cacop_code_r[4:3] == 2'b01) || ((cacop_code_r[4:3] == 2'b10) && (|refill_way_hit_r)))));
    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel = cacop_en_r ? cacop_index_r : refill_index;
    wire [ 3:0]             tagv_wmask_sel = (cacop_en_r && (cacop_code_r[4:3] == 2'b01 || cacop_code_r[4:3] ==2'b10))  ? 4'b0001 : {TAGV_BYTES{1'b1}};
    wire [`TAG_WIDTH:0]     tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} } : vc_write_cache ? vc_tagv[refill_vc_hitway_idx_r] : {refill_tag, 1'b1};


    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire tagv_wr = (refill_tagv_we && (refill_replace_way == gt)) || (vc_write_cache && (refill_replace_way == gt));
            wire        tagv_en  = tagv_wr || ram_read_en;
            wire [ 3:0] tagv_wen = tagv_wr ? tagv_wmask_sel : 4'b0;
            wire [`INDEX_WIDTH-1:0] tagv_addr = tagv_wr ? tagv_waddr_sel : ram_raddr;

            sp_ram #(
                .WIDTH (`TAG_WIDTH + 1),
                .DEPTH (INDEX_DEPTH),
                .ADDRW (`INDEX_WIDTH)
            ) u_tagv_ram (
                .clk   (clk),
                .en    (tagv_en),
                .wen   (tagv_wen),
                .addr  (tagv_addr),
                .wdata ({ {32-(`TAG_WIDTH+1){1'b0}}, tagv_wdata_sel }),
                .rdata (tagv_rdata[gt])
            );
        end
    endgenerate

    // D RAM相关逻辑
    integer d_wi;
    integer d_idx;
    always @(posedge clk) begin
        if (~resetn) begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                for (d_idx = 0; d_idx < INDEX_DEPTH; d_idx = d_idx + 1)
                    d_ram[d_wi][d_idx] = 1'b0;
            end
        end
        else begin
            for (d_wi = 0; d_wi < `WAY_NUM; d_wi = d_wi + 1) begin
                if ((main_refill && return_valid && return_last && refill_cached) && (refill_replace_way == d_wi))
                    d_ram[d_wi][refill_index] <= req_op;
                else if (vc_write_cache && (refill_replace_way == d_wi))
                    d_ram[d_wi][refill_index] <= req_op;
                else if (wb_write && wb_way_hit[d_wi])
                    d_ram[d_wi][wb_index] <= 1'b1;
                if (ram_read_en)
                    d_rdata[d_wi] <= d_ram[d_wi][ram_raddr];
            end
        end
    end

    // Data Bank RAM 例化
    genvar gw, gb;
    generate
        for (gw = 0; gw < `WAY_NUM; gw = gw + 1) begin : bank_ram_way
            for (gb = 0; gb < BANK_NUM; gb = gb + 1) begin : bank_ram_col
                wire bank_wr_refill = main_refill && return_valid && return_last && (refill_replace_way == gw) && refill_cached;
                wire bank_wr_hit    = wb_write && wb_way_hit[gw] && (wb_bank == gb);
                wire bank_wr_vc     = vc_write_cache && (refill_replace_way == gw);

                wire bank_en  = bank_wr_refill || bank_wr_hit || bank_wr_vc || ram_read_en;
                wire [ 3:0] bank_wen = bank_wr_refill ? 4'b1111 :
                                       bank_wr_hit    ? {wb_wstrb_mask[24], wb_wstrb_mask[16], wb_wstrb_mask[ 8], wb_wstrb_mask[ 0]} :
                                       bank_wr_vc     ? 4'b1111 : 4'b0;
                wire [`INDEX_WIDTH-1:0] bank_addr = bank_wr_refill ? refill_index :
                                                    bank_wr_hit    ? wb_index :
                                                    bank_wr_vc     ? refill_index : ram_raddr;

                // VC→L1 合并写 — 类比 refill_merged_word，store 数据合并到 VC 数据的对应 bank
                wire [31:0] vc_bank_merged = (req_op && (gb == refill_offset[3:2])) ?
                                             ((req_wdata & req_wstrb_mask) | (vc_bank[refill_vc_hitway_idx_r][gb] & ~req_wstrb_mask)) :
                                             vc_bank[refill_vc_hitway_idx_r][gb];

                wire [31:0] bank_wdata = bank_wr_refill ? ((refill_cnt == gb) ? refill_merged_word : refill_line[gb]) :
                                         bank_wr_hit    ? wb_wdata :
                                         bank_wr_vc     ? vc_bank_merged : 32'd0;

                sp_ram #(
                    .WIDTH (32),
                    .DEPTH (INDEX_DEPTH),
                    .ADDRW (`INDEX_WIDTH)
                ) u_bank_ram (
                    .clk   (clk),
                    .en    (bank_en),
                    .wen   (bank_wen),
                    .addr  (bank_addr),
                    .wdata (bank_wdata),
                    .rdata (bank_rdata[gw][gb])   // 读输出保持外层数组索引
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

    wire cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);
    wire cpu_fifo_we = (lookup_read_hit_done || refill_read_miss_done) && !(cpu_accept && cpu_fifo_empty);
    wire cpu_fifo_re = cpu_accept && !cpu_fifo_empty;

    wire lookup_read_hit_done  = main_lookup && (cache_hit || vc_way_hit_any) && !req_op;
    wire lookup_write_done     = main_lookup && req_op && !mmu_cancel;
    wire refill_read_miss_done = main_refill && return_valid && !req_op && (refill_cnt == refill_offset[3:2] || !refill_cached);

    wire [31:0] live_rdata = lookup_read_hit_done  ? lookup_rdata :
                             refill_read_miss_done ? return_data : 32'd0;

    wire accept_ok = cpu_op || (cpu_fifo_cnt < 3'd3) || (cpu_fifo_cnt == 3'd3 && req_op);

    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign cpu_data_ok = (lookup_read_hit_done || refill_read_miss_done || !cpu_fifo_empty) || lookup_write_done;
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
    // AXI 交互
    // ============================================================
    // AXI读请求
    assign rd_req = main_waitrd;

    assign rd_type = refill_cached ? 3'b100 : 3'b010;

    assign rd_addr = refill_cached
                   ? {refill_tag, refill_index, 4'b0000}
                   : {refill_tag, refill_index, refill_offset};

    // AXI 写请求 — 仅 WAITWR 状态
    assign wr_req = main_waitwr && wr_needs_write;

    assign wr_type = !is_uncached_store ? 3'b100
                   : (&req_wstrb_4b)     ? 3'b010
                   : wstrb_hw            ? 3'b001
                                         : 3'b000;

    assign wr_addr = !is_uncached_store
                   ? {tagv_rdata[refill_replace_way][`TAG_WIDTH:1], refill_index, 4'b0000}
                   : {refill_tag, refill_index, refill_offset};

    assign wr_wstrb = !is_uncached_store ? 4'b1111 : req_wstrb_4b;

    assign wr_data = !is_uncached_store
                   ? {bank_rdata[refill_replace_way][3], bank_rdata[refill_replace_way][2],
                      bank_rdata[refill_replace_way][1], bank_rdata[refill_replace_way][0]}
                   : {96'd0, req_wdata};

    // ============================================================
    // 性能计数器
    // ============================================================
    reg [31:0] perf_total_req       /*verilator public*/;   // 访存指令总数（load+store，不含 cacop）
    reg [31:0] perf_access_cnt      /*verilator public*/;   // cache 指令总数
    reg [31:0] perf_miss_cnt        /*verilator public*/;   // cache 指令中 L1 miss（含 VC hit）
    reg [31:0] perf_real_miss_cnt   /*verilator public*/;   // L1 miss 且 VC 也 miss（真实 miss）
    reg [31:0] perf_vc_hit_cnt      /*verilator public*/;   // L1 miss 但 VC 命中

    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
            perf_vc_hit_cnt       <= 32'd0;
        end
        else begin
            if (accept_new_req && !cacop_en)
                perf_total_req <= perf_total_req + 32'd1;
            if (main_lookup && mmu_cached && !cacop_en_r && !mmu_cancel) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit) begin
                    perf_miss_cnt <= perf_miss_cnt + 32'd1;
                    if (vc_way_hit_any)
                        perf_vc_hit_cnt <= perf_vc_hit_cnt + 32'd1;
                    else
                        perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
                end
            end
        end
    end

    // ========== debug ==========
    assign debug_main_state    = main_state;
    assign debug_rd_req        = rd_req;
    assign debug_mmu_tag       = mmu_tag;
    assign debug_cpu_index     = cpu_index;
    assign debug_refill_cached = refill_cached;
    assign debug_refill_index  = refill_index;
    assign debug_req_index     = req_index;

endmodule
