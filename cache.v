`include "mycpu.h"

module cache (
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

    // ========== 局部参数 ==========
    localparam INDEX_DEPTH = 1 << `INDEX_WIDTH;
    localparam BANK_NUM    = 4;

    localparam MAIN_IDLE    = 3'd0;
    localparam MAIN_LOOKUP  = 3'd1;
    localparam MAIN_MISS    = 3'd2;
    localparam MAIN_REPLACE = 3'd3;
    localparam MAIN_REFILL  = 3'd4;

    localparam WB_IDLE  = 1'd0;
    localparam WB_WRITE = 1'd1;

    // ========== RAM 存储阵列 ==========
    reg                 d_ram    [0:`WAY_NUM-1][0:INDEX_DEPTH-1];
    wire [`TAG_WIDTH:0] tagv_rdata [0:`WAY_NUM-1];   // 由 tagv RAM 输出驱动
    reg                 d_rdata    [0:`WAY_NUM-1];
    wire [31:0]         bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];  // 由 bank RAM 输出驱动

    // ========== 统一 RAM 读地址 ==========
    wire [`INDEX_WIDTH-1:0] ram_raddr_req;     // 接受新请求时的读地址
    wire [`INDEX_WIDTH-1:0] ram_raddr_miss;    // MISS→REPLACE 时的读地址
    assign ram_raddr_req  = (cacop_is_index || cacop_is_hit) ? cacop_index : cpu_index;
    assign ram_raddr_miss = cacop_is_index_r ? cacop_index_r : req_index;

    wire ram_read_en;
    wire ram_read_miss_en;
    assign ram_read_miss_en = main_miss && wr_rdy && (req_cached || cacop_en_r);
    assign ram_read_en      = accept_new_req || ram_read_miss_en;

    wire [`INDEX_WIDTH-1:0] ram_raddr;
    assign ram_raddr = accept_new_req    ? ram_raddr_req  :
                       ram_read_miss_en  ? ram_raddr_miss :
                                           {`INDEX_WIDTH{1'b0}};

    // ========== CACOP 逻辑 ==========
    wire cacop_is_index;
    wire cacop_is_hit;
    wire [`INDEX_WIDTH-1:0] cacop_index;
    wire [`WAY_NUM-1:0] cacop_way;
    assign cacop_is_index  = cacop_en && (cacop_code[4:3] != 2'b10);
    assign cacop_is_hit    = cacop_en && (cacop_code[4:3] == 2'b10);
    assign cacop_index = cacop_va[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign cacop_way = cacop_va[$clog2(`WAY_NUM)-1:0];
    // ========== 状态寄存器 ==========
    reg  [2:0] main_state;
    reg  [2:0] main_next;
    reg        wb_state;
    reg        wb_next;

    // ========== Request Buffer ==========
    reg                     req_op;
    reg  [`INDEX_WIDTH-1:0]  req_index;
    reg  [`TAG_WIDTH-1:0]   req_tag;
    reg  [`OFFSET_WIDTH-1:0] req_offset;
    reg  [31:0]             req_wstrb_mask;
    reg  [31:0]             req_wdata;
    reg                     req_cached;
    reg                     cacop_en_r;
    reg  [4:0]              cacop_code_r;
    reg                     cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;
    // ========== Miss Buffer ==========
    reg         miss_replace_way;
    reg  [ 1:0] miss_refill_cnt;
    reg  [31:0] miss_load_result;
    reg         wr_req_accepted;

    // ========== LFSR - 伪随机替换 ==========
    reg  [7:0] lfsr;

    // ========== Write Buffer ==========
    reg                  wb_valid;
    reg  [`WAY_NUM-1:0]   wb_way_hit;
    reg  [`INDEX_WIDTH-1:0] wb_index;
    reg  [ 1:0]          wb_bank;
    reg  [31:0]          wb_wstrb_mask;
    reg  [31:0]          wb_wdata;
    reg                  hit_write_lookup_r;
    // ========== 状态机节点 ==========
    wire main_idle    = (main_state == MAIN_IDLE);
    wire main_lookup  = (main_state == MAIN_LOOKUP);
    wire main_miss    = (main_state == MAIN_MISS);
    wire main_replace = (main_state == MAIN_REPLACE);
    wire main_refill  = (main_state == MAIN_REFILL);
    wire wb_idle      = (wb_state == WB_IDLE);
    wire wb_write     = (wb_state == WB_WRITE);

    // ========== Hit Write 冲突检测 ==========
    wire new_is_load;
    assign new_is_load = (cpu_op == 1'b0);

    wire hit_write_lookup;
    assign hit_write_lookup = main_lookup
                            && cache_hit
                            && req_op
                            && cpu_req
                            && new_is_load
                            && (cpu_offset[3:2] == req_offset[3:2])
                            && (cpu_index == req_index);

    wire hit_write_wb;
    assign hit_write_wb = wb_write
                       && cpu_req
                       && new_is_load
                       && (cpu_offset[3:2] == wb_bank);

    // ========== Tag 比较与命中判断 ==========
    wire [`WAY_NUM-1:0] way_hit;
    assign way_hit[0] = tagv_rdata[0][0]
                      && (tagv_rdata[0][`TAG_WIDTH:1] == req_tag)
                      && (req_cached || cacop_en_r);
    assign way_hit[1] = tagv_rdata[1][0]
                      && (tagv_rdata[1][`TAG_WIDTH:1] == req_tag)
                      && (req_cached || cacop_en_r);

    wire cache_hit;
    assign cache_hit = (way_hit[0] || way_hit[1]) && !cacop_en_r;

    wire lookup_store_hit;
    assign lookup_store_hit = main_lookup && cache_hit && req_op;

    wire is_uncached_store;
    assign is_uncached_store = !req_cached && req_op && !cacop_en_r;

    wire need_bus_rd;
    assign need_bus_rd = (req_cached || !req_op) && !cacop_en_r;

    // ========== 新请求接受标志 ==========
    wire accept_new_req;
    assign accept_new_req =  (main_idle   && !hit_write_wb && accept_ok)
                          || (main_lookup && cache_hit && !hit_write_wb && accept_ok);

    // ========== 主状态机 - 时序 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            main_state <= MAIN_IDLE;
        end
        else begin
            main_state <= main_next;
        end
    end

    // ========== Write Buffer 状态机 - 时序 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            wb_state <= WB_IDLE;
        end
        else begin
            wb_state <= wb_next;
        end
    end

    // ========== 主状态机 - 下一状态逻辑 ==========
    always @(*) begin
        case (main_state)
            MAIN_IDLE: begin
                main_next = (cpu_req || cacop_en) && !hit_write_wb ? MAIN_LOOKUP : MAIN_IDLE;
            end
            MAIN_LOOKUP: begin
                main_next = !cache_hit                         ? MAIN_MISS :
                            (cpu_req && !hit_write_wb) ? MAIN_LOOKUP : MAIN_IDLE;
            end
            MAIN_MISS: begin
                main_next = miss_needs_write ? (wr_rdy ? MAIN_REPLACE : MAIN_MISS)
                                             : MAIN_REPLACE;
            end
            MAIN_REPLACE: begin
                if (need_bus_rd) begin
                    if (rd_rdy) begin
                        main_next = MAIN_REFILL;
                    end
                    else begin
                        main_next = MAIN_REPLACE;
                    end
                end
                else if (is_uncached_store) begin
                    main_next = wr_done ? MAIN_IDLE : MAIN_REPLACE;
                end
                else if(cacop_en_r) begin
                    main_next = MAIN_REFILL;
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_REFILL: begin
                main_next = (return_valid && return_last || cacop_en_r) ? MAIN_IDLE : MAIN_REFILL;
            end
            default: begin
                main_next = MAIN_IDLE;
            end
        endcase
    end

    // ========== Write Buffer 状态机 - 下一状态逻辑 ==========
    wire wb_new_store_hit;
    assign wb_new_store_hit = main_lookup && lookup_store_hit;

    always @(*) begin
        case (wb_state)
            WB_IDLE: begin
                wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            end
            WB_WRITE: begin
                wb_next = wb_new_store_hit ? WB_WRITE : WB_IDLE;
            end
            default: begin
                wb_next = WB_IDLE;
            end
        endcase
    end

    // ========== LFSR - 伪随机数步进 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            lfsr <= 8'h5A;
        end
        else if (main_miss && wr_rdy) begin
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
        end
    end

    // ========== Request Buffer - 接受新请求时锁存 ==========
    always @(posedge clk) begin
        if (accept_new_req) begin
            req_op      <= cpu_op;
            req_index   <= cacop_en ? cacop_index : cpu_index;
            req_tag     <= (cacop_en && cacop_is_hit) ? cacop_tag : cpu_tag;
            req_offset  <= cpu_offset;
            req_wstrb_mask <= { {8{cpu_wstrb[3]}}, {8{cpu_wstrb[2]}},
                                {8{cpu_wstrb[1]}}, {8{cpu_wstrb[0]}} };
            req_wdata   <= cpu_wdata;
            req_cached  <= cpu_cached;
            cacop_en_r  <= cacop_en;
            cacop_code_r    <= cacop_code;
            cacop_way_r     <= cacop_way;
            cacop_index_r   <= cacop_index;
            cacop_is_index_r <= cacop_is_index;
            cacop_is_hit_r   <= cacop_is_hit;
        end
        if (main_refill && cacop_en_r) begin
                cacop_en_r <= 1'b0;
            end
    end

    // ========== Miss Buffer - 替换路号 / refill 计数 / load 结果 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            miss_replace_way <= 1'b0;
            miss_refill_cnt  <= 2'd0;
        end
        else begin
            // replace_way: MISS→REPLACE 时锁存
            if (main_miss && wr_rdy) begin
                if(cacop_en_r) begin
                    if(cacop_code_r[4:3]==2'b10) begin
                    miss_replace_way <= way_hit[1] ? 1'b1 : 1'b0;
                    end
                    else begin    
                    miss_replace_way <= cacop_way_r;
                    end
                end
                else begin
                    miss_replace_way <= lfsr[0];
                end
            end
            // refill_cnt: REPLACE→REFILL 清零，REFILL 中自增
            if (main_replace && need_bus_rd && rd_rdy) begin
                miss_refill_cnt <= 2'd0;
            end
            else if (main_refill && return_valid) begin
                miss_refill_cnt <= miss_refill_cnt + 2'd1;
            end
            // load_result: 读 miss / uncached read 保存返回数据
            if (main_refill && return_valid) begin
                if (miss_refill_cnt == req_offset[3:2] || !req_cached) begin
                    miss_load_result <= return_data;
                end
            end
            // 跟踪写请求是否被桥接受
            if (main_replace && wr_req && wr_rdy) begin
                wr_req_accepted <= 1'b1;
            end
            else if (!main_replace) begin
                wr_req_accepted <= 1'b0;
            end
        end
    end

    // ========== Write Buffer - 锁存命中 store ==========
    always @(posedge clk) begin
        if (main_lookup && lookup_store_hit) begin
            wb_valid   <= 1'b1;
            wb_way_hit <= way_hit;
            wb_index   <= req_index;
            wb_bank    <= req_offset[3:2];
            wb_wstrb_mask <= req_wstrb_mask;
            wb_wdata   <= req_wdata;
        end
        else if (wb_write && !wb_new_store_hit) begin
            wb_valid <= 1'b0;
        end
        if (main_lookup && lookup_store_hit) begin
            hit_write_lookup_r <= hit_write_lookup;
        end
        else  begin
            hit_write_lookup_r <= 1'b0;
        end
    end

    // ========== 替换行 128bit 数据 - 组合逻辑 ==========
    wire [127:0] replace_line_data;
    assign replace_line_data = {
        bank_rdata[miss_replace_way][3],
        bank_rdata[miss_replace_way][2],
        bank_rdata[miss_replace_way][1],
        bank_rdata[miss_replace_way][0]
    };

    // ========== Data Select - LOOKUP 时选字 ==========
    wire [31:0] way0_word;
    wire [31:0] way1_word;
    wire [31:0] hit_write_data;
    assign way0_word = bank_rdata[0][req_offset[3:2]];
    assign way1_word = bank_rdata[1][req_offset[3:2]];
    assign hit_write_data = (wb_wdata & wb_wstrb_mask)
                          | ((({32{way_hit[0]}} & way0_word) | ({32{way_hit[1]}} & way1_word)) & ~wb_wstrb_mask);

    wire [31:0] lookup_rdata;
    assign lookup_rdata = hit_write_lookup_r ? hit_write_data : ({32{way_hit[0]}} & way0_word) | ({32{way_hit[1]}} & way1_word);

    // ========== REFILL 合并写数据 - 把 store wdata 覆盖到 ret_data 上 ==========
    wire [3:0] req_wstrb_4b;
    assign req_wstrb_4b = {req_wstrb_mask[31], req_wstrb_mask[23],
                           req_wstrb_mask[15], req_wstrb_mask[ 7]};

    wire is_refill_store_target;
    assign is_refill_store_target = req_op && (miss_refill_cnt == req_offset[3:2]);

    wire [31:0] refill_merged_word;
    assign refill_merged_word = is_refill_store_target
                              ? ((req_wdata & req_wstrb_mask) | (return_data & ~req_wstrb_mask))
                              : return_data;

    // ========== {Tag, V} RAM - 单端口同步 RAM 例化 ==========
    wire refill_tagv_we;
    assign refill_tagv_we = main_refill && return_valid && return_last && req_cached
                          || main_refill && cacop_en_r;

    // CACOP code 分类
    wire cacop_code00 = cacop_en_r && (cacop_code_r[4:3] == 2'b00);  // 全清行
    wire cacop_code01 = cacop_en_r && (cacop_code_r[4:3] == 2'b01);  // 索引清 V
    wire cacop_code10 = cacop_en_r && (cacop_code_r[4:3] == 2'b10);  // 命中清 V

    // 本拍是否真的写 TagV（code 11 不写；code 10 未命中时不写）
    wire tagv_do_write;
    assign tagv_do_write = refill_tagv_we
                         && ( !cacop_en_r
                            || cacop_code00
                            || cacop_code01
                            || (cacop_code10 && (way_hit[0] || way_hit[1])) );

    // 写参数（与路号无关，仅由写类型决定）
    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel;
    wire [`TAG_WIDTH:0]     tagv_wmask_sel;
    wire [`TAG_WIDTH:0]     tagv_wdata_sel;
    assign tagv_waddr_sel = (cacop_code00 || cacop_code01) ? cacop_index_r : req_index;
    assign tagv_wmask_sel = (cacop_code01 || cacop_code10) ? { {`TAG_WIDTH{1'b0}}, 1'b1 }  // 仅写 V 位
                                                           : { (`TAG_WIDTH+1){1'b1} };       // 整字写
    assign tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }   // 全清 / 清 V：写 0
                                       : {req_tag, 1'b1};            // 正常填充：{tag, V=1}

    // 每路一块 TagV RAM。写只发生在 REFILL，读只发生在 IDLE/LOOKUP/MISS，二者永不同拍
    wire                    tagv_en   [0:`WAY_NUM-1];
    wire [`TAG_WIDTH:0]     tagv_wen  [0:`WAY_NUM-1];
    wire [`INDEX_WIDTH-1:0] tagv_addr [0:`WAY_NUM-1];

    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire tagv_wr = tagv_do_write && (miss_replace_way == gt);
            assign tagv_en[gt]   = tagv_wr || ram_read_en;
            assign tagv_wen[gt]  = tagv_wr ? tagv_wmask_sel : { (`TAG_WIDTH+1){1'b0} };
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
                .wdata (tagv_wdata_sel),
                .rdata (tagv_rdata[gt])
            );
        end
    endgenerate

    // ========== D RAM - 同步读/写/复位 ==========
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
                if (refill_d_we && (miss_replace_way == d_wi)) begin
                    d_ram[d_wi][req_index] <= req_op;
                end
                else if (wb_write && wb_way_hit[d_wi]) begin
                    d_ram[d_wi][wb_index] <= 1'b1;
                end
                if (ram_read_en) begin
                    d_rdata[d_wi] <= d_ram[d_wi][ram_raddr];
                end
            end
        end
    end

    // ========== Data Bank RAM - 单端口同步 RAM 例化 ==========
    // 每 (路 × bank) 一块独立单端口 RAM。命中写只碰命中路的对应 bank，写优先于读；
    // 被丢弃的那次读恰为新请求用不到的 bank（同 bank 已被 hit_write_wb 挡住），故无害。
    wire                    bank_wr_refill [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire                    bank_wr_hit    [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire                    bank_en        [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [31:0]             bank_wen       [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [`INDEX_WIDTH-1:0] bank_addr      [0:`WAY_NUM-1][0:BANK_NUM-1];
    wire [31:0]             bank_wdata     [0:`WAY_NUM-1][0:BANK_NUM-1];

    genvar gw, gb;
    generate
        for (gw = 0; gw < `WAY_NUM; gw = gw + 1) begin : bank_ram_way
            for (gb = 0; gb < BANK_NUM; gb = gb + 1) begin : bank_ram_col
                // REFILL 逐拍写：写整字
                assign bank_wr_refill[gw][gb] = main_refill && return_valid
                                              && (miss_refill_cnt == gb)
                                              && (miss_replace_way == gw)
                                              && req_cached;
                // Hit Write：按字节掩码写（掩码即等价原读改写）
                assign bank_wr_hit[gw][gb] = wb_write && wb_way_hit[gw] && (wb_bank == gb);

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb]
                                          || bank_wr_hit[gw][gb]
                                          || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 32'hFFFFFFFF
                                          : bank_wr_hit[gw][gb]    ? wb_wstrb_mask
                                                                   : 32'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? req_index
                                          : bank_wr_hit[gw][gb]    ? wb_index
                                                                   : ram_raddr;
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb] ? refill_merged_word
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

    // ========== 输出 FIFO - 缓冲读结果，等 CPU 接受 ==========
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
    wire write_done;
    wire read_miss_done;
    assign read_hit_done  = main_lookup && cache_hit && !req_op;
    assign write_done     = main_lookup && req_op;
    assign read_miss_done = main_refill && return_valid && return_last && !req_op;

    // 读结果就绪 + 实时数据
    wire read_result_ready;
    wire [31:0] live_rdata;
    assign read_result_ready = read_hit_done || read_miss_done;
    // 最后一拍且目标 word 恰好在当前 beat 时，miss_load_result 是 NBA 来不及更新，
    // 直接 bypass return_data。uncached 单拍返回也在此列
    wire miss_data_bypass;
    assign miss_data_bypass = main_refill && return_valid && return_last
                            && (miss_refill_cnt == req_offset[3:2] || !req_cached);
    assign live_rdata = read_hit_done              ? lookup_rdata
                      : (read_miss_done && miss_data_bypass) ? return_data
                      : read_miss_done             ? miss_load_result
                                                   : 32'd0;

    // 写 FIFO：有就绪数据且 CPU 不会从实时路径直接拿走
    wire cpu_takes_live;
    assign cpu_takes_live = cpu_accept && cpu_fifo_empty && read_result_ready;
    assign cpu_fifo_we    = read_result_ready && !cpu_takes_live;
    assign cpu_fifo_re    = cpu_accept && !cpu_fifo_empty;

    // 新请求接受条件
    // 写请求不占 FIFO → 永远接受
    // 读请求需预留 2 个空位（当前请求 + 新请求），cnt=3 只在当前是写时安全
    wire accept_ok;
    assign accept_ok = cpu_op
                     || (cpu_fifo_cnt < 3'd3)
                     || (cpu_fifo_cnt == 3'd3 && req_op);

    // 输出到 CPU
    assign cpu_addr_ok = accept_new_req && !cacop_en;
    assign cacop_rdy    = accept_new_req && cacop_en;
    assign bus_accept   = 1'b1;  // 直通桥，cache 在 REFILL 期间照单全收
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

    // ========== AXI 读请求 - REPLACE 时发出，进 REFILL 自动清零 ==========
    assign rd_req = main_replace && need_bus_rd;

    wire wstrb_hw;
    assign wstrb_hw = (req_wstrb_4b == 4'b0011) || (req_wstrb_4b == 4'b1100);

    wire [2:0] uncached_rd_type;
    assign uncached_rd_type = !req_op             ? 3'b010   // load 默认字
                            : (&req_wstrb_4b)     ? 3'b010   // store 字
                            : wstrb_hw            ? 3'b001   // store 半字
                                                  : 3'b000;  // store 字节

    assign rd_type = req_cached ? 3'b100 : uncached_rd_type;
    assign rd_addr = req_cached
                   ? {req_tag, req_index, 4'b0000}
                   : {req_tag, req_index, req_offset};

    // ========== AXI 写请求 - 写回脏行 / uncached store ==========
    wire cached_wr;
    wire uncached_wr;
    // CACOP 写回类型识别 - 必须由 cacop_en_r 门控，code 10 额外要求命中
    wire cacop_wb_index;       // code 01: 地址直接索引写回无效
    wire cacop_wb_hit;         // code 10: 查询索引写回无效（仅 |way_hit）
    wire cacop_wb;
    assign cacop_wb_index = cacop_en_r && (cacop_code_r[4:3] == 2'b01);
    assign cacop_wb_hit   = cacop_en_r && (cacop_code_r[4:3] == 2'b10) && (|way_hit);
    assign cacop_wb       = cacop_wb_index || cacop_wb_hit;

    // MISS 状态是否需要等写通道就绪：cached（可能有脏行，保守等）| uncached store | cacop 写回
    wire miss_needs_write;
    assign miss_needs_write = req_cached
                            || is_uncached_store
                            || cacop_wb;

    assign cached_wr = main_replace && (req_cached || cacop_wb)
                    && d_rdata[miss_replace_way]
                    && tagv_rdata[miss_replace_way][0];
    assign uncached_wr = main_replace && is_uncached_store;

    assign wr_req = (cached_wr || uncached_wr) && !wr_req_accepted;
    assign wr_type  = (req_cached || cacop_wb) ? 3'b100 : uncached_rd_type;
    // cacop_wb_index (code 01) 用 VA index；cacop_wb_hit (code 10) 用 PA index
    assign wr_addr  = (req_cached || cacop_wb)
                    ? {tagv_rdata[miss_replace_way][`TAG_WIDTH:1],
                       cacop_wb_index ? cacop_index_r : req_index, 4'b0000}
                    : {req_tag, req_index, req_offset};
    assign wr_wstrb = (req_cached || cacop_wb) ? 4'b1111 : req_wstrb_4b;
    assign wr_data  = (req_cached || cacop_wb) ? replace_line_data : {96'd0, req_wdata};

endmodule
