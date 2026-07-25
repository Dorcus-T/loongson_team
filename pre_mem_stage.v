`include "mycpu.h"

module pre_mem_stage (
    // 时钟与复位
    input  wire                     clk,                // 时钟信号
    input  wire                     reset,              // 复位信号（高有效）
    // 来自EX阶段
    input  wire                     ex_to_pre_mem_valid, // EX到PRE_MEM有效
    input  wire [`EX_TO_PRE_MEM_BUS_WD-1:0] ex_to_pre_mem_bus, // 来自EX的总线
    // 输出给MEM阶段
    output wire                     pre_mem_to_mem_valid, // PRE_MEM到MEM有效
    output wire [`PRE_MEM_TO_MEM_BUS_WD-1:0] pre_mem_to_mem_bus, // PRE_MEM到MEM总线
    output wire                     pre_mem_to_mem_upd,  // PRE_MEM→MEM 更新 data_n
    output wire                     pre_mem_ready_go,     // PRE_MEM阶段就绪标志
    // 访问MMU信号
    output wire [31:0]              pre_mem_to_mmu_vaddr, // 虚地址输出
    output wire [35:0]              vtlb_enop,          // {tlbsrch_valid, invtlb_valid, invtlb_op, invtlb_asid, invtlb_vaddr}
    output wire [ 1:0]              ld_and_str,         // 输出操作是load还是store
    input  wire [31:0]              padd,               // MMU物理地址返回
    input  wire [ 5:0]              srch_value,         // {s1_found, index}
    input  wire [ 4:0]              mem_tlb_exc,        // MMU返回tlb异常
    input  wire                     pre_cached,         // MMU返回是否可缓存
    input  wire                     s1_mem_tlb_req,        // MMU 告知需要查 TLB
    input  wire                     s1_utlb_hit,           // μTLB 命中（跳过 tlb_wait）
    output wire                     need_mmu,           // 本指令需要用 MMU
    // 与 DCache 的接口
    output wire                     dcache_cpu_req,     // DCache 请求有效
    output wire                     dcache_cpu_op,      // DCache 操作类型（1=写）
    output wire [`INDEX_WIDTH-1:0]  dcache_cpu_index,   // DCache 组索引
    output wire [ `TAG_WIDTH-1:0]   dcache_cpu_tag,     // DCache 标签
    output wire [`OFFSET_WIDTH-1:0] dcache_cpu_offset,  // DCache 块内偏移
    output wire [ 3:0]              dcache_cpu_wstrb,   // DCache 写字节掩码
    output wire [31:0]              dcache_cpu_wdata,   // DCache 写数据
    input  wire                     dcache_cpu_addr_ok, // DCache 地址就绪
    output wire                     dcache_cpu_cached,  // DCache 访问可缓存
    // cacop相关
    output wire [ 4:0]              cacop_code,         // cache操作类型
    output wire                     cacop_en_final,     // 有效使能（过异常门控）
    output wire [31:0]              cacop_va,           // cache操作虚地址
    output wire [`TAG_WIDTH-1:0]    cacop_tag,          // cache操作tag
    input  wire                     icache_cacop_rdy,   // ICache CACOP 就绪
    input  wire                     dcache_cacop_rdy,   // DCache CACOP 就绪
    // CSR与ERTN冒险（给ID做stall）
    output wire                     pre_mem_csr_we,     // pre_mem阶段确定要写csr
    output wire [13:0]              pre_mem_csr_num,    // pre_mem阶段写csr的号码
    // 前递控制（给ID做load-use / branch stall + 数据前递）
    output wire [ 4:0]              pre_mem_to_id_dest,     // PRE_MEM阶段写回寄存器号
    output wire [31:0]              pre_mem_to_id_result,   // PRE_MEM阶段前递数据
    output wire                     pre_mem_to_id_load_op,  // PRE_MEM阶段是否有load

    // ── linectrl 接口 ──
    input  wire                     ldata,              // 0=用旧寄存器, 1=用新寄存器
    input  wire                     lvalid,             // 本拍可呈现数据
    input  wire                     lpower,             // 本拍有权发请求
    input  wire                     lready,             // 维持就绪
    input  wire                     upd,                // 上级已准备且有权力 → 更新 data_n

    output wire                     pre_mem_valid_o,    // → linectrl valid_i
    output wire                     pre_mem_exc_o,      // → linectrl exc_i
    output wire                     pre_mem_ertn_o      // → linectrl ertn_i
);

    wire pre_mem_valid;                                 // 本拍有效 = (ldata? valid_n : valid_o) & lvalid
    wire can_req_pre;                                   // 本拍可访问mmu
    wire can_req;                                       // 本拍可访存

    // ========== 双寄存器结构 ==========
    reg  [`EX_TO_PRE_MEM_BUS_WD-1:0] data_n;           // 新数据寄存器（upd 时捕获）
    reg                          valid_n;               // 新 valid
    reg  [`EX_TO_PRE_MEM_BUS_WD-1:0] data_o;            // 旧数据寄存器
    reg                          valid_o;               // 旧 valid

    // ========== 内部异常/ertn 信号 ==========
    wire        pre_mem_exc_valid;                       // 后期异常有效
    wire        pre_mem_ertn_flush;                      // ertn 冲刷
    wire [15:0] ex_exc;      // 来自EX的异常字段（16-bit: {3'b0, exc[12:0]}）
    wire [12:0] pre_exc;          // PRE_MEM 级前异常（+ALE，不含TLB）
    wire [15:0] pre_mem_exc;     // PRE_MEM 级后异常（+TLB合并，16-bit）
    wire [ 4:0] valid_mem_tlb_exc;
    wire        pre_mem_rf_valid;     // 重取指标志
    wire        pre_exc_valid;   // PRE_MEM 级前异常有效（内部计算）

    // ========== 控制信号解析 ==========
    wire [31:0] final_csr_wmask;
    wire [31:0] final_csr_wvalue;
    wire tlbsrch_en;                    // 访问tlb进行查找
    wire invtlb_en;                     // 访问tlb进行选中无效
    wire tlbrd_en;                      // WB读tlb并写csr
    wire tlbwr_en;                      // tlbwrWB写tlb
    wire tlbfill_en;                    // tlbfillWB写tlb
    wire ex_load_op;                    // 加载指令标志
    wire res_from_mem;                  // 结果是否来自存储器
    wire gr_we;                         // 通用寄存器写使能
    wire mem_we;                        // 存储器写使能
    wire [4:0] dest;                    // 目标寄存器号
    wire [31:0] rj_value;               // 源操作数1（用于 vtlb_enop ASID）
    wire [31:0] rkd_value;              // 源操作数2（来自寄存器或立即数）
    wire [31:0] pre_mem_pc;                  // 当前指令PC
    wire ertn_flush;                    // 异常返回冲刷信号
    wire [2:0] mem_size;                // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                  // 符号扩展标志
    // ALU结果
    wire [31:0] alu_result;
    // CSR交互信号
    wire        res_from_csr;           // 结果来自csr寄存器堆
    wire [31:0] csr_rvalue;             // csr读数据
    wire        csr_we;                 // csr写使能
    wire [31:0] csr_wmask;              // csr写掩码
    wire [31:0] csr_wvalue;             // csr写数据
    // 计数器数值筛选
    wire        res_from_timer;         // 结果来自计数器
    wire [31:0] timer_finalval;         // 筛选后的计数器读取数据
    // DCache 接口
    wire        is_mem_inst;            // 是访存指令
    reg         req_state;              // dcache 请求状态
    wire        tlb_return;             // TLB 查大表返回数据（已等 1 拍后置 1）
    // cacop 信号
    wire [4:0]  cacop_code_int;         // 来自EX bus的cache操作类型
    wire        cacop_en;               // 来自EX bus的cache操作使能
    reg         icacop_state;           // ICache CACOP 请求状态
    reg         dcacop_state;           // DCache CACOP 请求状态
    wire        cacop_hit_mode;         // cacop 命中模式

    // ── 请求状态组合输出（ldata=1 当拍清零）──
    wire req_already, i_cacop_req_already, d_cacop_req_already;
    assign req_already          = req_state     && !ldata;
    assign i_cacop_req_already  = icacop_state  && !ldata;
    assign d_cacop_req_already  = dcacop_state  && !ldata;
    // result_or_badv
    wire [31:0] result_or_badv;         // 若为TLB相关异常，替换为pc
    // 异常

    `ifdef DIFFTEST_EN
    // difftest 信号
    wire [31:0] dift_csr_rvalue;
    wire        dift_csr_rstat_en;
    wire [ 7:0] dift_inst_st_en;
    wire [ 7:0] dift_inst_ld_en;
    wire        dift_cnt_inst;
    wire [63:0] dift_timer_64;
    wire [31:0] dift_id_inst;
    wire [31:0] dift_vaddr;
    wire [31:0] dift_paddr;
    wire [31:0] dift_st_data;
    assign dift_paddr = padd;
    `else
    // 占位 dummy wire（保持总线位宽不变）
    wire [209:0] _unused_diff_pad;
    `endif

    // ========== 双寄存器逻辑 ==========

    // ── data_n: upd 时从上游捕获 ──
    always @(posedge clk) begin
        if (reset) begin
            data_n  <= `EX_TO_PRE_MEM_BUS_WD'd0;
            valid_n <= 1'b0;
        end
        else if (upd) begin
            data_n  <= ex_to_pre_mem_bus;
            valid_n <= ex_to_pre_mem_valid;
        end
    end

    // ── data_o: ldata=1 且未准备时从 data_n 拷贝 ──
    always @(posedge clk) begin
        if (reset) begin
            data_o  <= `EX_TO_PRE_MEM_BUS_WD'd0;
            valid_o <= 1'b0;
        end
        else begin
            if (ldata)  data_o  <= data_n;
            valid_o <= (ldata ? valid_n : valid_o) & lvalid;
        end
    end

    // ── ldata 选通 ──
    wire [`EX_TO_PRE_MEM_BUS_WD-1:0] current_bus;
    assign current_bus    = ldata ? data_n : data_o;
    assign pre_mem_valid  = (ldata ? valid_n : valid_o) & lvalid;

    // ── ready_go = work_done || !valid || lready ──
    wire work_done;

    // ── → linectrl ──
    assign pre_mem_valid_o = pre_mem_valid;
    assign pre_mem_exc_o   = pre_mem_exc_valid;
    assign pre_mem_ertn_o  = pre_mem_ertn_flush;

    // ── → MEM ──
    assign pre_mem_to_mem_valid = pre_mem_valid;
    assign pre_mem_to_mem_upd   = (pre_mem_ready_go && lpower) || !pre_mem_valid;

    assign can_req_pre = pre_mem_valid && !pre_exc_valid && lpower;
    assign can_req     = pre_mem_valid && !pre_mem_exc_valid && lpower;

    // ========== 解析来自EX阶段的总线（多6bit cacop在MSB） ==========
    assign {
        cacop_code_int,    // 489:485 cache操作类型
        cacop_en,          // 484     cache操作使能
        rj_value,          // 521:490 源操作数1（用于 vtlb_enop ASID）
        rkd_value,         // 490:459 源操作数2（用于 dcache_wdata / vtlb_enop VPPN）
        ex_load_op,        // 458     加载指令标志（用于 ALE 检测 / ld_and_str / pre_mem_to_id_load_op）
        `ifdef DIFFTEST_EN
        dift_csr_rvalue,   // 451:420 csr读数据 for difftest
        dift_csr_rstat_en, // 420     csr estat读使能 for difftest
        dift_inst_st_en,   // 419:412 store使能 for difftest
        dift_inst_ld_en,   // 411:404 load使能 for difftest
        dift_cnt_inst,     // 403     计数器指令 for difftest
        dift_timer_64,     // 402:339 定时器值 for difftest
        dift_id_inst,      // 338:307 指令编码 for difftest
        dift_vaddr,        // 306:275 load/store虚地址 for difftest
        dift_st_data,      // 274:243 store数据 for difftest
        `else
        _unused_diff_pad,  // 占位：保持非difftest字段bit位置不变
        `endif
        tlbsrch_en,        // 244     tlbsrch使能（vtlb_enop + tlb_wait）
        invtlb_en,         // 243     invtlb使能（vtlb_enop）
        tlbrd_en,          // 242     tlbrd使能
        tlbwr_en,          // 241     tlbwf使能
        tlbfill_en,        // 240
        pre_mem_rf_valid,       // 239     重取指标志
        mem_we,            // 238     存储器写使能（is_mem_inst 由 PRE_MEM 计算，不来自 EX）
        timer_finalval,    // 236:205 筛选后的计数器数据
        res_from_timer,    // 204     结果来自计数器
        res_from_csr,      // 203     结果来自csr寄存器堆
        pre_mem_csr_num,   // 202:189 csr号码
        csr_rvalue,        // 188:157 csr读数据
        csr_we,            // 156     csr写使能
        csr_wmask,         // 155:124 csr写掩码（原值）
        csr_wvalue,        // 123:92  csr写数据（原值）
        ertn_flush,        // 91      异常返回冲刷信号
        ex_exc,            // 90:75 EX自身异常（16-bit）
        res_from_mem,      // 74      结果来源
        mem_sign_ext,      // 73      符号扩展标志
        mem_size,          // 72:70   访存大小
        gr_we,             // 69      寄存器写使能
        dest,              // 68:64   目标寄存器号
        alu_result,        // 63:32   ALU计算结果
        pre_mem_pc              // 31:0    PC
    } = current_bus;

    // ========== ALE 检测（PRE_MEM 负责，EX 不检测访存对齐） ==========
    wire ale;
    assign ale = (pre_mem_valid && (ex_load_op || mem_we)) &&
                 ((mem_size[1] && (alu_result[0] != 1'b0)) ||
                  (mem_size[2] && (alu_result[1:0] != 2'b00)));
    assign pre_exc = {ex_exc[12:1], ale};

    // ========== 输出到MEM阶段的总线 ==========
    assign pre_mem_to_mem_bus = {
        `ifdef DIFFTEST_EN
        dift_csr_rvalue,   // 452:421 csr读数据 for difftest
        dift_csr_rstat_en, // 420     csr estat读使能 for difftest
        dift_inst_st_en,   // 419:412 store使能 for difftest
        dift_inst_ld_en,   // 411:404 load使能 for difftest
        dift_cnt_inst,     // 403     计数器指令 for difftest
        dift_timer_64,     // 402:339 定时器值 for difftest
        dift_id_inst,      // 338:307 指令编码 for difftest
        dift_vaddr,        // 338:307 load/store虚地址 for difftest
        dift_paddr,        // 306:275 load/store物理地址 for difftest（= padd）
        dift_st_data,      // 274:243 store数据 for difftest
        `else
        242'd0,            // 占位：保持非difftest字段bit位置不变
        `endif
        tlbrd_en,          // 242     tlbrd使能
        tlbwr_en,          // 241     tlbwf使能
        tlbfill_en,        // 240
        pre_mem_rf_valid,       // 239     重取指标志
        is_mem_inst,       // 238     是访存指令
        mem_we,            // 237     存储器写使能
        timer_finalval,    // 236:205 筛选后的计数器数据
        res_from_timer,    // 204     结果来自计数器
        res_from_csr,      // 203     结果来自csr寄存器堆
        pre_mem_csr_num,   // 202:189 csr号码
        csr_rvalue,        // 188:157 csr读数据
        csr_we,            // 156     csr写使能
        final_csr_wmask,   // 155:124 csr写掩码（最终值，可能被 tlbsrch 改写）
        final_csr_wvalue,  // 123:92  csr写数据（最终值，可能被 tlbsrch 改写）
        ertn_flush,        // 91      异常返回冲刷信号
        pre_mem_exc,       // 90:75   异常类型（已合并TLB）
        res_from_mem,      // 74      结果来源
        mem_sign_ext,      // 73      符号扩展标志
        mem_size,          // 72:70   访存大小
        gr_we,             // 69      寄存器写使能
        dest,              // 68:64   目标寄存器号
        result_or_badv,    // 63:32   ALU计算结果（TLB异常时用PC替换）
        pre_mem_pc              // 31:0    PC
    };

    // ========== 流水线控制 ==========
    assign is_mem_inst = (mem_we || res_from_mem);
    // TLB 握手控制
    assign need_mmu = (mem_we || res_from_mem || cacop_en && (cacop_code_int[4:3] == 2'b10)) && can_req_pre;
    wire need_tlb_lookup = s1_mem_tlb_req || tlbsrch_en && can_req_pre;
    wire tlb_ready       = !need_tlb_lookup || tlb_return || s1_utlb_hit;
    // ========== ready_go = work_done || !valid || lready ==========
    wire is_mem_tlb = mem_we || res_from_mem || tlbsrch_en;
    wire is_cacop_i = cacop_en && (cacop_code_int[2:0] == 3'd0);
    wire is_cacop_d = cacop_en && (cacop_code_int[2:0] == 3'd1);
    wire cache_sent = (dcache_cpu_req && dcache_cpu_addr_ok) || req_already;

    wire mem_done  = tlb_ready && (cache_sent || tlbsrch_en);
    wire caci_done = icache_cacop_rdy || i_cacop_req_already;
    wire cadc_done = dcache_cacop_rdy || d_cacop_req_already;

    assign work_done       = pre_mem_exc_valid ? 1'b1 :
                             is_cacop_i       ? caci_done :
                             is_cacop_d       ? cadc_done :
                             is_mem_tlb       ? mem_done :
                             1'b1;
    assign pre_mem_ready_go = work_done || !pre_mem_valid || lready;

    // ========== DCache 请求控制 ==========
    wire req_set = dcache_cpu_req && dcache_cpu_addr_ok;
    always @(posedge clk) begin
        if (reset)                                           req_state <= 1'b0;
        else if (ldata && !req_set)                          req_state <= 1'b0;
        else if (req_set)                                    req_state <= 1'b1;
    end
    wire icacop_set = cacop_en && (cacop_code_int[2:0] == 3'd0) && icache_cacop_rdy;
    always @(posedge clk) begin
        if (reset)                                           icacop_state <= 1'b0;
        else if (ldata && !icacop_set)                       icacop_state <= 1'b0;
        else if (icacop_set)                                 icacop_state <= 1'b1;
    end
    wire dcacop_set = cacop_en && (cacop_code_int[2:0] == 3'd1) && dcache_cacop_rdy;
    always @(posedge clk) begin
        if (reset)                                           dcacop_state <= 1'b0;
        else if (ldata && !dcacop_set)                       dcacop_state <= 1'b0;
        else if (dcacop_set)                                 dcacop_state <= 1'b1;
    end

    // ========== TLB 握手控制（TLB 输出寄存器多 1 拍延迟） ==========
    assign tlb_return = !ldata;

    // ========== csr写文件写回控制 ==========
    assign pre_mem_csr_we = csr_we && pre_mem_valid;

    // ========== 访问MMU信号逻辑 ==========
    assign pre_mem_to_mmu_vaddr = alu_result;
    assign vtlb_enop = {
        tlbsrch_en && can_req_pre,
        invtlb_en && can_req_pre,
        dest,
        rj_value[9:0],
        rkd_value[31:13]
    };
    assign final_csr_wmask  = tlbsrch_en && srch_value[5] ? 32'h8000001f : csr_wmask;
    assign final_csr_wvalue = tlbsrch_en && srch_value[5] ? {27'b0,srch_value[4:0]} : csr_wvalue;
    assign ld_and_str       = {ex_load_op || (cacop_en && cacop_code_int[4:3] == 2'b10), mem_we} & {2{pre_mem_valid}};

    // ========== cacop相关信号 ==========
    assign cacop_code     = cacop_code_int;
    assign cacop_va       = alu_result;
    assign cacop_tag      = padd[`OFFSET_WIDTH + `INDEX_WIDTH +: `TAG_WIDTH];
    assign cacop_hit_mode = cacop_en && (cacop_code_int[4:3] == 2'b10);
    assign cacop_en_final = cacop_en && can_req
                          && !(cacop_hit_mode && !tlb_ready)
                          && !i_cacop_req_already && !d_cacop_req_already;

    // ========== DCache 输出信号 ==========
    assign dcache_cpu_req   = can_req && !req_already && (mem_we || res_from_mem) && tlb_ready;
    assign dcache_cpu_op    = mem_we;
    assign dcache_cpu_index = alu_result[`OFFSET_WIDTH +: `INDEX_WIDTH];
    assign dcache_cpu_tag   = padd[`OFFSET_WIDTH + `INDEX_WIDTH +: `TAG_WIDTH];
    assign dcache_cpu_offset= alu_result[0 +: `OFFSET_WIDTH];
    assign dcache_cpu_wstrb  = mem_size[0] ? (4'b0001 << alu_result[1:0]) :          // 字节访问
                               mem_size[1] ? (alu_result[1] ? 4'b1100 : 4'b0011) :   // 半字访问
                               4'b1111;                                              // 字访问
    assign dcache_cpu_wdata  = mem_size[0] ? {4{rkd_value[7:0]}} :                   // 字节：4份
                               mem_size[1] ? {2{rkd_value[15:0]}} :                  // 半字：2份
                               rkd_value;                                            // 字：原值
    assign dcache_cpu_cached = pre_cached;                                           // 来自 MMU 的缓存判断

    // ========== 前递输出（给ID做stall检测 + 数据前递） ==========
    assign pre_mem_to_id_dest    = dest & {5{pre_mem_valid}} & {5{gr_we}};
    assign pre_mem_to_id_result  = res_from_csr ? csr_rvalue : 
                                   res_from_timer ? timer_finalval :
                                   alu_result;
    assign pre_mem_to_id_load_op = ex_load_op & pre_mem_valid;

    // ========== 检测异常与ertn（EX自身异常 + EX自身异常有效） ==========
    assign pre_exc_valid          = (|pre_exc || pre_mem_rf_valid) && pre_mem_valid;

    // ========== 检测异常与ertn（合并EX异常 + TLB异常） ==========
    assign valid_mem_tlb_exc     = mem_tlb_exc & {5{!(|pre_exc) && pre_mem_valid && ld_and_str != 2'b0 && tlb_ready}};
    assign pre_mem_exc           = {pre_exc[12:11], pre_exc[10] || valid_mem_tlb_exc[4], pre_exc[9], pre_exc[8] || valid_mem_tlb_exc[3], pre_exc[7:0], valid_mem_tlb_exc[2:0]};
    assign pre_mem_exc_valid  = (|pre_mem_exc || pre_mem_rf_valid) && pre_mem_valid;
    assign pre_mem_ertn_flush = ertn_flush && pre_mem_valid;

    // ========== result_or_badv（TLB异常时用PC替换地址） ==========
    assign result_or_badv = (!pre_exc[11] && |pre_exc[10:8]) ? pre_mem_pc : alu_result;

endmodule