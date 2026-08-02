`include "mycpu.h"

module icache (
    // 时钟与复位
    input  wire                 clk,
    input  wire                 resetn,

    // CPU 流水线接口（只读）
    input  wire                     cpu_req,
    input  wire [`INDEX_WIDTH-1:0]  cpu_index,
    input  wire [ `TAG_WIDTH-1:0]   mmu_tag,
    input  wire [`OFFSET_WIDTH-1:0] cpu_offset,
    input  wire                     mmu_cache,
    input  wire                     mmu_cancel, 
    input  wire                     mmu_cacop_cancel,
    output wire                     cpu_addr_ok,
    output wire                     cpu_data_ok,
    output wire [31:0]              cpu_rdata,
    input  wire                     cpu_accept,

    // AXI 读接口
    output wire                 rd_req,
    output wire [ 2:0]          rd_type,
    output wire [31:0]          rd_addr,
    input  wire                 rd_rdy,
    input  wire                 return_valid,
    input  wire                 return_last,
    input  wire [31:0]          return_data,

    // CACOP 接口
    input  wire                    cacop_en,
    input  wire [ 4:0]             cacop_code,
    input  wire [31:0]             cacop_va,
    input  wire [`TAG_WIDTH-1:0]   mmu_cacop_tag,
    output wire                    cacop_rdy,

    // debug
    output wire [ 3:0]              debug_main_state,
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
    // 状态机有关，主状态机和wb状态机
    // ============================================================
    // 状态寄存器
    reg  [3:0] main_state;
    reg  [3:0] main_next;

    // 状态机节点
    wire main_idle   = (main_state == MAIN_IDLE);
    wire main_lookup = (main_state == MAIN_LOOKUP);
    wire main_waitrd = (main_state == MAIN_WAITRD);
    wire main_refill = (main_state == MAIN_REFILL);

    // ============================================================
    // 各个buffer的声明
    // ============================================================
    // Request Buffer — accept_new_req 时更新，miss 处理期间稳定
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg                      cacop_en_r;
    reg  [4:0]               cacop_code_r;
    reg  [WAY_IDX_W-1:0]     cacop_way_r;
    reg  [`INDEX_WIDTH-1:0]  cacop_index_r;

    // Refill Buffer — LOOKUP miss 拍从 Request Buffer 快照，REFILL 期间不变
    reg  [`INDEX_WIDTH-1:0]  refill_index;
    reg  [`TAG_WIDTH-1:0]    refill_tag;
    reg  [`OFFSET_WIDTH-1:0] refill_offset;
    reg                      refill_cached;
    reg  [WAY_IDX_W-1:0]     refill_replace_way;
    reg  [ 1:0]              refill_cnt;
    reg  [31:0]              refill_line [0:BANK_NUM-1];
    reg  [`WAY_NUM-1:0]      refill_way_hit_r;

    // ============================================================
    // CACOP 辅助信号
    // ============================================================
    wire cacop_is_index = cacop_en && (cacop_code[4:3] != 2'b10);
    wire cacop_is_hit   = cacop_en && (cacop_code[4:3] == 2'b10);
    wire [`INDEX_WIDTH-1:0] cacop_index = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    wire [WAY_IDX_W-1:0]    cacop_way   = cacop_va[WAY_IDX_W-1:0];
    
    // ============================================================
    // 一些重要信号生成
    // ============================================================
    // 统一 RAM 读控制
    wire ram_read_en = accept_new_req;

    wire [`INDEX_WIDTH-1:0] ram_raddr = cacop_en ? cacop_index : cpu_index;
    
    // accept_new_req
    wire accept_new_req = accept_ok && (cpu_req || cacop_en) && (main_idle || (main_lookup && cache_hit)); 

    // REFILL 节拍
    wire refill_last = main_refill && return_valid && return_last;
    
    // 无效信号生成
    wire lookup_cancel = cacop_en_r ? mmu_cacop_cancel : mmu_cancel;

    // ============================================================
    // Tag 比较与命中判断
    // ============================================================
    wire [`TAG_WIDTH-1:0] lookup_tag    = cacop_en_r ? mmu_cacop_tag : mmu_tag;
    wire                  lookup_cache  = cacop_en_r ? 1'b1          : mmu_cache;

    wire [`TAG_WIDTH-1:0] tag_diff     [0:`WAY_NUM-1];
    wire                  tag_match    [0:`WAY_NUM-1];
    wire [`WAY_NUM-1:0]   way_hit;
    genvar gh;
    generate
        for (gh = 0; gh < `WAY_NUM; gh = gh + 1) begin : way_hit_gen
            assign tag_diff[gh]  = tagv_rdata[gh][`TAG_WIDTH:1] ^ lookup_tag;
            assign tag_match[gh] = ~(|tag_diff[gh]);
            assign way_hit[gh]   = tagv_rdata[gh][0]
                                 && tag_match[gh]
                                 && (lookup_cache || cacop_en_r);
        end
    endgenerate

    wire cache_hit = (|way_hit) && !cacop_en_r && !lookup_cancel;
    
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
    
    // PLRU 预计算 — accept 拍遍历 PLRU 树
    reg  [PLRU_W-1:0]  plru [0:INDEX_DEPTH-1];
    reg  [WAY_IDX_W:0] plru_node_pre;
    wire pre_plru_en = accept_new_req;
    wire [`INDEX_WIDTH-1:0] pre_plru_index = ram_raddr;
   
    integer plv_pre;
    always @(*) begin
        plru_node_pre = 1;
        for (plv_pre = 0; plv_pre < WAY_IDX_W; plv_pre = plv_pre + 1)
            plru_node_pre = (plru_node_pre << 1) + plru[pre_plru_index][plru_node_pre-1];
    end
    wire [WAY_IDX_W-1:0] plru_victim_pre = plru_node_pre - `WAY_NUM;

    reg  [WAY_IDX_W-1:0] plru_victim_r;
    always @(posedge clk) begin
        if (~resetn)
            plru_victim_r <= {WAY_IDX_W{1'b0}};
        else if (pre_plru_en)
            plru_victim_r <= plru_victim_pre;
    end
    
    // 替换路号
    wire [WAY_IDX_W-1:0] replace_way = cacop_en_r ? ((cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r) : 
                                                     (has_invalid ? invalid_way : plru_victim_r);

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

    // 主状态机 — 下一状态逻辑（并行 assign，消除 case 级联延迟）
    wire main_idle_stay    = main_idle   && !accept_new_req;
    wire main_idle_lookup  = main_idle   && accept_new_req;

    wire main_lookup_cancel = main_lookup && lookup_cancel;
    wire main_lookup_refill = main_lookup && !lookup_cancel
                            && (cacop_en_r || (!cache_hit && rd_rdy));
    wire main_lookup_waitrd = main_lookup && !cache_hit && !rd_rdy
                            && !cacop_en_r && !lookup_cancel;
    wire main_lookup_hit    = main_lookup && cache_hit
                            && !cacop_en_r && !lookup_cancel;

    wire main_waitrd_refill = main_waitrd && rd_rdy;
    wire main_waitrd_wait   = main_waitrd && !rd_rdy;

    wire main_refill_idle   = main_refill && (refill_last || cacop_en_r);
    wire main_refill_stay   = main_refill && !refill_last && !cacop_en_r;

    always @(*) begin
        main_next = MAIN_IDLE;
        if (main_idle_lookup)                              main_next = MAIN_LOOKUP;
        if (main_lookup_refill)                            main_next = MAIN_REFILL;
        if (main_lookup_waitrd)                            main_next = MAIN_WAITRD;
        if (main_lookup_hit && accept_new_req)             main_next = MAIN_LOOKUP;
        if (main_waitrd_refill)                            main_next = MAIN_REFILL;
        if (main_waitrd_wait)                              main_next = MAIN_WAITRD;
        if (main_refill_stay)                              main_next = MAIN_REFILL;
    end

    // ============================================================
    // PLRU 更新 — 命中 / 填充时标 MRU
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
            req_index        <= {`INDEX_WIDTH{1'b0}};
            req_offset       <= {`OFFSET_WIDTH{1'b0}};

            cacop_en_r       <= 1'b0;
            cacop_code_r     <= 5'b0;
            cacop_way_r      <= {WAY_IDX_W{1'b0}};
            cacop_index_r    <= {`INDEX_WIDTH{1'b0}};
        end
        else if (accept_new_req) begin
            req_index        <= cpu_index;
            req_offset       <= cpu_offset;
            cacop_en_r       <= cacop_en;
            cacop_code_r     <= cacop_code;
            cacop_way_r      <= cacop_way;
            cacop_index_r    <= cacop_index;
        end
        else if (main_refill && cacop_en_r) begin
            cacop_en_r <= 1'b0;
        end
    end

    // Refill Buffer — LOOKUP miss 拍一次性锁存，整个 REFILL 期间不变
    always @(posedge clk) begin
        if (main_lookup && !cache_hit && !lookup_cancel) begin
            refill_index        <= req_index;
            refill_tag          <= lookup_tag;
            refill_offset       <= req_offset;
            refill_cached       <= lookup_cache;
            refill_replace_way  <= replace_way;
            refill_cnt          <= 2'd0;
            refill_way_hit_r    <= way_hit;
        end
        else if (main_refill && return_valid) begin
            refill_cnt <= refill_cnt + 2'd1;
            if (refill_cached)
                refill_line[refill_cnt] <= return_data;
        end
    end

    // ============================================================
    // 数据处理
    // ============================================================
    // lookup返回数据
    wire [31:0] lookup_rdata = bank_rdata[hit_way_idx][req_offset[3:2]];

    // 输出 FIFO
    reg  [31:0] cpu_fifo_mem [0:3];
    reg  [ 1:0] cpu_fifo_wptr;
    reg  [ 1:0] cpu_fifo_rptr;
    reg  [ 2:0] cpu_fifo_cnt;

    wire cpu_fifo_empty = (cpu_fifo_cnt == 3'd0);
    wire cpu_fifo_we    = (lookup_read_hit_done || refill_read_miss_done) && !(cpu_accept && cpu_fifo_empty);
    wire cpu_fifo_re    = cpu_accept && !cpu_fifo_empty;
    
    wire lookup_read_hit_done  = main_lookup && cache_hit;
    wire refill_read_miss_done = main_refill && return_valid && (refill_cnt == refill_offset[3:2] || !refill_cached);
    
    wire [31:0] live_rdata = lookup_read_hit_done  ? lookup_rdata :
                             refill_read_miss_done ? return_data : 32'd0;

    wire accept_ok = (cpu_fifo_cnt < 3'd3);
    
    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy   = accept_new_req && cacop_en;
    assign cpu_data_ok = lookup_read_hit_done || refill_read_miss_done || !cpu_fifo_empty;
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
    // 存储数据管理
    // ============================================================
    // TagV相关逻辑
    wire refill_tagv_we = main_refill && ((return_valid && return_last && refill_cached) || (cacop_en_r && ((cacop_code_r[4:3] == 2'b00) || (cacop_code_r[4:3] == 2'b01) || ((cacop_code_r[4:3] == 2'b10) && (|refill_way_hit_r)))));
    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel = cacop_en_r ? cacop_index_r : refill_index;
    wire [ 3:0]             tagv_wmask_sel = (cacop_en_r && (cacop_code_r[4:3] == 2'b01 || cacop_code_r[4:3] == 2'b10)) ? 4'b0001 : {TAGV_BYTES{1'b1}};
    wire [`TAG_WIDTH:0]     tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} } : {refill_tag, 1'b1};

    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire         tagv_wr = refill_tagv_we && (refill_replace_way == gt);
            wire         tagv_en   = tagv_wr || ram_read_en;
            wire [ 3:0]  tagv_wen  = tagv_wr ? tagv_wmask_sel : 4'b0;
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

    // Data Bank RAM 例化
    genvar gw, gb;
    generate
        for (gw = 0; gw < `WAY_NUM; gw = gw + 1) begin : bank_ram_way
            for (gb = 0; gb < BANK_NUM; gb = gb + 1) begin : bank_ram_col
                wire bank_wr_refill    = main_refill && return_valid && return_last && (refill_replace_way == gw) && refill_cached;
                wire bank_en           = bank_wr_refill || ram_read_en;
                wire [ 3:0] bank_wen   = bank_wr_refill ? 4'b1111 : 4'b0;
                wire [`INDEX_WIDTH-1:0] bank_addr  = bank_wr_refill ? refill_index : ram_raddr;
                wire [31:0] bank_wdata = bank_wr_refill ? ((refill_cnt == gb) ? return_data : refill_line[gb]) : 32'b0;

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
                    .rdata (bank_rdata[gw][gb])
                );
            end
        end
    endgenerate

    // ============================================================
    // AXI 读请求
    // ============================================================
    assign rd_req = (main_lookup && !cache_hit && !cacop_en_r && !lookup_cancel) || main_waitrd;

    assign rd_type = rd_addr_cached ? 3'b100 : 3'b010;
    
    assign rd_addr = rd_addr_cached ? {rd_addr_tag, rd_addr_index, 4'b0000} : {rd_addr_tag, rd_addr_index, rd_addr_offset};

    wire [`TAG_WIDTH-1:0]    rd_addr_tag    = main_lookup ? lookup_tag    : refill_tag;
    wire                     rd_addr_cached = main_lookup ? lookup_cache  : refill_cached;
    wire [`INDEX_WIDTH-1:0]  rd_addr_index  = main_lookup ? req_index  : refill_index;
    wire [`OFFSET_WIDTH-1:0] rd_addr_offset = main_lookup ? req_offset : refill_offset;

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
            if (main_lookup && lookup_cache && !cacop_en_r) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit) begin
                    perf_miss_cnt      <= perf_miss_cnt      + 32'd1;
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
