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
    input  wire                    mmu_cache,
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

    // ============================================================
    // 状态寄存器
    // ============================================================
    reg  [6:0] main_state;
    reg  [6:0] main_next;
    reg        wb_state;
    reg        wb_next;

    // ============================================================
    // 状态机节点
    // ============================================================
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
    // Request Buffer — accept_new_req 时更新，miss 处理期间稳定
    // ============================================================
    reg                     req_op;
    reg  [`INDEX_WIDTH-1:0] req_index;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg  [31:0]             req_wstrb_mask;
    reg  [31:0]             req_wdata;
    reg                     cacop_en_r;
    reg  [4:0]              cacop_code_r;
    reg  [WAY_IDX_W-1:0]    cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;

    // ============================================================
    // Refill Buffer — 总线读上下文 + REFILL 拼装
    // ============================================================
    reg  [`INDEX_WIDTH-1:0]  refill_index;
    reg  [`TAG_WIDTH-1:0]    refill_tag;
    reg                     refill_cached;
    reg  [`OFFSET_WIDTH-1:0] refill_offset;
    reg  [WAY_IDX_W-1:0]    refill_replace_way;
    reg  [ 1:0]             refill_cnt;
    reg  [31:0]             refill_line [0:BANK_NUM-1];

    // ============================================================
    // Write Buffer — 命中 store 时写入，延迟写入 bank RAM
    // ============================================================
    reg                     wb_valid;
    reg  [`WAY_NUM-1:0]     wb_way_hit;
    reg  [`INDEX_WIDTH-1:0] wb_index;
    reg  [ 1:0]             wb_bank;
    reg  [31:0]             wb_wstrb_mask;
    reg  [31:0]             wb_wdata;

    // ============================================================
    // 树状伪 LRU
    // ============================================================
    reg  [PLRU_W-1:0] plru [0:INDEX_DEPTH-1];

    // ============================================================
    // CACOP 组合译码
    // ============================================================
    wire cacop_is_index  = cacop_en && (cacop_code[4:3] != 2'b10);
    wire cacop_is_hit    = cacop_en && (cacop_code[4:3] == 2'b10);
    wire [`INDEX_WIDTH-1:0] cacop_index = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    wire [WAY_IDX_W-1:0]    cacop_way   = cacop_va[WAY_IDX_W-1:0];

    // ============================================================
    // 统一 RAM 读控制
    // ============================================================
    wire ram_read_en = accept_new_req || main_reread;

    wire [`INDEX_WIDTH-1:0] ram_raddr = main_reread ? refill_index
                                      : cacop_en    ? cacop_index
                                                    : cpu_index;

    // ============================================================
    // accept_new_req — (IDLE || LOOKUP hit) && !冲突 && accept_ok
    // ============================================================
    wire accept_new_req = accept_ok && (cpu_req || cacop_en) && (main_idle || (main_lookup && cache_hit))
                                    && !(wb_write && !cpu_op && (wb_bank == cpu_offset[3:2]));

    // ============================================================
    // REFILL 节拍
    // ============================================================
    wire refill_last = main_refill && return_valid && return_last;

    // ============================================================
    // MMU 取消
    // ============================================================
    wire effective_cancel = mmu_cancel;

    // ============================================================
    // Tag 比较与命中判断
    // ============================================================

    wire [`WAY_NUM-1:0] way_hit;
    genvar gh;
    generate
        for (gh = 0; gh < `WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign way_hit[gh] = tagv_rdata[gh][0]
                               && (tagv_rdata[gh][`TAG_WIDTH:1] == mmu_tag)
                               && (mmu_cache || cacop_en_r);
        end
    endgenerate

    wire cache_hit = (|way_hit) && !cacop_en_r && !effective_cancel;

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
            if (!tagv_rdata[vwi][0]) begin
                has_invalid = 1'b1;
                invalid_way = vwi[WAY_IDX_W-1:0];
            end
    end

    // ============================================================
    // PLRU 预计算
    // ============================================================
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

    // ============================================================
    // 替换路号
    // ============================================================
    wire [WAY_IDX_W-1:0] replace_way = cacop_en_r ? ((cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r)
                                                  : (has_invalid ? invalid_way : plru_victim_r);

    // ============================================================
    // 衍生判断
    // ============================================================
    wire is_uncached_store = !refill_cached && req_op && !cacop_en_r;

    // 写回需求 — WAITWR 拍组合判定
    wire wr_needs_write = cacop_en_r ? ( ((cacop_code_r[4:3] != 2'b11) && !((cacop_code_r[4:3] == 2'b10) && !(|way_hit))) && d_rdata[replace_way] )
                                     : ( (refill_cached && d_rdata[refill_replace_way]) || is_uncached_store );

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
                main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
            end
            MAIN_LOOKUP: begin
                if (effective_cancel)
                    main_next = MAIN_IDLE;
                else if (cache_hit) begin
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                else begin
                    main_next = MAIN_REREAD;
                end
            end
            MAIN_REREAD: begin
                main_next = MAIN_WAITWR;
            end
            MAIN_WAITWR: begin
                if (is_uncached_store) begin
                    main_next = wr_rdy ? MAIN_WAIT_WR_DONE : MAIN_WAITWR;
                end
                else if (!wr_needs_write || wr_rdy) begin
                    main_next = cacop_en_r ? MAIN_REFILL : MAIN_WAITRD;
                end
                else begin
                    main_next = MAIN_WAITWR;
                end
            end
            MAIN_WAIT_WR_DONE: begin
                main_next = wr_done ? MAIN_IDLE : MAIN_WAIT_WR_DONE;
            end
            MAIN_WAITRD: begin
                main_next = rd_rdy ? MAIN_REFILL : MAIN_WAITRD;
            end
            MAIN_REFILL: begin
                main_next = (refill_last || cacop_en_r) ? MAIN_IDLE : MAIN_REFILL;
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
    // Request Buffer — 时序更新
    // ============================================================
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

    // ============================================================
    // Write Buffer — 时序更新
    // ============================================================
    always @(posedge clk) begin
        if (wb_new_store_hit) begin
            wb_valid       <= 1'b1;
            wb_way_hit     <= way_hit;
            wb_index       <= req_index;
            wb_bank        <= req_offset[3:2];
            wb_wstrb_mask  <= req_wstrb_mask;
            wb_wdata       <= req_wdata;
        end
        else if (wb_write && !ram_read_en && !wb_new_store_hit) begin
            wb_valid <= 1'b0;
        end
    end

    // ============================================================
    // Refill Buffer — LOOKUP miss 从 MMU 信号锁存，REFILL 拼装
    // ============================================================
    always @(posedge clk) begin
        if (main_lookup && !cache_hit && !effective_cancel) begin
            refill_index       <= req_index;
            refill_tag         <= mmu_tag;
            refill_cached      <= mmu_cache;
            refill_offset      <= req_offset;
            refill_replace_way <= replace_way;
            refill_cnt         <= 2'd0;
        end
        if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= refill_merged_word;
        end
    end

    // ============================================================
    // 数据选择
    // ============================================================
    wire [31:0] lookup_rdata = (main_lookup && wb_write && !req_op && (wb_index == req_index) && wb_way_hit[hit_way_idx]  && (wb_bank == req_offset[3:2]))
                               ? ((wb_wdata & wb_wstrb_mask) | (bank_rdata[hit_way_idx][req_offset[3:2]] & ~wb_wstrb_mask))
                               : bank_rdata[hit_way_idx][req_offset[3:2]];

    // ============================================================
    // REFILL 合并写数据
    // ============================================================
    wire [3:0] req_wstrb_4b = {req_wstrb_mask[31], req_wstrb_mask[23],
                               req_wstrb_mask[15], req_wstrb_mask[ 7]};
    wire wstrb_hw = (req_wstrb_4b == 4'b0011) || (req_wstrb_4b == 4'b1100);

    wire [31:0] refill_merged_word = (req_op && (refill_cnt == refill_offset[3:2]))
        ? ((req_wdata & req_wstrb_mask) | (return_data & ~req_wstrb_mask))
        : return_data;

    // ============================================================
    // {Tag, V} RAM 写控制
    // ============================================================
    wire refill_tagv_we = (main_refill && return_valid && return_last && refill_cached)
                        || (main_refill && cacop_en_r);

    wire tagv_do_write = refill_tagv_we && ( !cacop_en_r
            || (cacop_en_r && (cacop_code_r[4:3] == 2'b00))
            || (cacop_en_r && (cacop_code_r[4:3] == 2'b01))
            || (cacop_en_r && (cacop_code_r[4:3] == 2'b10) && (|way_hit)) );

    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel = cacop_en_r ? cacop_index_r : refill_index;
    wire [ 3:0]            tagv_wmask_sel = (cacop_en_r && (cacop_code_r[4:3] == 2'b01))
                                          || (cacop_en_r && (cacop_code_r[4:3] == 2'b10))
                                            ? 4'b0001 : {TAGV_BYTES{1'b1}};
    wire [`TAG_WIDTH:0]     tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }
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
            wire tagv_wr = (tagv_do_write && (refill_replace_way == gt));
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
                if ((main_refill && return_valid && return_last && refill_cached)
                    && (refill_replace_way == d_wi))
                    d_ram[d_wi][refill_index] <= req_op;
                else if (wb_write && wb_way_hit[d_wi] && !ram_read_en)
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
                assign bank_wr_hit[gw][gb]    = wb_write && wb_way_hit[gw]
                                              && (wb_bank == gb) && !ram_read_en;

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb]
                                          || bank_wr_hit[gw][gb]
                                          || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 4'b1111
                                          : bank_wr_hit[gw][gb]    ? {wb_wstrb_mask[24], wb_wstrb_mask[16],
                                                                      wb_wstrb_mask[ 8], wb_wstrb_mask[ 0]}
                                                                    : 4'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? refill_index
                                          : bank_wr_hit[gw][gb]    ? wb_index
                                                                    : ram_raddr;
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb]
                                          ? ((refill_cnt == gb) ? refill_merged_word : refill_line[gb])
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

    wire cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);
    wire cpu_fifo_we = read_result_ready
                     && !(cpu_accept && cpu_fifo_empty && read_result_ready);
    wire cpu_fifo_re = cpu_accept && !cpu_fifo_empty;

    wire read_hit_done  = main_lookup && cache_hit && !req_op;
    wire write_done     = main_lookup && req_op && !effective_cancel;
    wire read_miss_done = main_refill && return_valid && !req_op
                        && (refill_cnt == refill_offset[3:2] || !refill_cached);

    wire read_result_ready = read_hit_done || read_miss_done;
    wire [31:0] live_rdata = read_hit_done  ? lookup_rdata
                           : read_miss_done ? return_data
                                            : 32'd0;

    wire accept_ok = cpu_op
                  || (cpu_fifo_cnt < 3'd3)
                  || (cpu_fifo_cnt == 3'd3 && req_op);

    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
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
    // AXI 读请求 — 仅在 WAITRD 状态
    // ============================================================
    assign rd_req = main_waitrd;

    assign rd_type = refill_cached ? 3'b100 : 3'b010;

    assign rd_addr = refill_cached
                   ? {refill_tag, refill_index, 4'b0000}
                   : {refill_tag, refill_index, refill_offset};

    // ============================================================
    // AXI 写请求 — 仅 WAITWR 状态
    // ============================================================
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
    reg [31:0] perf_total_req       /*verilator public*/;
    reg [31:0] perf_access_cnt      /*verilator public*/;
    reg [31:0] perf_miss_cnt        /*verilator public*/;
    reg [31:0] perf_real_miss_cnt   /*verilator public*/;

    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
        end
        else begin
            if (accept_new_req)
                perf_total_req <= perf_total_req + 32'd1;
            if (main_lookup && mmu_cache && !cacop_en_r) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit) begin
                    perf_miss_cnt      <= perf_miss_cnt + 32'd1;
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
