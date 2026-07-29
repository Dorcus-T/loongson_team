`include "mycpu.h"

module core_top (
    // 系统时钟和复位
    input  wire         aclk,                      // 系统时钟
    input  wire         aresetn,                   // 低电平有效复位信号
    input  wire [ 7:0]  intrpt,                    // 外部中断输入（8个中断线）
    // AXI3 Master 读地址通道
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
    // AXI3 Master 读数据通道
    input  wire [ 3:0]  rid,
    input  wire [31:0]  rdata,
    input  wire [ 1:0]  rresp,
    input  wire         rlast,
    input  wire         rvalid,
    output wire         rready,
    // AXI3 Master 写地址通道
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
    // AXI3 Master 写数据通道
    output wire [ 3:0]  wid,
    output wire [31:0]  wdata,
    output wire [ 3:0]  wstrb,
    output wire         wlast,
    output wire         wvalid,
    input  wire         wready,
    // AXI3 Master 写响应通道
    input  wire [ 3:0]  bid,
    input  wire [ 1:0]  bresp,
    input  wire         bvalid,
    output wire         bready,
    // debug
    input  wire         break_point,               // 无需实现功能，仅提供接口即可，输入1'b0
    input  wire         infor_flag,                // 无需实现功能，仅提供接口即可，输入1'b0
    input  wire [ 4:0]  reg_num,                   // 无需实现功能，仅提供接口即可，输入5'b0
    output wire         ws_valid,                  // 无需实现功能，仅提供接口即可
    output wire [31:0]  rf_rdata,                  // 无需实现功能，仅提供接口即可
    // 调试接口（波形追踪）
    output wire [31:0]  debug0_wb_pc,              // WB阶段PC值
    output wire [ 3:0]  debug0_wb_rf_wen,          // 寄存器写使能（调试用）
    output wire [ 4:0]  debug0_wb_rf_wnum,         // 写回的寄存器号
    output wire [31:0]  debug0_wb_rf_wdata,        // 写回的数据
    output wire [31:0]  debug0_wb_inst,            // WB阶段指令
    // 性能计数器
    output wire [31:0]  debug0_pred_cnt,           // 分支预测次数
    output wire [31:0]  debug0_mispred_cnt,        // 分支预测错误次数
    // 异常调试接口
    output wire         debug_exc_not_rf,          // 异常提交标志
    output wire [ 5:0]  debug_ecode,               // 异常类型码
    output wire [31:0]  debug_exc_back_pc,          // 异常返回地址（异常指令PC）
    // IF 级调试接口
    output wire [31:0]  debug_pre_if_pc,            // pre-IF 级 PC
    output wire [31:0]  debug_if_pc,                // IF 级 PC
    output wire [31:0]  debug_if_inst,              // IF 级指令
    output wire         debug_s0_cancel,             // ICache mmu_cancel
    output wire         debug_icache_addr_ok,        // ICache addr_ok
    output wire [ 2:0]  debug_inst_dirty,            // IF inst_dirty
    // ICache 调试接口
    output wire [ 3:0]  debug_icache_state,           // ICache 主状态机
    output wire         debug_icache_rd_req            // ICache AXI 读请求
);

    // ========== 复位信号处理（将低有效转换为高有效） ==========
    reg  reset;
    wire clk = aclk;
    always @(posedge clk) reset <= ~aresetn;

    // ========== 流水线控制信号（linectrl 集中控制） ==========
    wire [6:0] ldata;                                 // linectrl → 各级
    wire [6:0] lvalid;                                // linectrl → 各级
    wire [6:0] lpower;                                // linectrl → 各级
    wire [6:0] lready;                                // linectrl → 各级
    wire [6:0] valid_i;                               // 各级 → linectrl valid
    wire [6:0] readygo_i;                             // 各级 → linectrl ready_go
    wire [6:0] exc_i;                                 // 各级 → linectrl exc
    wire [6:0] ertn_i;                                // 各级 → linectrl ertn
    wire [6:0] mispred_i;                             // 各级 → linectrl mispred
    wire       bp_valid;                              // linectrl → EX
    wire       s0_flush;                              // linectrl → MMU/IF

    // 悬空位 tie-off（linectrl 输入中 wb 不接入 exc/ertn，仅 EX 级有效 mispred）
    assign mispred_i[6:4] = 3'b0;
    assign mispred_i[2:0] = 3'b0;
    assign exc_i[6]       = 1'b0;
    assign ertn_i[6]      = 1'b0;

    // 各级间 upd（上级 ready && lpower → 更新下级 data_n）
    wire pre_if_to_if_upd;                            // pre_if → IF
    wire if_to_id_upd;                                // IF → ID
    wire id_to_ex_upd;                                // ID → EX
    wire ex_to_pre_mem_upd;                           // EX → PRE_MEM
    wire pre_mem_to_mem_upd;                          // PRE_MEM → MEM
    wire mem_to_wb_upd;                               // MEM → WB

    // 各级 valid（旧接口兼容）
    wire if_to_id_valid;
    wire id_to_ex_valid;
    wire ex_to_pre_mem_valid;
    wire pre_mem_to_mem_valid;
    wire mem_to_wb_valid;

    // ========== 流水线总线（各级之间的数据传递） ==========
    wire [`IF_TO_ID_BUS_WD-1:0]     if_to_id_bus;       // IF -> ID 总线
    wire [`ID_TO_EX_BUS_WD-1:0]     id_to_ex_bus;       // ID -> EX 总线
    wire [`EX_TO_PRE_MEM_BUS_WD-1:0] ex_to_pre_mem_bus; // EX -> PRE_MEM 总线
    wire [`PRE_MEM_TO_MEM_BUS_WD-1:0] pre_mem_to_mem_bus; // PRE_MEM -> MEM 总线
    wire [`MEM_TO_WB_BUS_WD-1:0]    mem_to_wb_bus;      // MEM -> WB 总线
    wire [`WB_TO_RF_BUS_WD-1:0]  wb_to_rf_bus;   // WB -> 寄存器文件
    wire [`WB_TO_CSR_BUS_WD-1:0] wb_to_csr_bus;  // WB -> CSR总线

    // ================================================================
    // 分支预测器连线
    // ================================================================
    wire [`MISPRED_BUS_WD-1:0] mispred_bus;     // 误预测纠正总线（仅 EX → IF，33 bit）

    wire        bp_btb_hit;
    wire [29:0] bp_btb_target;
    wire [ 1:0] bp_btb_counter;
    wire        ex_pred_event;       // EX 阶段预测事件
    wire        ex_mispred_event;    // EX 阶段预测错误事件
    wire [ 4:0] bp_btb_index;
    wire        bp_ras_hit;
    wire [29:0] bp_ras_target;
    wire [ 3:0] bp_ras_index;

    wire [`BP_BUS_WD-1:0] bp_bus;
    wire                  bp_update_en;
    wire                  ex_mispredict;
    wire [31:0] ex_corr_target;
    wire [31:0] if_pre_if_pc_next;              // IF 级 pre_if_pc_next 给 branch_predict 做 lookup_pc_i

    assign mispred_bus = {ex_mispredict, ex_corr_target};

    // ========== 数据前递信号（解决RAW数据冒险） ==========
    wire [ 4:0] ex_to_id_dest;            // EX阶段写回的寄存器号
    wire [ 4:0] mem_to_id_dest;           // MEM阶段写回的寄存器号
    wire [ 4:0] wb_to_id_dest;            // WB阶段写回的寄存器号

    wire [31:0] ex_to_id_result;         // EX阶段计算结果
    wire [31:0] mem_to_id_result;        // MEM阶段计算结果
    wire [31:0] wb_to_id_result;         // WB阶段计算结果
    wire        ex_to_id_load_op;        // EX阶段是否为加载指令（用于load-use检测）
    wire        calc_not_ready;          // EX → ID mul/div 结果未就绪
    wire        mem_to_id_data_ok;       // MEM前递给id的数据是否准备好

    // ========== 异常信号与ertn（各阶段直连 ID 做 csr_stall） ==========
    wire ex_ertn_flush;
    wire mem_ertn_flush;
    wire pre_mem_ertn_flush;
    wire wb_ertn_flush;
    wire ex_exc_valid;
    wire pre_mem_exc_valid;
    wire mem_exc_valid;

    // ========== pre_mem 前递信号 ==========
    wire [ 4:0] pre_mem_to_id_dest;
    wire [31:0] pre_mem_to_id_result;
    wire        pre_mem_to_id_load_op;
    wire        pre_mem_csr_we;
    wire [13:0] pre_mem_csr_num;

    // ========== 重取指信号 ==========
    wire exc_not_rf;         // wb发if，csr除中断外被rf覆盖异常信号
    wire rf_valid;           // rf信号
    wire [31:0] wb_pc_back;  // 发if重取指pc

    // ========== csr有关信号 ==========
    wire [31:0] exc_entry;          // 异常入口地址
    wire [31:0] exc_back_pc;        // 异常返回地址
    wire [31:0] csr_rvalue;         // CSR读数据
    wire [13:0] csr_id_num;         // CSR读号码
    wire        has_int;            // 中断有效标志
    wire [13:0] ex_csr_num;         // ex阶段写csr寄存器号
    wire        ex_csr_we;          // ex阶段写csr使能
    wire [13:0] mem_csr_num;        // mem阶段写csr寄存器号
    wire        mem_csr_we;         // mem阶段写csr使能
    wire [13:0] wb_csr_num;         // wb阶段写csr寄存器号
    wire        wb_csr_we;          // wb阶段写csr使能
    // 特殊csr相关信号
    wire [ 1:0] plv_out;            // 特权等级输出
    wire [ 5:0] ecode_out;          // 异常码输出
    wire [ 1:0] da_pg_out;          // 虚实转换方式输出
    wire [ 1:0] datf_out;           // CRMD.DATF — IF 直接翻译 MAT
    wire [ 1:0] datm_out;           // CRMD.DATM — MEM 直接翻译 MAT
    wire [63:0] dmw_out;            // dmw输出
    wire [ 7:0] hw_inter_num = intrpt;  // 硬件中断号
    wire        ipi_inter    = 1'b0;     // 核间中断（占位）
    wire [`TLBCSR_BUS_WD-1:0] tlbcsr_bus; // tlb相关csr输出

    // ========== 与MMU交互信号 ==========
    wire [31:0] if_to_mmu_vaddr;        // if发mmu虚地址
    wire [31:0] pre_mem_to_mmu_vaddr;   // pre_mem发mmu虚地址
    wire [35:0] vtlb_enop;          // 发mmu tlbsrch，invtlb使能即操作数
    wire [ 1:0] ld_and_str;         // 发mmu load和store信号
    wire [ 2:0] tlbrwf_valid;       // tlbrd tlbwr tlbfill使能
    wire [`TAG_WIDTH-1:0] if_tag;        // MMU → ICache 物理 tag
    wire [`TAG_WIDTH-1:0] ex_tag;        // MMU → DCache 物理 tag
    wire [31:0] pre_mem_paddr;      // MMU → mem_stage 物理地址
    wire        if_s0_need_mmu;      // if_stage → MMU
    wire        pre_mem_s1_need_mmu; // pre_mem → MMU
    wire        mmu_if_cached;      // MMU → ICache
    wire        mmu_ex_cached;      // MMU → DCache
    wire [2:0]  if_tlb_exc;         // MMU → if_stage
    wire [ 4:0] pre_mem_tlb_exc;    // MMU → mem_stage
    wire [ 5:0] srch_value;         // 发pre_mem tlbsrch查询结果
    wire        s0_cancel;           // MMU → ICache
    wire        s1_cancel;           // MMU → DCache
    wire        s0_need_mmu_r;       // MMU → if_stage
    wire        s1_need_mmu_r;       // MMU → mem_stage
    wire [`TLBRD_BUS_WD-1:0] tlbrd_value;
    wire [ 4:0]               tlbfill_rand_index;

    // ========== 计数器数值 ==========
    wire [63:0] timer_value;        // 计数器输出

    // ================================================================
    // ICache — CPU 侧连线
    // ================================================================
    wire        icache_cpu_req;
    wire [ 7:0] icache_cpu_index;
    wire [ 3:0] icache_cpu_offset;
    wire        icache_cpu_addr_ok;
    wire        icache_cpu_data_ok;
    wire [31:0] icache_cpu_rdata;
    wire        icache_cpu_accept;

    // ================================================================
    // DCache — CPU 侧连线
    // ================================================================
    wire        dcache_cpu_req;
    wire        dcache_cpu_op;
    wire [ 7:0] dcache_cpu_index;
    wire [ 3:0] dcache_cpu_offset;
    wire [ 3:0] dcache_cpu_wstrb;
    wire [31:0] dcache_cpu_wdata;
    wire        dcache_cpu_addr_ok;
    wire        dcache_cpu_data_ok;
    wire [31:0] dcache_cpu_rdata;
    wire        dcache_cpu_accept;

    // ================================================================
    // CACOP 连线（EX → ICache / DCache）
    // ================================================================
    wire [4:0]  cacop_code;
    wire        cacop_en_final;
    wire [31:0] cacop_va;
    wire [`WAY_NUM-1:0] cacop_way;
    wire        icache_cacop_en;
    wire        dcache_cacop_en;
    assign icache_cacop_en = cacop_en_final && (cacop_code[2:0] == 3'd0);
    assign dcache_cacop_en = cacop_en_final && (cacop_code[2:0] == 3'd1);
    wire        icache_cacop_rdy;
    wire        dcache_cacop_rdy;

    // ================================================================
    // ICache — AXI 侧连线（ICache 只读，写信号未使用）
    // ================================================================
    wire        icache_rd_req;
    wire [ 2:0] icache_rd_type;
    wire [31:0] icache_rd_addr;
    wire        icache_rd_rdy;
    wire        icache_return_valid;
    wire        icache_return_last;
    wire [31:0] icache_return_data;
    // ================================================================
    // DCache — AXI 侧连线
    // ================================================================
    wire        dcache_rd_req;
    wire [ 2:0] dcache_rd_type;
    wire [31:0] dcache_rd_addr;
    wire        dcache_rd_rdy;
    wire        dcache_return_valid;
    wire        dcache_return_last;
    wire [31:0] dcache_return_data;
    wire        dcache_wr_req;
    wire [ 2:0] dcache_wr_type;
    wire [31:0] dcache_wr_addr;
    wire [ 3:0] dcache_wr_wstrb;
    wire [127:0] dcache_wr_data;
    wire        dcache_wr_rdy;
    wire        dcache_wr_done;

    `ifdef DIFFTEST_EN
    // ================================================================
    // difftest 信号
    // ================================================================
    // from wb_stage
    wire        ws_valid_diff;
    wire        cnt_inst_diff;
    wire [63:0] timer_64_diff;
    wire [ 7:0] inst_ld_en_diff;
    wire [31:0] ld_paddr_diff;
    wire [31:0] ld_vaddr_diff;
    wire [ 7:0] inst_st_en_diff;
    wire [31:0] st_paddr_diff;
    wire [31:0] st_vaddr_diff;
    wire [31:0] st_data_diff;
    wire        csr_rstat_en_diff;
    wire [31:0] csr_data_diff;

    wire        inst_valid_diff = ws_valid_diff;
    reg         cmt_valid;
    reg         cmt_cnt_inst;
    reg  [63:0] cmt_timer_64;
    reg  [ 7:0] cmt_inst_ld_en;
    reg  [31:0] cmt_ld_paddr;
    reg  [31:0] cmt_ld_vaddr;
    reg  [ 7:0] cmt_inst_st_en;
    reg  [31:0] cmt_st_paddr;
    reg  [31:0] cmt_st_vaddr;
    reg  [31:0] cmt_st_data;
    reg         cmt_csr_rstat_en;
    reg  [31:0] cmt_csr_data;

    reg         cmt_wen;
    reg  [ 7:0] cmt_wdest;
    reg  [31:0] cmt_wdata;
    reg  [31:0] cmt_pc;
    reg  [31:0] cmt_inst;

    reg         trap;
    reg  [ 7:0] trap_code;
    reg  [63:0] cycleCnt;
    reg  [63:0] instrCnt;

    reg         cmt_excp_flush;
    reg         cmt_ertn;
    reg  [ 5:0] cmt_csr_ecode;
    reg  [12:0] cmt_intrNo;
    reg         cmt_tlbfill_en;
    reg  [ 4:0] cmt_rand_index;

    // from regfile
    wire [31:0] regs[31:0];

    // from csr
    wire [31:0] csr_crmd_diff_0;
    wire [31:0] csr_prmd_diff_0;
    wire [31:0] csr_ectl_diff_0;
    wire [31:0] csr_estat_diff_0;
    wire [31:0] csr_era_diff_0;
    wire [31:0] csr_badv_diff_0;
    wire [31:0] csr_eentry_diff_0;
    wire [31:0] csr_tlbidx_diff_0;
    wire [31:0] csr_tlbehi_diff_0;
    wire [31:0] csr_tlbelo0_diff_0;
    wire [31:0] csr_tlbelo1_diff_0;
    wire [31:0] csr_asid_diff_0;
    wire [31:0] csr_save0_diff_0;
    wire [31:0] csr_save1_diff_0;
    wire [31:0] csr_save2_diff_0;
    wire [31:0] csr_save3_diff_0;
    wire [31:0] csr_tid_diff_0;
    wire [31:0] csr_tcfg_diff_0;
    wire [31:0] csr_tval_diff_0;
    wire [31:0] csr_ticlr_diff_0;
    wire [31:0] csr_llbctl_diff_0;
    wire [31:0] csr_tlbrentry_diff_0;
    wire [31:0] csr_dmw0_diff_0;
    wire [31:0] csr_dmw1_diff_0;
    wire [31:0] csr_pgdl_diff_0;
    wire [31:0] csr_pgdh_diff_0;

    assign ws_valid = ws_valid_diff;
    assign rf_rdata = regs[reg_num];
    `endif

    // ================================================================
    // 分支预测器 (BTB + BHT + RAS)
    // ================================================================
    branch_predict u_branch_predict (
        .clk         (clk),
        .reset       (reset),
        .lookup_pc_i (if_pre_if_pc_next[31:2]),
        .btb_hit_o   (bp_btb_hit),
        .btb_target_o(bp_btb_target),
        .btb_counter_o(bp_btb_counter),
        .btb_index_o (bp_btb_index),
        .ras_hit_o   (bp_ras_hit),
        .ras_target_o(bp_ras_target),
        .ras_index_o (bp_ras_index),
        .update_en   (bp_update_en),
        .update_bus  (bp_bus)
    );

    // ================================================================
    // 流水线控制器 (linectrl)
    // ================================================================
    linectrl u_linectrl (
        .clk          (clk),
        .reset        (reset),
        .valid_i      (valid_i),
        .readygo_i    (readygo_i),
        .exc_i        (exc_i),
        .ertn_i       (ertn_i),
        .mispred_i    (mispred_i),
        .lvalid       (lvalid),
        .lpower       (lpower),
        .ldata        (ldata),
        .lready       (lready),
        .bp_valid     (bp_valid),
        .s0_flush     (s0_flush)
    );

    // ========== 异常/ertn 直连 ID（csr_stall 使用） ==========
    assign ex_ertn_flush      = ertn_i[3];
    assign pre_mem_ertn_flush = ertn_i[4];
    assign mem_ertn_flush     = ertn_i[5];
    assign ex_exc_valid       = exc_i[3];
    assign pre_mem_exc_valid  = exc_i[4];
    assign mem_exc_valid      = exc_i[5];

    // ================================================================
    // 第一阶段：取指阶段 (IF - Instruction Fetch)
    // ================================================================
    if_stage u_if_stage (
        .clk                (clk),
        .reset              (reset),
        .if_to_id_valid     (if_to_id_valid),
        .if_to_id_bus       (if_to_id_bus),
        .if_to_id_upd       (if_to_id_upd),
        .icache_cpu_req     (icache_cpu_req),
        .icache_cpu_index   (icache_cpu_index),
        .icache_cpu_offset  (icache_cpu_offset),
        .icache_cpu_addr_ok (icache_cpu_addr_ok),
        .icache_cpu_data_ok (icache_cpu_data_ok),
        .icache_cpu_rdata   (icache_cpu_rdata),
        .icache_cpu_accept  (icache_cpu_accept),
        .if_to_mmu_vaddr    (if_to_mmu_vaddr),
        .s0_need_mmu         (if_s0_need_mmu),
        .if_tlb_exc         (if_tlb_exc),
        .s0_need_mmu_r       (s0_need_mmu_r),
        .exc_no_rf          (exc_not_rf),
        .wb_ertn_flush      (wb_ertn_flush),
        .exc_entry          (exc_entry),
        .exc_back_pc        (exc_back_pc),
        .rf_valid           (rf_valid),
        .rf_pc              (wb_pc_back),
        .bp_btb_hit         (bp_btb_hit),
        .bp_btb_target      (bp_btb_target),
        .bp_btb_counter     (bp_btb_counter),
        .bp_btb_index       (bp_btb_index),
        .bp_ras_hit         (bp_ras_hit),
        .bp_ras_target      (bp_ras_target),
        .bp_ras_index       (bp_ras_index),
        .mispred_bus        (mispred_bus),
        .ldata              (ldata[1:0]),
        .lvalid             (lvalid[1:0]),
        .lpower             (lpower[1:0]),
        .lready             (lready[1:0]),
        .if_valid_o         (valid_i[1:0]),
        .if_ready_o         (readygo_i[1:0]),
        .if_exc_o           (exc_i[1:0]),
        .if_ertn_o          (ertn_i[1:0]),
        .s0_flush           (s0_flush),
        .s0_cancel          (s0_cancel),
        .if_pre_if_pc_next  (if_pre_if_pc_next),
        .debug_pre_if_pc    (debug_pre_if_pc),
        .debug_if_pc        (debug_if_pc),
        .debug_if_inst      (debug_if_inst),
        .debug_inst_dirty   (debug_inst_dirty)
    );

    // ================================================================
    // 第二阶段：译码阶段 (ID - Instruction Decode)
    // ================================================================
    id_stage u_id_stage (
        .clk                (clk),
        .reset              (reset),
        .if_to_id_valid     (if_to_id_valid),
        .if_to_id_bus       (if_to_id_bus),
        .id_to_ex_valid     (id_to_ex_valid),
        .id_to_ex_bus       (id_to_ex_bus),
        .id_to_ex_upd       (id_to_ex_upd),
        .id_ready_go        (readygo_i[2]),
        .wb_to_rf_bus       (wb_to_rf_bus),
        .ex_to_id_dest      (ex_to_id_dest),
        .mem_to_id_dest     (mem_to_id_dest),
        .wb_to_id_dest      (wb_to_id_dest),
        .ex_to_id_load_op   (ex_to_id_load_op),
        .ex_to_id_result    (ex_to_id_result),
        .mem_to_id_result   (mem_to_id_result),
        .wb_to_id_result    (wb_to_id_result),
        .mem_to_id_data_ok  (mem_to_id_data_ok),
        .calc_not_ready     (calc_not_ready),
        .ex_csr_we          (ex_csr_we),
        .ex_csr_num         (ex_csr_num),
        .ex_ertn_flush      (ex_ertn_flush),
        .pre_mem_csr_we     (pre_mem_csr_we),
        .pre_mem_csr_num    (pre_mem_csr_num),
        .pre_mem_ertn_flush (pre_mem_ertn_flush),
        .pre_mem_to_id_dest    (pre_mem_to_id_dest),
        .pre_mem_to_id_result  (pre_mem_to_id_result),
        .pre_mem_to_id_load_op (pre_mem_to_id_load_op),
        .mem_csr_we         (mem_csr_we),
        .mem_csr_num        (mem_csr_num),
        .mem_ertn_flush     (mem_ertn_flush),
        .wb_csr_we          (wb_csr_we),
        .wb_csr_num         (wb_csr_num),
        .wb_ertn_flush      (wb_ertn_flush),
        .csr_rvalue         (csr_rvalue),
        .csr_id_num         (csr_id_num),
        .has_int            (has_int),
        .csr_da_pg          (da_pg_out),
        .ldata              (ldata[2]),
        .lvalid             (lvalid[2]),
        .lpower             (lpower[2]),
        .lready             (lready[2]),
        .upd                (if_to_id_upd),
        .id_valid_o         (valid_i[2]),
        .id_exc_o           (exc_i[2]),
        .id_ertn_o          (ertn_i[2])
        `ifdef DIFFTEST_EN
        ,
        .rf_to_diff         (regs)
        `endif
    );

    // ================================================================
    // 第三阶段：执行阶段 (EX - Execute)
    // ================================================================
    exe_stage u_exe_stage (
        .clk                (clk),
        .reset              (reset),
        .id_to_ex_valid     (id_to_ex_valid),
        .id_to_ex_bus       (id_to_ex_bus),
        .ex_to_pre_mem_valid (ex_to_pre_mem_valid),
        .ex_to_pre_mem_bus   (ex_to_pre_mem_bus),
        .ex_to_pre_mem_upd  (ex_to_pre_mem_upd),
        .ex_ready_go        (readygo_i[3]),
        .ex_to_id_dest      (ex_to_id_dest),
        .ex_to_id_result    (ex_to_id_result),
        .ex_to_id_load_op   (ex_to_id_load_op),
        .ex_csr_we          (ex_csr_we),
        .ex_csr_num         (ex_csr_num),
        .timer_value        (timer_value),
        .ex_mispredict      (ex_mispredict),
        .ex_corr_target     (ex_corr_target),
        .calc_not_ready     (calc_not_ready),
        .pred_event         (ex_pred_event),
        .mispred_event      (ex_mispred_event),
        .ldata              (ldata[3]),
        .lvalid             (lvalid[3]),
        .lpower             (lpower[3]),
        .lready             (lready[3]),
        .upd                (id_to_ex_upd),
        .ex_valid_o         (valid_i[3]),
        .ex_exc_o           (exc_i[3]),
        .ex_ertn_o          (ertn_i[3]),
        .ex_mispred_o       (mispred_i[3])
    );

    // ================================================================
    // 第四阶段：访存前置阶段 (PRE_MEM - Pre-Memory Access)
    // ================================================================
    pre_mem_stage u_pre_mem_stage (
        .clk                 (clk),
        .reset               (reset),
        .ex_to_pre_mem_valid (ex_to_pre_mem_valid),
        .ex_to_pre_mem_bus   (ex_to_pre_mem_bus),
        .pre_mem_to_mem_valid (pre_mem_to_mem_valid),
        .pre_mem_to_mem_bus  (pre_mem_to_mem_bus),
        .pre_mem_to_mem_upd  (pre_mem_to_mem_upd),
        .pre_mem_ready_go    (readygo_i[4]),
        .pre_mem_to_mmu_vaddr(pre_mem_to_mmu_vaddr),
        .dcache_cpu_req      (dcache_cpu_req),
        .dcache_cpu_op       (dcache_cpu_op),
        .dcache_cpu_index    (dcache_cpu_index),
        .dcache_cpu_offset   (dcache_cpu_offset),
        .dcache_cpu_wstrb    (dcache_cpu_wstrb),
        .dcache_cpu_wdata    (dcache_cpu_wdata),
        .dcache_cpu_addr_ok  (dcache_cpu_addr_ok),
        .vtlb_enop           (vtlb_enop),
        .ld_and_str          (ld_and_str),
        .srch_value          (srch_value),
        .s1_need_mmu          (pre_mem_s1_need_mmu),
        .cacop_code          (cacop_code),
        .cacop_en_final      (cacop_en_final),
        .cacop_va            (cacop_va),
        .icache_cacop_rdy    (icache_cacop_rdy),
        .dcache_cacop_rdy    (dcache_cacop_rdy),
        .pre_mem_csr_we      (pre_mem_csr_we),
        .pre_mem_csr_num     (pre_mem_csr_num),
        .pre_mem_to_id_dest  (pre_mem_to_id_dest),
        .pre_mem_to_id_result(pre_mem_to_id_result),
        .pre_mem_to_id_load_op(pre_mem_to_id_load_op),
        .ldata               (ldata[4]),
        .lvalid              (lvalid[4]),
        .lpower              (lpower[4]),
        .lready              (lready[4]),
        .upd                 (ex_to_pre_mem_upd),
        .pre_mem_valid_o     (valid_i[4]),
        .pre_mem_exc_o       (exc_i[4]),
        .pre_mem_ertn_o      (ertn_i[4]),
        .bp_update_en        (bp_update_en),
        .bp_bus              (bp_bus),
        .bp_valid            (bp_valid)
    );

    // ================================================================
    // 第五阶段：访存数据阶段 (MEM - Memory Access)
    // ================================================================
    mem_stage u_mem_stage (
        .clk                 (clk),
        .reset               (reset),
        .pre_mem_to_mem_valid(pre_mem_to_mem_valid),
        .pre_mem_to_mem_bus  (pre_mem_to_mem_bus),
        .mem_to_wb_valid     (mem_to_wb_valid),
        .mem_to_wb_bus       (mem_to_wb_bus),
        .mem_to_wb_upd       (mem_to_wb_upd),
        .mem_ready_go        (readygo_i[5]),
        .dcache_cpu_rdata    (dcache_cpu_rdata),
        .dcache_cpu_data_ok  (dcache_cpu_data_ok),
        .mem_to_id_dest      (mem_to_id_dest),
        .mem_to_id_result    (mem_to_id_result),
        .mem_to_id_data_ok   (mem_to_id_data_ok),
        .mem_csr_we          (mem_csr_we),
        .mem_csr_num         (mem_csr_num),
        .dcache_cpu_accept   (dcache_cpu_accept),
        .ex_tlb_exc          (pre_mem_tlb_exc),
        .padd                (pre_mem_paddr),
        .s1_need_mmu_r        (s1_need_mmu_r),
        .ldata               (ldata[5]),
        .lvalid              (lvalid[5]),
        .lpower              (lpower[5]),
        .lready              (lready[5]),
        .upd                 (pre_mem_to_mem_upd),
        .mem_valid_o         (valid_i[5]),
        .mem_exc_o           (exc_i[5]),
        .mem_ertn_o          (ertn_i[5])
    );

    // ================================================================
    // 第六阶段：写回阶段 (WB - Write Back)
    // ================================================================
    wb_stage u_wb_stage (
        .clk               (clk),
        .reset             (reset),
        .mem_to_wb_valid   (mem_to_wb_valid),
        .mem_to_wb_bus     (mem_to_wb_bus),
        .wb_to_rf_bus      (wb_to_rf_bus),
        .debug_wb_pc       (debug0_wb_pc),
        .debug_wb_rf_we    (debug0_wb_rf_wen),
        .debug_wb_rf_wnum  (debug0_wb_rf_wnum),
        .debug_wb_rf_wdata (debug0_wb_rf_wdata),
        .debug_wb_inst     (debug0_wb_inst),
        .wb_to_id_dest     (wb_to_id_dest),
        .wb_to_id_result   (wb_to_id_result),
        .wb_ertn_flush     (wb_ertn_flush),
        .wb_csr_we         (wb_csr_we),
        .wb_csr_num        (wb_csr_num),
        .wb_to_csr_bus     (wb_to_csr_bus),
        .exc_no_rf         (exc_not_rf),
        .rf_valid          (rf_valid),
        .wb_pc_back        (wb_pc_back),
        .tlbrwf_valid      (tlbrwf_valid),
        .ldata              (ldata[6]),
        .lvalid             (lvalid[6]),
        .lpower             (lpower[6]),
        .lready             (lready[6]),
        .upd                (mem_to_wb_upd),
        .wb_valid_o         (valid_i[6]),
        .wb_ready_go        (readygo_i[6])
        `ifdef DIFFTEST_EN
        ,
        .ws_valid_diff      (ws_valid_diff),
        .ws_cnt_inst_diff   (cnt_inst_diff),
        .ws_timer_64_diff   (timer_64_diff),
        .ws_inst_ld_en_diff (inst_ld_en_diff),
        .ws_ld_paddr_diff   (ld_paddr_diff),
        .ws_ld_vaddr_diff   (ld_vaddr_diff),
        .ws_inst_st_en_diff (inst_st_en_diff),
        .ws_st_paddr_diff   (st_paddr_diff),
        .ws_st_vaddr_diff   (st_vaddr_diff),
        .ws_st_data_diff    (st_data_diff),
        .ws_csr_rstat_en_diff (csr_rstat_en_diff),
        .ws_csr_data_diff   (csr_data_diff)
        `endif
    );

    // ================================================================
    // csr寄存器堆
    // ================================================================
    csr_regfile u_csr_regfile (
        .clk           (clk),
        .reset         (reset),
        .exc_entry     (exc_entry),
        .exc_back_pc   (exc_back_pc),
        .csr_id_num    (csr_id_num),
        .csr_rvalue    (csr_rvalue),
        .has_int       (has_int),
        .wb_to_csr_bus (wb_to_csr_bus),
        .coreid_in     (32'd0),
        .hw_inter_num  (hw_inter_num),
        .ipi_inter     (ipi_inter),
        .plv_out       (plv_out),
        .ecode_out     (ecode_out),
        .da_pg_out     (da_pg_out),
        .datf_out      (datf_out),
        .datm_out      (datm_out),
        .dmw_out       (dmw_out),
        .tlbrd_bus     (tlbrd_value),
        .tlbcsr_bus    (tlbcsr_bus)
        `ifdef DIFFTEST_EN
        ,
        .csr_crmd_diff      (csr_crmd_diff_0),
        .csr_prmd_diff      (csr_prmd_diff_0),
        .csr_ectl_diff      (csr_ectl_diff_0),
        .csr_estat_diff     (csr_estat_diff_0),
        .csr_era_diff       (csr_era_diff_0),
        .csr_badv_diff      (csr_badv_diff_0),
        .csr_eentry_diff    (csr_eentry_diff_0),
        .csr_tlbidx_diff    (csr_tlbidx_diff_0),
        .csr_tlbehi_diff    (csr_tlbehi_diff_0),
        .csr_tlbelo0_diff   (csr_tlbelo0_diff_0),
        .csr_tlbelo1_diff   (csr_tlbelo1_diff_0),
        .csr_asid_diff      (csr_asid_diff_0),
        .csr_save0_diff     (csr_save0_diff_0),
        .csr_save1_diff     (csr_save1_diff_0),
        .csr_save2_diff     (csr_save2_diff_0),
        .csr_save3_diff     (csr_save3_diff_0),
        .csr_tid_diff       (csr_tid_diff_0),
        .csr_tcfg_diff      (csr_tcfg_diff_0),
        .csr_tval_diff      (csr_tval_diff_0),
        .csr_ticlr_diff     (csr_ticlr_diff_0),
        .csr_llbctl_diff    (csr_llbctl_diff_0),
        .csr_tlbrentry_diff (csr_tlbrentry_diff_0),
        .csr_dmw0_diff      (csr_dmw0_diff_0),
        .csr_dmw1_diff      (csr_dmw1_diff_0),
        .csr_pgdl_diff      (csr_pgdl_diff_0),
        .csr_pgdh_diff      (csr_pgdh_diff_0)
        `endif
    );

    // ================================================================
    // MMU
    // ================================================================
    mmu u_mmu (
        .clk                (clk),
        .reset              (reset),
        .vaddr_from_if      (if_to_mmu_vaddr),
        .if_tag             (if_tag),
        .if_tlb_exc         (if_tlb_exc),
        .if_cached          (mmu_if_cached),
        .paddr_to_if        (),
        .vaddr_from_ex      (pre_mem_to_mmu_vaddr),
        .vtlb_enop          (vtlb_enop),
        .ld_and_str         (ld_and_str),
        .ex_tag             (ex_tag),
        .ex_tlb_exc         (pre_mem_tlb_exc),
        .ex_cached          (mmu_ex_cached),
        .paddr_to_ex        (pre_mem_paddr),
        .srch_value         (srch_value),
        .tlbrwf_en          (tlbrwf_valid),
        .plv_in             (plv_out),
        .ecode_in           (ecode_out),
        .dapg_in            (da_pg_out),
        .datf_in            (datf_out),
        .datm_in            (datm_out),
        .dmw                (dmw_out),
        .tlbcsr             (tlbcsr_bus),
        .tlbrd_value        (tlbrd_value),
        .tlbfill_rand_index (tlbfill_rand_index),
        .s0_cancel          (s0_cancel),
        .s1_cancel          (s1_cancel),
        .s0_need_mmu_r      (s0_need_mmu_r),
        .s1_need_mmu_r      (s1_need_mmu_r),
        .s0_need_mmu        (if_s0_need_mmu),
        .s1_need_mmu        (pre_mem_s1_need_mmu)
    );

    // ================================================================
    // 64位周期计数器
    // ================================================================
    timer_64bit u_timer_64bit (
        .clk         (clk),
        .reset       (reset),
        .timer_value (timer_value)
    );

    // ================================================================
    // 分支预测性能计数器
    // ================================================================
    reg [31:0] pred_cnt;
    reg [31:0] mispred_cnt;

    always @(posedge clk) begin
        if (reset) begin
            pred_cnt   <= 32'd0;
            mispred_cnt <= 32'd0;
        end
        else begin
            if (ex_pred_event)
                pred_cnt <= pred_cnt + 32'd1;
            if (ex_mispred_event)
                mispred_cnt <= mispred_cnt + 32'd1;
        end
    end

    assign debug0_pred_cnt   = pred_cnt;
    assign debug0_mispred_cnt = mispred_cnt;
    assign debug_exc_not_rf    = exc_not_rf;
    assign debug_ecode         = ecode_out;
    assign debug_exc_back_pc   = exc_back_pc;
    assign debug_s0_cancel       = s0_cancel;
    assign debug_icache_addr_ok  = icache_cpu_addr_ok;

    // ================================================================
    // ICache
    // ================================================================
    icache u_icache (
        .clk           (clk),
        .resetn        (~reset),
        // CPU 接口
        .cpu_req       (icache_cpu_req),
        .cpu_index     (icache_cpu_index),
        .mmu_tag       (if_tag),
        .cpu_offset    (icache_cpu_offset),
        .mmu_cache     (mmu_if_cached),
        .mmu_cancel    (s0_cancel),
        .mmu_cacop_cancel (s1_cancel),
        .cpu_addr_ok   (icache_cpu_addr_ok),
        .cpu_data_ok   (icache_cpu_data_ok),
        .cpu_rdata     (icache_cpu_rdata),
        .cpu_accept    (icache_cpu_accept),
        // CACOP
        .cacop_en      (icache_cacop_en),
        .cacop_code    (cacop_code),
        .cacop_va      (cacop_va),
        .mmu_cacop_tag (ex_tag),
        .cacop_rdy     (icache_cacop_rdy),
        // AXI 接口
        .rd_req        (icache_rd_req),
        .rd_type       (icache_rd_type),
        .rd_addr       (icache_rd_addr),
        .rd_rdy        (icache_rd_rdy),
        .return_valid  (icache_return_valid),
        .return_last   (icache_return_last),
        .return_data   (icache_return_data),
        // debug
        .debug_main_state (debug_icache_state),
        .debug_rd_req     (debug_icache_rd_req)
    );

    // ================================================================
    // DCache
    // ================================================================
    dcache u_dcache (
        .clk           (clk),
        .resetn        (~reset),
        // CPU 接口
        .cpu_req       (dcache_cpu_req),
        .cpu_op        (dcache_cpu_op),
        .cpu_index     (dcache_cpu_index),
        .mmu_tag       (ex_tag),
        .cpu_offset    (dcache_cpu_offset),
        .cpu_wstrb     (dcache_cpu_wstrb),
        .cpu_wdata     (dcache_cpu_wdata),
        .mmu_cache     (mmu_ex_cached),
        .mmu_cancel    (s1_cancel),
        .cpu_addr_ok   (dcache_cpu_addr_ok),
        .cpu_data_ok   (dcache_cpu_data_ok),
        .cpu_rdata     (dcache_cpu_rdata),
        .cpu_accept    (dcache_cpu_accept),
        // CACOP
        .cacop_en      (dcache_cacop_en),
        .cacop_code    (cacop_code),
        .cacop_va      (cacop_va),
        .cacop_rdy     (dcache_cacop_rdy),
        // AXI 接口
        .rd_req        (dcache_rd_req),
        .rd_type       (dcache_rd_type),
        .rd_addr       (dcache_rd_addr),
        .rd_rdy        (dcache_rd_rdy),
        .return_valid  (dcache_return_valid),
        .return_last   (dcache_return_last),
        .return_data   (dcache_return_data),
        .wr_req        (dcache_wr_req),
        .wr_type       (dcache_wr_type),
        .wr_addr       (dcache_wr_addr),
        .wr_wstrb      (dcache_wr_wstrb),
        .wr_data       (dcache_wr_data),
        .wr_rdy        (dcache_wr_rdy),
        .wr_done       (dcache_wr_done)
    );

    // ================================================================
    // Cache-AXI 转接桥
    // ================================================================
    cache_axi_bridge u_cache_axi_bridge (
        .clk                  (clk),
        .reset                (reset),
        // ICache 接口
        .icache_rd_req        (icache_rd_req),
        .icache_rd_type       (icache_rd_type),
        .icache_rd_addr       (icache_rd_addr),
        .icache_rd_rdy        (icache_rd_rdy),
        .icache_return_valid  (icache_return_valid),
        .icache_return_last   (icache_return_last),
        .icache_return_data   (icache_return_data),
        // DCache 接口
        .dcache_rd_req        (dcache_rd_req),
        .dcache_rd_type       (dcache_rd_type),
        .dcache_rd_addr       (dcache_rd_addr),
        .dcache_rd_rdy        (dcache_rd_rdy),
        .dcache_return_valid  (dcache_return_valid),
        .dcache_return_last   (dcache_return_last),
        .dcache_return_data   (dcache_return_data),
        .dcache_wr_req        (dcache_wr_req),
        .dcache_wr_type       (dcache_wr_type),
        .dcache_wr_addr       (dcache_wr_addr),
        .dcache_wr_wstrb      (dcache_wr_wstrb),
        .dcache_wr_data       (dcache_wr_data),
        .dcache_wr_rdy        (dcache_wr_rdy),
        .dcache_wr_done       (dcache_wr_done),
        // AXI 接口
        .arid           (arid),
        .araddr         (araddr),
        .arlen          (arlen),
        .arsize         (arsize),
        .arburst        (arburst),
        .arlock         (arlock),
        .arcache        (arcache),
        .arprot         (arprot),
        .arvalid        (arvalid),
        .arready        (arready),
        .rid            (rid),
        .rdata          (rdata),
        .rresp          (rresp),
        .rlast          (rlast),
        .rvalid         (rvalid),
        .rready         (rready),
        .awid           (awid),
        .awaddr         (awaddr),
        .awlen          (awlen),
        .awsize         (awsize),
        .awburst        (awburst),
        .awlock         (awlock),
        .awcache        (awcache),
        .awprot         (awprot),
        .awvalid        (awvalid),
        .awready        (awready),
        .wid            (wid),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .wlast          (wlast),
        .wvalid         (wvalid),
        .wready         (wready),
        .bid            (bid),
        .bresp          (bresp),
        .bvalid         (bvalid),
        .bready         (bready)
    );

    `ifdef DIFFTEST_EN
    always @(posedge aclk) begin
        if (reset) begin
            {cmt_valid, cmt_cnt_inst, cmt_timer_64, cmt_inst_ld_en, cmt_ld_paddr, cmt_ld_vaddr, cmt_inst_st_en, cmt_st_paddr, cmt_st_vaddr, cmt_st_data, cmt_csr_rstat_en, cmt_csr_data} <= 0;
            {cmt_wen, cmt_wdest, cmt_wdata, cmt_pc, cmt_inst} <= 0;
            {trap, trap_code, cycleCnt, instrCnt} <= 0;
        end
        else if (~trap) begin
            cmt_valid       <= inst_valid_diff          ;
            cmt_cnt_inst    <= cnt_inst_diff            ;
            cmt_timer_64    <= timer_64_diff            ;
            cmt_inst_ld_en  <= inst_ld_en_diff          ;
            cmt_ld_paddr    <= ld_paddr_diff            ;
            cmt_ld_vaddr    <= ld_vaddr_diff            ;
            cmt_inst_st_en  <= inst_st_en_diff          ;
            cmt_st_paddr    <= st_paddr_diff            ;
            cmt_st_vaddr    <= st_vaddr_diff            ;
            cmt_st_data     <= st_data_diff             ;
            cmt_csr_rstat_en<= csr_rstat_en_diff        ;
            cmt_csr_data    <= csr_data_diff            ;

            cmt_wen     <=  debug0_wb_rf_wen            ;
            cmt_wdest   <=  {3'd0, debug0_wb_rf_wnum}   ;
            cmt_wdata   <=  debug0_wb_rf_wdata          ;
            cmt_pc      <=  debug0_wb_pc                ;
            cmt_inst    <=  debug0_wb_inst              ;

            cmt_excp_flush  <= exc_not_rf                ;
            cmt_ertn        <= wb_ertn_flush             ;
            cmt_csr_ecode   <= ecode_out                 ;
            cmt_intrNo      <= csr_estat_diff_0[12:2]   ;
            cmt_tlbfill_en  <= tlbrwf_valid[0]           ;
            cmt_rand_index  <= tlbfill_rand_index        ;

            trap            <= 0                        ;
            trap_code       <= regs[10][7:0]            ;
            cycleCnt        <= cycleCnt + 1             ;
            instrCnt        <= instrCnt + inst_valid_diff;
        end
    end

    DifftestInstrCommit DifftestInstrCommit(
        .clock              (aclk           ),
        .coreid             (0              ),
        .index              (0              ),
        .valid              (cmt_valid      ),
        .pc                 (cmt_pc         ),
        .instr              (cmt_inst       ),
        .skip               (0              ),
        .is_TLBFILL         (cmt_tlbfill_en ),
        .TLBFILL_index      (cmt_rand_index ),
        .is_CNTinst         (cmt_cnt_inst   ),
        .timer_64_value     (cmt_timer_64   ),
        .wen                (cmt_wen        ),
        .wdest              (cmt_wdest      ),
        .wdata              (cmt_wdata      ),
        .csr_rstat          (cmt_csr_rstat_en),
        .csr_data           (cmt_csr_data   )
    );

    DifftestExcpEvent DifftestExcpEvent(
        .clock              (aclk           ),
        .coreid             (0              ),
        .excp_valid         (cmt_excp_flush ),
        .eret               (cmt_ertn       ),
        .intrNo             (csr_estat_diff_0[12:2]     ),
        .cause              (ecode_out      ),
        .exceptionPC        (cmt_pc         ),
        .exceptionInst      (cmt_inst       )
    );

    DifftestTrapEvent DifftestTrapEvent(
        .clock              (aclk           ),
        .coreid             (0              ),
        .valid              (0              ),
        .code               (trap_code      ),
        .pc                 (cmt_pc         ),
        .cycleCnt           (cycleCnt       ),
        .instrCnt           (instrCnt       )
    );

    DifftestStoreEvent DifftestStoreEvent(
        .clock              (aclk           ),
        .coreid             (0              ),
        .index              (0              ),
        .valid              (cmt_inst_st_en ),
        .storePAddr         (cmt_st_paddr   ),
        .storeVAddr         (cmt_st_vaddr   ),
        .storeData          (cmt_st_data    )
    );

    DifftestLoadEvent DifftestLoadEvent(
        .clock              (aclk           ),
        .coreid             (0              ),
        .index              (0              ),
        .valid              (cmt_inst_ld_en ),
        .paddr              (cmt_ld_paddr   ),
        .vaddr              (cmt_ld_vaddr   )
    );

    DifftestCSRRegState DifftestCSRRegState(
        .clock              (aclk               ),
        .coreid             (0                  ),
        .crmd               (csr_crmd_diff_0    ),
        .prmd               (csr_prmd_diff_0    ),
        .euen               (0                  ),
        .ecfg               (csr_ectl_diff_0    ),
        .estat              (csr_estat_diff_0   ),
        .era                (csr_era_diff_0     ),
        .badv               (csr_badv_diff_0    ),
        .eentry             (csr_eentry_diff_0  ),
        .tlbidx             (csr_tlbidx_diff_0  ),
        .tlbehi             (csr_tlbehi_diff_0  ),
        .tlbelo0            (csr_tlbelo0_diff_0 ),
        .tlbelo1            (csr_tlbelo1_diff_0 ),
        .asid               (csr_asid_diff_0    ),
        .pgdl               (csr_pgdl_diff_0    ),
        .pgdh               (csr_pgdh_diff_0    ),
        .save0              (csr_save0_diff_0   ),
        .save1              (csr_save1_diff_0   ),
        .save2              (csr_save2_diff_0   ),
        .save3              (csr_save3_diff_0   ),
        .tid                (csr_tid_diff_0     ),
        .tcfg               (csr_tcfg_diff_0    ),
        .tval               (csr_tval_diff_0    ),
        .ticlr              (csr_ticlr_diff_0   ),
        .llbctl             (csr_llbctl_diff_0  ),
        .tlbrentry          (csr_tlbrentry_diff_0),
        .dmw0               (csr_dmw0_diff_0    ),
        .dmw1               (csr_dmw1_diff_0    )
    );

    DifftestGRegState DifftestGRegState(
        .clock              (aclk       ),
        .coreid             (0          ),
        .gpr_0              (0          ),
        .gpr_1              (regs[1]    ),
        .gpr_2              (regs[2]    ),
        .gpr_3              (regs[3]    ),
        .gpr_4              (regs[4]    ),
        .gpr_5              (regs[5]    ),
        .gpr_6              (regs[6]    ),
        .gpr_7              (regs[7]    ),
        .gpr_8              (regs[8]    ),
        .gpr_9              (regs[9]    ),
        .gpr_10             (regs[10]   ),
        .gpr_11             (regs[11]   ),
        .gpr_12             (regs[12]   ),
        .gpr_13             (regs[13]   ),
        .gpr_14             (regs[14]   ),
        .gpr_15             (regs[15]   ),
        .gpr_16             (regs[16]   ),
        .gpr_17             (regs[17]   ),
        .gpr_18             (regs[18]   ),
        .gpr_19             (regs[19]   ),
        .gpr_20             (regs[20]   ),
        .gpr_21             (regs[21]   ),
        .gpr_22             (regs[22]   ),
        .gpr_23             (regs[23]   ),
        .gpr_24             (regs[24]   ),
        .gpr_25             (regs[25]   ),
        .gpr_26             (regs[26]   ),
        .gpr_27             (regs[27]   ),
        .gpr_28             (regs[28]   ),
        .gpr_29             (regs[29]   ),
        .gpr_30             (regs[30]   ),
        .gpr_31             (regs[31]   )
    );
    `endif

endmodule
