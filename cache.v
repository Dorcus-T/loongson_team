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
    localparam WAY_IDX_W   = $clog2(`WAY_NUM);   // 路号位宽（2路=1, 4路=2）
    localparam PLRU_W      = `WAY_NUM - 1;       // 每组树状 PLRU 状态位数
    localparam TAGV_BYTES  = (`TAG_WIDTH + 1 + 7) / 8;   // tagv 占用字节数，ceil((TAG_WIDTH+1)/8)

    localparam MAIN_IDLE    = 3'd0;
    localparam MAIN_LOOKUP  = 3'd1;
    localparam MAIN_SWAP    = 3'd2;   // WB/refill 写窗口冲突修复：重读一拍后回 LOOKUP
    localparam MAIN_REPLACE = 3'd3;
    localparam MAIN_REFILL  = 3'd4;
    localparam MAIN_VCFILL  = 3'd5;

    localparam WB_IDLE  = 1'd0;
    localparam WB_WRITE = 1'd1;

    parameter IS_ICACHE = 0;  // I-cache 实例设 1，使能顺序预取
    parameter VC_DEPTH  = 4;  // Victim Cache 条目数（全相联，clean-only）
    parameter VC_EN     = 1;  // VC 使能：D-cache=1，I-cache=0

    localparam VC_IDX_W = (VC_DEPTH > 1) ? $clog2(VC_DEPTH) : 1;

    // ========== RAM 存储阵列 ==========
    reg                 d_ram    [0:`WAY_NUM-1][0:INDEX_DEPTH-1];
    wire [`TAG_WIDTH:0] tagv_rdata [0:`WAY_NUM-1];   // 由 tagv RAM 输出驱动
    reg                 d_rdata    [0:`WAY_NUM-1];
    wire [31:0]         bank_rdata [0:`WAY_NUM-1][0:BANK_NUM-1];  // 由 bank RAM 输出驱动

    // ========== 统一 RAM 读地址 ==========
    wire [`INDEX_WIDTH-1:0] ram_raddr_req;     // 接受新请求时的读地址
    assign ram_raddr_req = (cacop_is_index || cacop_is_hit) ? cacop_index : cpu_index;

    // 预取发起：IDLE 用挂起的 prefetch_addr；LOOKUP 命中收尾且无新请求时跳过 IDLE 直接发起
    wire launch_prefetch_idle;
    wire launch_prefetch_lookup;
    wire launch_prefetch;

    // 预裁决：不依赖 cache_hit 的条件提前 AND 好（全触发器出发），cache_hit 只过一次与门就到 BRAM 使能引脚
    wire lookup_accept_cond;
    wire lookup_prefetch_cond;
    assign lookup_accept_cond  = main_lookup && !hit_write_wb && accept_ok && (cpu_req || cacop_en);
    assign lookup_prefetch_cond = is_ifetch && main_lookup && !prefetch_active && !cpu_req && !cacop_en;

    assign launch_prefetch_idle   = IS_ICACHE && main_idle && prefetch_pending
                                 && !cpu_req && !cacop_en;
    assign launch_prefetch_lookup = lookup_prefetch_cond && cache_hit;
    assign launch_prefetch = launch_prefetch_idle || launch_prefetch_lookup;

    // 下一行地址：LOOKUP 直接发起时组合计算，IDLE 发起时取挂起值
    wire [31:0] next_line_addr;
    wire [31:0] launch_addr;
    assign next_line_addr = {req_tag, req_index, {`OFFSET_WIDTH{1'b0}}} + 32'd16;
    assign launch_addr    = launch_prefetch_lookup ? next_line_addr : prefetch_addr;

    wire ram_read_en;
    assign ram_read_en = accept_new_req || launch_prefetch || main_swap;

    wire [`INDEX_WIDTH-1:0] ram_raddr;
    assign ram_raddr = main_swap        ? req_index
                     : launch_prefetch  ? launch_addr[`OFFSET_WIDTH +: `INDEX_WIDTH]
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
    reg  [WAY_IDX_W-1:0]    cacop_way_r;
    reg  [`INDEX_WIDTH-1:0] cacop_index_r;
    reg                     cacop_is_index_r;
    reg                     cacop_is_hit_r;
    // ========== Miss Buffer ==========
    reg  [WAY_IDX_W-1:0] miss_replace_way;
    reg  [ 1:0] miss_refill_cnt;
    reg         wr_req_accepted;

    // ========== Refill Buffer - 逐拍缓存返回数据，最后一拍统一写 bank ==========
    reg  [31:0] refill_buffer [0:BANK_NUM-1];

    // ========== Prefetch 寄存器 ==========
    reg         prefetch_pending;      // IDLE 时有预取待发起
    reg         prefetch_active;       // 当前正在处理预取请求
    reg  [31:0] prefetch_addr;         // 预取目标物理地址

    // ========== 树状伪 LRU - 每组 (WAY_NUM-1) bit ==========
    // 堆式二叉树：内部节点 1..WAY_NUM-1 存于 plru[s][节点号-1]
    // bit=0 走左子(2j)、bit=1 走右子(2j+1)，victim = 沿 bit 走到的叶
    reg  [PLRU_W-1:0] plru [0:INDEX_DEPTH-1];

    // ========== Write Buffer ==========
    reg                  wb_valid;
    reg  [`WAY_NUM-1:0]   wb_way_hit;
    reg  [`INDEX_WIDTH-1:0] wb_index;
    reg  [ 1:0]          wb_bank;
    reg  [31:0]          wb_wstrb_mask;
    reg  [31:0]          wb_wdata;
    reg                  hit_write_lookup_r;

    // ========== Victim Cache 存储 - 全相联，clean-only（只存干净行） ==========
    reg                  vc_valid [0:VC_DEPTH-1];
    reg  [`TAG_WIDTH+`INDEX_WIDTH-1:0] vc_addr [0:VC_DEPTH-1];   // {tag, index}
    reg  [127:0]         vc_data  [0:VC_DEPTH-1];
    reg  [VC_IDX_W-1:0]  vc_fifo_ptr;                            // 插入路径 FIFO 指针

    // ========== VC 交换缓冲 - 已删除：交换写在 LOOKUP 当拍/写握手拍组合完成，无需锁存 ==========

    // ========== WB 碰撞记录 - accept 拍读被 WB 写抢占的 way ==========
    reg                  collide_valid_r;
    reg  [`WAY_NUM-1:0]   collide_wayhit_r;
    reg                  data_sent_r;           // SWAP 重入 LOOKUP 时抑制重复 data_ok
    reg                  vc_swap_wb_r;          // 本次 REPLACE 是 VC 交换脏写回（只写不读）
    // ========== 状态机节点 ==========
    wire main_idle    = (main_state == MAIN_IDLE);
    wire main_lookup  = (main_state == MAIN_LOOKUP);
    wire main_swap    = (main_state == MAIN_SWAP);
    wire main_replace = (main_state == MAIN_REPLACE);
    wire main_refill  = (main_state == MAIN_REFILL);
    wire main_vcfill  = (main_state == MAIN_VCFILL);
    wire wb_idle      = (wb_state == WB_IDLE);
    wire wb_write     = (wb_state == WB_WRITE);

    // ========== Prefetch 组合逻辑 ==========
    wire is_ifetch;
    assign is_ifetch = IS_ICACHE && !req_op && req_cached && !cacop_en_r;

    wire prefetch_cpu_match;
    assign prefetch_cpu_match = prefetch_active && cpu_req && cpu_cached
                             && (cpu_tag == req_tag) && (cpu_index == req_index);

    // 本拍发现预错（组合）：仅 CPU cacheable 取指能判匹配，uncached 一律视为不匹配
    wire prefetch_mismatch;
    assign prefetch_mismatch = prefetch_active && cpu_req && !prefetch_cpu_match;

    // 预取中止请求（上总线前可用）：CPU 失配 + CACOP 中断（REFILL 段仅 CPU 失配可压写）
    wire prefetch_abort_req;
    assign prefetch_abort_req = prefetch_mismatch || (prefetch_active && cacop_en);

    // 预错压写只看决策拍当拍：未握手就被冲刷的请求不留痕迹
    wire prefetch_wr_kill;
    assign prefetch_wr_kill = prefetch_mismatch;

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

    // ========== 替换 helper - 命中路编码 / 空路优先 / PLRU 牺牲路 ==========
    // 命中路一热 → 二进制路号
    reg  [WAY_IDX_W-1:0] hit_way_idx;
    integer hwi;
    always @(*) begin
        hit_way_idx = {WAY_IDX_W{1'b0}};
        for (hwi = 0; hwi < `WAY_NUM; hwi = hwi + 1)
            if (way_hit[hwi]) hit_way_idx = hwi[WAY_IDX_W-1:0];
    end

    // 空路检测（取最低号无效路）
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

    // 沿树状 PLRU 位从根走到叶，得到牺牲路
    reg  [WAY_IDX_W:0]   plru_node;
    reg  [WAY_IDX_W-1:0] plru_victim;
    integer plv;
    always @(*) begin
        plru_node = 1;                                  // 根节点 = 1
        for (plv = 0; plv < WAY_IDX_W; plv = plv + 1)
            plru_node = (plru_node << 1) + plru[req_index][plru_node-1];
        plru_victim = plru_node - `WAY_NUM;
    end

    // 牺牲路：空路优先，否则 PLRU
    wire [WAY_IDX_W-1:0] victim_way;
    assign victim_way = has_invalid ? invalid_way : plru_victim;

    // ========== VC 查找 - 与 L1 LOOKUP 同拍组合比较（全地址匹配） ==========
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

    // 命中 entry 一热 → 二进制号
    reg  [VC_IDX_W-1:0] vc_hit_idx;
    integer vhi;
    always @(*) begin
        vc_hit_idx = {VC_IDX_W{1'b0}};
        for (vhi = 0; vhi < VC_DEPTH; vhi = vhi + 1)
            if (vc_match[vhi]) vc_hit_idx = vhi[VC_IDX_W-1:0];
    end

    // 行/字选择：一热 OR 归约（同 hit_word 风格），数据路径不经过 vc_hit_idx 优先编码
    reg  [127:0] vc_line;
    reg  [31:0]  vc_word;
    integer vli;
    always @(*) begin
        vc_line = 128'b0;
        vc_word = 32'b0;
        for (vli = 0; vli < VC_DEPTH; vli = vli + 1) begin
            vc_line = vc_line | ({128{vc_match[vli]}} & vc_data[vli]);
            vc_word = vc_word | ({32{vc_match[vli]}} & vc_data[vli][{req_offset[3:2], 5'b0} +: 32]);
        end
    end

    // VC 命中服务：L1 miss 且 VC hit
    wire vc_serve;
    assign vc_serve = main_lookup && !cache_hit && vc_hit;

    // ========== WB 碰撞检测 - victim 行数据/脏位可能陈旧的两个窗口 ==========
    // 目标 way：普通 miss 用 victim_way；CACOP 写回用命中路/指定路
    reg  [WAY_IDX_W-1:0] use_way;
    always @(*) begin
        if (cacop_en_r)
            use_way = (cacop_code_r[4:3] == 2'b10) ? hit_way_idx : cacop_way_r;
        else
            use_way = victim_way;
    end

    // 只有真会用到目标行数据的 miss 才需要修复（uncached / code00 除外）
    wire victim_needed;
    assign victim_needed = cacop_en_r
                         ? (  (cacop_code_r[4:3] == 2'b01)
                           || (cacop_code_r[4:3] == 2'b10 && (|way_hit)) )
                         : req_cached;

    // 窗口一：accept 拍与 WB 写同拍，该 way 的 bank 读被抢占丢弃（跨 set 也算）
    // 窗口二：本 LOOKUP 拍 WB 正写 victim 行本行，读早于写，数据/脏位双陈旧
    wire wb_collide;
    assign wb_collide = victim_needed && tagv_rdata[use_way][0]
                      && (  (collide_valid_r && collide_wayhit_r[use_way])
                         || (wb_write && (wb_index == req_index) && wb_way_hit[use_way]) );

    // 交换写占用 LOOKUP 当拍的 bank 写口：WB 同拍写同一 way（跨 set）则借 SWAP 让位
    wire vc_fill_conflict;
    assign vc_fill_conflict = vc_hit && !victim_dirty && !prefetch_active
                            && wb_write && wb_way_hit[victim_way];

    wire goto_swap;
    assign goto_swap = main_lookup && !cache_hit && (wb_collide || vc_fill_conflict);

    wire lookup_store_hit;
    assign lookup_store_hit = main_lookup && cache_hit && req_op;

    wire is_uncached_store;
    assign is_uncached_store = !req_cached && req_op && !cacop_en_r;

    wire need_bus_rd;
    assign need_bus_rd = (req_cached || !req_op) && !cacop_en_r;

    // ========== 新请求接受标志 ==========
    // 预取中止直通：预错/CACOP 中止的当拍 RAM 写端口空闲，可直接受理新请求，省去 IDLE 中转
    // REFILL 最后拍仅 CPU 失配可压写受理，CACOP 不开此路（写已由 refill 占据）
    wire prefetch_abort_accept;
    assign prefetch_abort_accept = (main_lookup  && !cache_hit && prefetch_abort_req)
                                || (main_replace && prefetch_abort_req)
                                || (main_refill  && return_valid && return_last && prefetch_wr_kill);

    wire accept_new_req;
    assign accept_new_req = (main_idle && !hit_write_wb && accept_ok && (cpu_req || cacop_en))
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
                if (accept_new_req) begin
                    main_next = MAIN_LOOKUP;
                end
                else if (launch_prefetch_idle) begin
                    main_next = MAIN_LOOKUP;   // 发起挂起的预取
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_LOOKUP: begin
                if (!cache_hit && prefetch_abort_req) begin
                    // 预取 miss 且预错/CACOP，尚未上总线 → 放弃，能受理即直通新请求的 LOOKUP
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                else if (goto_swap) begin
                    // victim 行与 WB 写窗口冲突 → 重读修复后回 LOOKUP 重判
                    main_next = MAIN_SWAP;
                end
                else if (vc_fill_lookup) begin
                    main_next = MAIN_VCFILL;    // 干净/空 victim → 进入独立交换状态
                end
                else if (vc_serve) begin
                    if (prefetch_active) begin
                        main_next = MAIN_IDLE;      // 预取 VC 命中：行已缓存，无动作
                    end
                    else begin
                        main_next = MAIN_REPLACE;   // 脏 victim → 写通道踢出脏行
                    end
                end
                // clean miss + bridge 空闲 → 直通 REFILL，省一拍
                else if (rd_req_lookup && rd_rdy) begin
                    main_next = MAIN_REFILL;
                end
                else if (!cache_hit) begin
                    main_next = MAIN_REPLACE;
                end
                else if (accept_new_req || launch_prefetch_lookup) begin
                    main_next = MAIN_LOOKUP;   // 命中：衔接新请求 / 直接发起预取
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_SWAP: begin
                main_next = MAIN_LOOKUP;   // 重读拍结束，回 LOOKUP 重判
            end
            MAIN_VCFILL: begin
                main_next = MAIN_IDLE;     // 交换写完成，回 IDLE
            end
            MAIN_REPLACE: begin
                if (prefetch_abort_req) begin
                    // 预错/CACOP 且读请求尚未发出 → 放弃，能受理即直通新请求的 LOOKUP
                    main_next = accept_new_req ? MAIN_LOOKUP : MAIN_IDLE;
                end
                else if (vc_swap_wb_r) begin
                    // VC 交换 + 脏 victim：只写不读，握手拍完成交换写直接回 IDLE
                    // （bridge 握手拍已整行锁存 wr_data，REPLACE 期间 RAM 写口空闲）
                    main_next = (wr_req && wr_rdy) ? MAIN_IDLE : MAIN_REPLACE;
                end
                else if (need_bus_rd && !miss_needs_write) begin
                    // 只读：干净 miss，发 rd_req 等 rd_rdy
                    main_next = rd_rdy ? MAIN_REFILL : MAIN_REPLACE;
                end
                else if (need_bus_rd && miss_needs_write) begin
                    // 又读又写：脏 miss，先 wr 握手再 rd
                    if (wr_req_accepted) begin
                        main_next = rd_rdy ? MAIN_REFILL : MAIN_REPLACE;
                    end
                    else begin
                        main_next = MAIN_REPLACE;
                    end
                end
                else if (is_uncached_store) begin
                    // 只写：uncached store，先 wr 握手等 wr_done
                    if (wr_req_accepted) begin
                        main_next = wr_done ? MAIN_IDLE : MAIN_REPLACE;
                    end
                    else begin
                        main_next = MAIN_REPLACE;
                    end
                end
                else if (cacop_en_r) begin
                    // CACOP：脏写回先等 wr 握手，否则直通 REFILL 写 tagv
                    if (miss_needs_write && !wr_req_accepted) begin
                        main_next = MAIN_REPLACE;
                    end
                    else begin
                        main_next = MAIN_REFILL;
                    end
                end
                else begin
                    main_next = MAIN_IDLE;
                end
            end
            MAIN_REFILL: begin
                // 预错也不中断 burst：收完所有 beat，最后一拍统一写入（不浪费总线带宽）
                // 压写的最后一拍 RAM 端口空闲，能受理即直通新请求的 LOOKUP，省一拍
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

    // ========== 树状伪 LRU - 命中/填充时把被访问路标为 MRU ==========
    wire                 plru_upd_en;
    wire [WAY_IDX_W-1:0] plru_upd_way;
    assign plru_upd_en  = (main_lookup && cache_hit && !prefetch_active)
                        || refill_d_we
                        || vc_fill;
    assign plru_upd_way = (main_lookup && cache_hit) ? hit_way_idx
                        : vc_fill                    ? vc_fill_way
                                                     : miss_replace_way;

    integer pnode, pparent, pui, prst;
    always @(posedge clk) begin
        if (~resetn) begin
            for (prst = 0; prst < INDEX_DEPTH; prst = prst + 1)
                plru[prst] <= {PLRU_W{1'b0}};
        end
        else if (plru_upd_en) begin
            pnode = `WAY_NUM + plru_upd_way;                 // 被访问叶
            for (pui = 0; pui < WAY_IDX_W; pui = pui + 1) begin
                pparent = pnode >> 1;
                plru[req_index][pparent-1] <= ~pnode[0];     // 指向远离被访问叶一侧
                pnode = pparent;
            end
        end
    end

    // ========== Request Buffer - 接受新请求/发起预取时锁存 ==========
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
        else if (launch_prefetch) begin
            req_op      <= 1'b0;                                           // 读
            req_index   <= launch_addr[`OFFSET_WIDTH +: `INDEX_WIDTH];
            req_tag     <= launch_addr[`INDEX_WIDTH + `OFFSET_WIDTH +: `TAG_WIDTH];
            req_offset  <= 4'b0;
            req_wstrb_mask <= 32'b0;
            req_wdata   <= 32'b0;
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

    // ========== Miss Buffer - 替换路号 / refill 计数 / load 结果 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            miss_replace_way <= {WAY_IDX_W{1'b0}};
            miss_refill_cnt  <= 2'd0;
        end
        else begin
            // replace_way: LOOKUP miss → REPLACE 入口锁存
            if (main_lookup && !cache_hit) begin
                if (cacop_en_r) begin
                    if (cacop_code_r[4:3] == 2'b10)
                        miss_replace_way <= hit_way_idx;   // code 10：命中路
                    else
                        miss_replace_way <= cacop_way_r;   // code 00/01：指定路
                end
                else begin
                    miss_replace_way <= victim_way;        // 空路优先，否则 PLRU
                end
            end
            // refill_cnt: LOOKUP 直通 / REPLACE → REFILL 清零，REFILL 中自增
            if ((main_lookup && rd_req_lookup && rd_rdy)
             || (main_replace && need_bus_rd && rd_rdy)) begin
                miss_refill_cnt <= 2'd0;
            end
            else if (main_refill && return_valid) begin
                miss_refill_cnt <= miss_refill_cnt + 2'd1;
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

    // ========== Prefetch 状态管理 ==========
    // 仅 CPU 取指请求完成时挂预取；排除预取自身（否则命中/refill 会无限链式预取）
    wire set_prefetch_pending;
    assign set_prefetch_pending = is_ifetch && !prefetch_active
        && ((main_lookup && (cache_hit || vc_serve) && main_next == MAIN_IDLE)
         || (main_refill && return_valid && return_last && main_next == MAIN_IDLE));

    always @(posedge clk) begin
        if (~resetn) begin
            prefetch_pending    <= 1'b0;
            prefetch_active     <= 1'b0;
            prefetch_addr       <= 32'b0;
        end
        else begin
            // 设置：I-fetch 完成（hit 或 refill）回 IDLE 时挂预取
            if (set_prefetch_pending) begin
                prefetch_pending <= 1'b1;
                prefetch_addr    <= next_line_addr;
            end
            else if (accept_new_req || launch_prefetch) begin
                prefetch_pending <= 1'b0;
            end

            // prefetch_active：跟踪预取是否正在进行
            if (launch_prefetch) begin
                prefetch_active <= 1'b1;
            end
            else if (accept_new_req || (main_next == MAIN_IDLE)) begin
                prefetch_active <= 1'b0;
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

    // ========== WB 碰撞记录 / data_sent - 时序 ==========
    always @(posedge clk) begin
        if (~resetn) begin
            collide_valid_r  <= 1'b0;
            collide_wayhit_r <= {`WAY_NUM{1'b0}};
            data_sent_r      <= 1'b0;
            vc_swap_wb_r     <= 1'b0;
        end
        else begin
            // accept/预取发起拍若 WB 正在写，记录被抢占的 way
            if (accept_new_req || launch_prefetch) begin
                collide_valid_r  <= wb_write;
                collide_wayhit_r <= wb_way_hit;
            end
            else if (main_swap) begin
                collide_valid_r <= 1'b0;   // 重读后数据已新鲜
            end
            // goto_swap 拍已发 data_ok/write_done，重入 LOOKUP 抑制重复发送
            if (goto_swap) begin
                data_sent_r <= 1'b1;
            end
            else if (!main_swap) begin
                data_sent_r <= 1'b0;
            end
            // VC 交换脏写回模式：LOOKUP 拍锁存，REPLACE 期间保持
            if (main_lookup) begin
                vc_swap_wb_r <= vc_serve && !wb_collide && victim_dirty && !prefetch_active;
            end
        end
    end

    // ========== VC 交换写 - 独立 VCFILL 状态 + 脏路径事件驱动 ==========
    // 干净/空 victim：LOOKUP → VCFILL 一拍完成交换写（BRAM 写使能从触发器出发，切短组合路径）
    // 脏 victim：REPLACE 写握手拍完成（REPLACE 期间无读，写口空闲）
    wire vc_fill_lookup;    // LOOKUP → VCFILL 的转移条件（仅状态机使用）
    wire vc_fill_vcfill;    // VCFILL 拍实际执行交换写
    wire vc_fill_replace;
    wire vc_fill;
    assign vc_fill_lookup  = vc_serve && !victim_dirty && !prefetch_active && !goto_swap;
    assign vc_fill_vcfill  = main_vcfill;
    assign vc_fill_replace = main_replace && vc_swap_wb_r && wr_req && wr_rdy;
    assign vc_fill         = vc_fill_vcfill || vc_fill_replace;

    wire [WAY_IDX_W-1:0] vc_fill_way;
    assign vc_fill_way = vc_fill_replace ? miss_replace_way : victim_way;

    // 换入行数据：store 把 wdata 合并进目标字（组合，两条路径共用）
    wire [31:0] vc_fill_word [0:BANK_NUM-1];
    genvar gf;
    generate
        for (gf = 0; gf < BANK_NUM; gf = gf + 1) begin : vc_fill_word_gen
            assign vc_fill_word[gf] = (req_op && (req_offset[3:2] == gf))
                                    ? ((req_wdata & req_wstrb_mask) | (vc_line[gf*32 +: 32] & ~req_wstrb_mask))
                                    : vc_line[gf*32 +: 32];
        end
    endgenerate

    // ========== VC 存储更新 - CACOP 失效 / 脏 victim store 失效 / 交换回填 / REFILL 插入 ==========
    wire vc_insert;
    assign vc_insert = refill_d_we && VC_EN
                     && tagv_rdata[miss_replace_way][0]     // victim 有效
                     && !d_rdata[miss_replace_way];         // 且干净（clean-only）

    integer vci;
    always @(posedge clk) begin
        if (~resetn) begin
            for (vci = 0; vci < VC_DEPTH; vci = vci + 1) begin
                vc_valid[vci] <= 1'b0;
            end
            vc_fifo_ptr <= {VC_IDX_W{1'b0}};
        end
        else begin
            // CACOP：code10 按全地址精确失效，code00/01 按 index 失效（code11 无操作）
            if (main_lookup && cacop_en_r && cacop_code_r[4:3] != 2'b11 && VC_EN) begin
                for (vci = 0; vci < VC_DEPTH; vci = vci + 1) begin
                    if (vc_valid[vci]
                     && (cacop_is_hit_r ? (vc_addr[vci] == {req_tag, req_index})
                                        : (vc_addr[vci][`INDEX_WIDTH-1:0] == req_index))) begin
                        vc_valid[vci] <= 1'b0;
                    end
                end
            end
            // store miss + VC hit + 脏 victim：走 REPLACE 写回 + 握手拍换入，entry 在此清空
            // VC 交换写：干净有效 victim 回填原 entry；空 victim / 脏路径清 entry
            if (vc_fill) begin
                if (vc_fill_vcfill && tagv_rdata[victim_way][0]) begin
                    vc_addr[vc_hit_idx]  <= {tagv_rdata[victim_way][`TAG_WIDTH:1], req_index};
                    vc_data[vc_hit_idx]  <= {bank_rdata[victim_way][3], bank_rdata[victim_way][2],
                                             bank_rdata[victim_way][1], bank_rdata[victim_way][0]};
                    vc_valid[vc_hit_idx] <= 1'b1;
                end
                else begin
                    vc_valid[vc_hit_idx] <= 1'b0;
                end
            end
            // REFILL 末拍：干净 victim 插入（FIFO 替换）
            if (vc_insert) begin
                vc_valid[vc_fifo_ptr] <= 1'b1;
                vc_addr[vc_fifo_ptr]  <= {tagv_rdata[miss_replace_way][`TAG_WIDTH:1], req_index};
                vc_data[vc_fifo_ptr]  <= replace_line_data;
                vc_fifo_ptr <= vc_fifo_ptr + 1'b1;
            end
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
    // 命中路原始 word：对所有路做一热 OR 归约
    reg  [31:0] hit_word;
    integer hwsi;
    always @(*) begin
        hit_word = 32'b0;
        for (hwsi = 0; hwsi < `WAY_NUM; hwsi = hwsi + 1)
            hit_word = hit_word | ({32{way_hit[hwsi]}} & bank_rdata[hwsi][req_offset[3:2]]);
    end

    wire [31:0] hit_write_data;
    assign hit_write_data = (wb_wdata & wb_wstrb_mask)
                          | (hit_word & ~wb_wstrb_mask);

    wire [31:0] lookup_rdata;
    assign lookup_rdata = hit_write_lookup_r ? hit_write_data : hit_word;

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
    assign refill_tagv_we = (main_refill && return_valid && return_last && req_cached
                          || main_refill && cacop_en_r);

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
                            || (cacop_code10 && (|way_hit)) );

    // 写参数（与路号无关，仅由写类型决定）
    wire [`INDEX_WIDTH-1:0] tagv_waddr_sel;
    wire [ 3:0]            tagv_wmask_sel;
    wire [`TAG_WIDTH:0]     tagv_wdata_sel;
    assign tagv_waddr_sel = (cacop_code00 || cacop_code01) ? cacop_index_r : req_index;
    assign tagv_wmask_sel = (cacop_code01 || cacop_code10) ? 4'b0001     // 仅写 byte0（V 位所在）
                                                           : {TAGV_BYTES{1'b1}};   // 写满 tagv 所占字节
    assign tagv_wdata_sel = cacop_en_r ? { (`TAG_WIDTH+1){1'b0} }   // 全清 / 清 V：写 0
                                       : {req_tag, 1'b1};            // 正常填充：{tag, V=1}

    // 每路一块 TagV RAM。写只发生在 REFILL/VCFILL，读只发生在 accept/SWAP 重读拍，永不同拍
    wire                    tagv_en   [0:`WAY_NUM-1];
    wire [ 3:0]            tagv_wen  [0:`WAY_NUM-1];
    wire [`INDEX_WIDTH-1:0] tagv_addr [0:`WAY_NUM-1];

    genvar gt;
    generate
        for (gt = 0; gt < `WAY_NUM; gt = gt + 1) begin : tagv_ram_gen
            wire tagv_wr = (tagv_do_write && (miss_replace_way == gt))
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
                else if (vc_fill && (vc_fill_way == d_wi)) begin
                    d_ram[d_wi][req_index] <= req_op;   // 换入行：load 干净，store 已合并置脏
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

    // ========== Refill Buffer 累积 - REFILL 每拍存入，最后一拍写 bank ==========
    always @(posedge clk) begin
        if (main_refill && return_valid && req_cached) begin
            refill_buffer[miss_refill_cnt] <= refill_merged_word;
        end
    end

    // ========== Data Bank RAM - 单端口同步 RAM 例化 ==========
    // 每 (路 × bank) 一块独立单端口 RAM。命中写只碰命中路的对应 bank，写优先于读。
    // REFILL 数据逐拍缓存在 refill_buffer，return_last 统一写 4 bank，
    // 确保预取中止不污染 cache。
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
                // REFILL：最后一拍统一写 4 bank
                assign bank_wr_refill[gw][gb] = main_refill && return_valid && return_last
                                              && (miss_replace_way == gw)
                                              && req_cached;
                // VC 交换写：LOOKUP 当拍 / 写握手拍统一写 4 bank（换入 VC 行）
                assign bank_wr_vcf[gw][gb] = vc_fill && (vc_fill_way == gw);
                // Hit Write：按字节掩码写
                assign bank_wr_hit[gw][gb] = wb_write && wb_way_hit[gw] && (wb_bank == gb);

                assign bank_en[gw][gb]    = bank_wr_refill[gw][gb]
                                          || bank_wr_vcf[gw][gb]
                                          || bank_wr_hit[gw][gb]
                                          || ram_read_en;
                assign bank_wen[gw][gb]   = bank_wr_refill[gw][gb] ? 4'b1111
                                          : bank_wr_vcf[gw][gb]    ? 4'b1111
                                          : bank_wr_hit[gw][gb]    ? {wb_wstrb_mask[24], wb_wstrb_mask[16], wb_wstrb_mask[8], wb_wstrb_mask[0]}
                                                                   : 4'b0;
                assign bank_addr[gw][gb]  = bank_wr_refill[gw][gb] ? req_index
                                          : bank_wr_vcf[gw][gb]    ? req_index
                                          : bank_wr_hit[gw][gb]    ? wb_index
                                                                   : ram_raddr;
                // 最后一拍：gb==miss_refill_cnt 的 bank 取 live 数据，其余取 buffer
                assign bank_wdata[gw][gb] = bank_wr_refill[gw][gb]
                                          ? ((miss_refill_cnt == gb) ? refill_merged_word : refill_buffer[gb])
                                          : bank_wr_vcf[gw][gb] ? vc_fill_word[gb]
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
    wire vc_read_done;
    wire write_done;
    wire read_miss_done;
    assign read_hit_done  = main_lookup && cache_hit && !req_op && !prefetch_active;
    // VC 命中 load：LOOKUP 拍即交付（SWAP 重入拍由 data_sent_r 抑制重复交付）
    assign vc_read_done   = vc_serve && !req_op && !prefetch_active && !data_sent_r;
    assign write_done     = main_lookup && req_op && !data_sent_r;
    // 早重启：关键字到达那拍即交付，不必等 return_last；此拍 return_data 就是所需字
    // 预取期间抑制——预取数据不能送给 CPU
    assign read_miss_done = main_refill && return_valid && !req_op && !prefetch_active
                          && (miss_refill_cnt == req_offset[3:2] || !req_cached);

    // 读结果就绪 + 实时数据
    wire read_result_ready;
    wire [31:0] live_rdata;
    assign read_result_ready = read_hit_done || vc_read_done || read_miss_done;
    // read_miss_done 只在关键字拍为真，故 miss 读数据直接取 return_data
    assign live_rdata = read_hit_done  ? lookup_rdata
                      : vc_read_done   ? vc_word
                      : read_miss_done ? return_data
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

    // ========== AXI 读请求 - LOOKUP clean miss 直通 / REPLACE 待命 ==========
    // clean miss 时 LOOKUP 当拍即发 rd_req，bridge 空闲可直通 REFILL 省一拍
    wire rd_req_lookup;
    assign rd_req_lookup = main_lookup && !cache_hit
                         && need_bus_rd && !miss_needs_write
                         && !prefetch_abort_req
                         && !vc_hit && !wb_collide;

    assign rd_req = rd_req_lookup
                  || (main_replace && need_bus_rd
                      && (!miss_needs_write || wr_req_accepted)
                      && !prefetch_abort_req
                      && !vc_swap_wb_r);

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

    // 牺牲行 / CACOP 目标行是否脏（组合逻辑，与 cached_wr 判脏同源）
    wire victim_dirty;
    wire cacop_dirty;
    assign victim_dirty = d_rdata[victim_way] && tagv_rdata[victim_way][0];
    assign cacop_dirty  = (cacop_code_r[4:3] == 2'b10)
                        ? (d_rdata[hit_way_idx] && tagv_rdata[hit_way_idx][0])   // code10：命中路
                        : (d_rdata[cacop_way_r] && tagv_rdata[cacop_way_r][0]);  // code01：指定路

    // 仅“真会写回”才等写通道：普通 cached / CACOP 写回都只在目标行脏时等
    wire miss_needs_write;
    assign miss_needs_write = cacop_en_r ? (cacop_wb && cacop_dirty)
                            : ((req_cached && victim_dirty) || is_uncached_store);

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

`ifndef SYNTHESIS
    // ========== 仿真断言 - 仅仿真观测，不参与逻辑 ==========
    // 不变量 1：同一行不能同时在 L1 和 VC（交换类 bug 的第一症状）
    // 不变量 2：VC 内不能有重复 entry（多热命中）
    always @(posedge clk) begin
        if (resetn && main_lookup && req_cached && !cacop_en_r && !data_sent_r) begin
            if (cache_hit && (|vc_match)) begin
                $display("[%m] ASSERT FAIL: line in both L1 and VC, tag=%h index=%h",
                         req_tag, req_index);
            end
            if ((|vc_match) && ((vc_match & (vc_match - 1)) != {VC_DEPTH{1'b0}})) begin
                $display("[%m] ASSERT WARN: duplicate VC entries, tag=%h index=%h",
                         req_tag, req_index);
            end
        end
    end
`endif
    // ========== 性能计数器 - 总请求 / 可缓存访问 / miss（仅仿真观测，不参与逻辑） ==========
    // u_icache / u_dcache 各自一份。I-cache 的总请求 ≈ 取指总次数
    // L1 命中率        = 1 - perf_miss_cnt / perf_access_cnt
    // VC 后有效命中率  = 1 - perf_real_miss_cnt / perf_access_cnt
    // VC 抢救率        = perf_vc_hit_cnt / perf_miss_cnt（L1 miss 中被 VC 救回的比例）
    reg [31:0] perf_total_req  /*verilator public*/;   // 接受的总请求数（含 uncached / CACOP）
    reg [31:0] perf_access_cnt /*verilator public*/;   // 可缓存查找总次数
    reg [31:0] perf_miss_cnt   /*verilator public*/;   // L1 miss 次数（含 VC hit）
    reg [31:0] perf_real_miss_cnt /*verilator public*/;   // 真 miss：L1 miss 且 VC miss（上总线）
    reg [31:0] perf_prefetch_launch /*verilator public*/;  // 预取总发起次数
    reg [31:0] perf_prefetch_abort  /*verilator public*/;  // 预取中止次数（任一阶段被 kill）
    reg [31:0] perf_prefetch_fill   /*verilator public*/;  // 预取成功落盘次数
    reg [31:0] perf_vc_hit_cnt     /*verilator public*/;   // L1 miss + VC hit 次数
    reg [31:0] perf_vc_insert_cnt  /*verilator public*/;   // REFILL 干净 victim 插入次数
    reg [31:0] perf_vc_fill_cnt    /*verilator public*/;   // VCFILL 交换写拍次数
    always @(posedge clk) begin
        if (~resetn) begin
            perf_total_req        <= 32'd0;
            perf_access_cnt       <= 32'd0;
            perf_miss_cnt         <= 32'd0;
            perf_real_miss_cnt    <= 32'd0;
            perf_prefetch_launch  <= 32'd0;
            perf_prefetch_abort   <= 32'd0;
            perf_prefetch_fill    <= 32'd0;
            perf_vc_hit_cnt       <= 32'd0;
            perf_vc_insert_cnt    <= 32'd0;
            perf_vc_fill_cnt      <= 32'd0;
        end
        else begin
            if (accept_new_req) begin
                perf_total_req <= perf_total_req + 32'd1;
            end
            if (main_lookup && req_cached && !cacop_en_r && !prefetch_active && !data_sent_r) begin
                perf_access_cnt <= perf_access_cnt + 32'd1;
                if (!cache_hit)
                    perf_miss_cnt <= perf_miss_cnt + 32'd1;
                if (!cache_hit && vc_hit)
                    perf_vc_hit_cnt <= perf_vc_hit_cnt + 32'd1;
                if (!cache_hit && !vc_hit)
                    perf_real_miss_cnt <= perf_real_miss_cnt + 32'd1;
            end
            if (vc_insert) begin
                perf_vc_insert_cnt <= perf_vc_insert_cnt + 32'd1;
            end
            if (vc_fill) begin
                perf_vc_fill_cnt <= perf_vc_fill_cnt + 32'd1;
            end
            // 预取计数器：launch / abort / fill
            // abort 仅限 LOOKUP/REPLACE 阶段（未上总线），REFILL 阶段数据一律写入算 fill
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
