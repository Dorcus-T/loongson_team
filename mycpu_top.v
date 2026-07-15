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
    output wire [31:0]  debug0_wb_inst             // WB阶段指令
);

    // ========== 复位信号处理（将低有效转换为高有效） ==========
    reg  reset;
    wire clk = aclk;
    always @(posedge clk) reset <= ~aresetn;

    // ========== 流水线控制信号（各级之间的握手信号） ==========
    wire id_allowin;                     // ID阶段允许接收（来自ID）
    wire ex_allowin;                     // EX阶段允许接收（来自EX）
    wire mem_allowin;                    // MEM阶段允许接收（来自MEM）
    wire wb_allowin;                     // WB阶段允许接收（来自WB）

    // 各级流水线有效标志
    wire if_to_id_valid;                 // IF -> ID 有效
    wire id_to_ex_valid;                 // ID -> EX 有效
    wire ex_to_mem_valid;                // EX -> MEM 有效
    wire mem_to_wb_valid;                // MEM -> WB 有效

    // ========== 流水线总线（各级之间的数据传递） ==========
    wire [`IF_TO_ID_BUS_WD-1:0]  if_to_id_bus;   // IF -> ID 总线
    wire [`ID_TO_EX_BUS_WD-1:0]  id_to_ex_bus;   // ID -> EX 总线
    wire [`EX_TO_MEM_BUS_WD-1:0] ex_to_mem_bus;  // EX -> MEM 总线
    wire [`MEM_TO_WB_BUS_WD-1:0] mem_to_wb_bus;  // MEM -> WB 总线
    wire [`WB_TO_RF_BUS_WD-1:0]  wb_to_rf_bus;   // WB -> 寄存器文件
    wire [`WB_TO_CSR_BUS_WD-1:0] wb_to_csr_bus;  // WB -> CSR总线
    wire [`BR_BUS_WD-1:0]        br_bus;         // 分支总线

    // ========== 数据前递信号（解决RAW数据冒险） ==========
    wire [ 4:0] ex_to_id_dest;            // EX阶段写回的寄存器号
    wire [ 4:0] mem_to_id_dest;           // MEM阶段写回的寄存器号
    wire [ 4:0] wb_to_id_dest;            // WB阶段写回的寄存器号

    wire [31:0] ex_to_id_result;         // EX阶段计算结果
    wire [31:0] mem_to_id_result;        // MEM阶段计算结果
    wire [31:0] wb_to_id_result;         // WB阶段计算结果
    wire        ex_to_id_load_op;        // EX阶段是否为加载指令（用于load-use检测）
    wire        mem_to_id_data_ok;       // MEM前递给id的数据是否准备好

    // ========== 异常信号与ertn ==========
    wire ex_mem_exc_valid;   // EX阶段异常有效
    wire wb_exc_valid;       // WB阶段异常有效
    wire wb_ertn_flush;      // WB阶段有ertn指令
    wire mem_exc_valid;      // MEM阶段异常有效
    wire mem_ertn_flush;     // MEM阶段有ertn指令
    wire ex_ertn_flush;

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
    wire [31:0] if_to_mmu_vaddr;    // if发mmu虚地址
    wire [31:0] ex_to_mmu_vaddr;    // ex发mmu虚地址
    wire [35:0] vtlb_enop;          // 发mmu tlbsrch，invtlb使能即操作数
    wire [ 1:0] ld_and_str;         // 发mmu load和store信号
    wire [ 2:0] tlbrwf_valid;       // tlbrd tlbwr tlbfill使能
    wire [31:0] paddr_to_if;        // 发if实地址
    wire [ 2:0] if_tlb_exc;         // 发if tlb相关异常
    wire [ 1:0] if_mat;             // if 访存方式
    wire        if_cached;          // if 访问可缓存
    wire [31:0] paddr_to_ex;        // 发ex实地址
    wire [ 5:0] srch_value;         // 发ex tlbsrch查询结果
    wire [ 4:0] ex_tlb_exc;         // 发ex tlb相关异常
    wire [ 1:0] ex_mat;             // ex 访存方式
    wire        ex_cached;          // ex 访问可缓存
    wire [`TLBRD_BUS_WD-1:0] tlbrd_value; // 发csr tlbrd使能和数据

    // ========== 计数器数值 ==========
    wire [63:0] timer_value;        // 计数器输出

    // ================================================================
    // ICache — CPU 侧连线
    // ================================================================
    wire        icache_cpu_req;
    wire        icache_cpu_op;
    wire [ 7:0] icache_cpu_index;
    wire [19:0] icache_cpu_tag;
    wire [ 3:0] icache_cpu_offset;
    wire [ 3:0] icache_cpu_wstrb;
    wire [31:0] icache_cpu_wdata;
    wire        icache_cpu_cached;
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
    wire [19:0] dcache_cpu_tag;
    wire [ 3:0] dcache_cpu_offset;
    wire [ 3:0] dcache_cpu_wstrb;
    wire [31:0] dcache_cpu_wdata;
    wire        dcache_cpu_cached;
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
    wire [`TAG_WIDTH-1:0] cacop_tag;
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
    wire        icache_bus_accept;

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
    wire        dcache_bus_accept;

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

    // 从 wb_to_csr_bus 提取 CSR 写信息
    wire        wb_csr_we_bus = wb_to_csr_bus[145];
    wire [13:0] wb_csr_num_bus = wb_to_csr_bus[159:146];
    wire [31:0] wb_csr_wmask_bus = wb_to_csr_bus[144:113];
    wire [31:0] wb_csr_wvalue_bus = wb_to_csr_bus[112:81];

    // CSR _nxt：csr_we 写时取新值，否则取当前值（异常写不过 csr_we，自然延迟一拍）
    `define CSR_NXT(name, CSR_ADDR) (wb_csr_we_bus && wb_csr_num_bus == CSR_ADDR) ? ((wb_csr_wmask_bus & wb_csr_wvalue_bus) | (~wb_csr_wmask_bus & csr_``name``_diff_0)) : csr_``name``_diff_0
    wire [31:0] csr_crmd_nxt    = `CSR_NXT(crmd,    `CSR_CRMD);
    wire [31:0] csr_prmd_nxt    = `CSR_NXT(prmd,    `CSR_PRMD);
    wire [31:0] csr_ectl_nxt    = `CSR_NXT(ectl,    `CSR_ECFG);
    wire [31:0] csr_estat_nxt   = `CSR_NXT(estat,   `CSR_ESTAT);
    wire [31:0] csr_era_nxt     = `CSR_NXT(era,     `CSR_ERA);
    wire [31:0] csr_badv_nxt    = `CSR_NXT(badv,    `CSR_BADV);
    wire [31:0] csr_eentry_nxt  = `CSR_NXT(eentry,  `CSR_EENTRY);
    wire [31:0] csr_tlbidx_nxt  = `CSR_NXT(tlbidx,  `CSR_TLBIDX);
    wire [31:0] csr_tlbehi_nxt  = `CSR_NXT(tlbehi,  `CSR_TLBEHI);
    wire [31:0] csr_tlbelo0_nxt = `CSR_NXT(tlbelo0, `CSR_TLBELO0);
    wire [31:0] csr_tlbelo1_nxt = `CSR_NXT(tlbelo1, `CSR_TLBELO1);
    wire [31:0] csr_asid_nxt    = `CSR_NXT(asid,    `CSR_ASID);
    wire [31:0] csr_save0_nxt   = `CSR_NXT(save0,   `CSR_SAVE0);
    wire [31:0] csr_save1_nxt   = `CSR_NXT(save1,   `CSR_SAVE1);
    wire [31:0] csr_save2_nxt   = `CSR_NXT(save2,   `CSR_SAVE2);
    wire [31:0] csr_save3_nxt   = `CSR_NXT(save3,   `CSR_SAVE3);
    wire [31:0] csr_tid_nxt     = `CSR_NXT(tid,     `CSR_TID);
    wire [31:0] csr_tcfg_nxt    = `CSR_NXT(tcfg,    `CSR_TCFG);
    wire [31:0] csr_tval_nxt    = `CSR_NXT(tval,    `CSR_TVAL);
    wire [31:0] csr_ticlr_nxt   = `CSR_NXT(ticlr,   `CSR_TICLR);
    wire [31:0] csr_llbctl_nxt  = `CSR_NXT(llbctl,  `CSR_LLBCTL);
    wire [31:0] csr_tlbrentry_nxt = `CSR_NXT(tlbrentry, `CSR_TLBRENTRY);
    wire [31:0] csr_dmw0_nxt    = `CSR_NXT(dmw0,    `CSR_DMW0);
    wire [31:0] csr_dmw1_nxt    = `CSR_NXT(dmw1,    `CSR_DMW1);
    wire [31:0] csr_pgdl_nxt    = `CSR_NXT(pgdl,    `CSR_PGDL);
    wire [31:0] csr_pgdh_nxt    = `CSR_NXT(pgdh,    `CSR_PGDH);
    wire [12:0] csr_intrNo_nxt  = csr_estat_nxt[12:2];

    // CSR 延迟一拍（解决异常写时序；csr_we 写通过 _nxt 补偿）
    reg  [31:0] cmt_csr_crmd;    reg  [31:0] cmt_csr_prmd;
    reg  [31:0] cmt_csr_ectl;    reg  [31:0] cmt_csr_estat;
    reg  [31:0] cmt_csr_era;     reg  [31:0] cmt_csr_badv;
    reg  [31:0] cmt_csr_eentry;  reg  [31:0] cmt_csr_tlbidx;
    reg  [31:0] cmt_csr_tlbehi;  reg  [31:0] cmt_csr_tlbelo0;
    reg  [31:0] cmt_csr_tlbelo1; reg  [31:0] cmt_csr_asid;
    reg  [31:0] cmt_csr_save0;   reg  [31:0] cmt_csr_save1;
    reg  [31:0] cmt_csr_save2;   reg  [31:0] cmt_csr_save3;
    reg  [31:0] cmt_csr_tid;     reg  [31:0] cmt_csr_tcfg;
    reg  [31:0] cmt_csr_tval;    reg  [31:0] cmt_csr_ticlr;
    reg  [31:0] cmt_csr_llbctl;  reg  [31:0] cmt_csr_tlbrentry;
    reg  [31:0] cmt_csr_dmw0;    reg  [31:0] cmt_csr_dmw1;
    reg  [31:0] cmt_csr_pgdl;    reg  [31:0] cmt_csr_pgdh;
    reg  [12:0] cmt_csr_intrNo;

    assign ws_valid = ws_valid_diff;
    assign rf_rdata = regs[reg_num];
    `endif

    // ================================================================
    // 第一阶段：取指阶段 (IF - Instruction Fetch)
    // ================================================================
    if_stage u_if_stage (
        .clk                (clk),
        .reset              (reset),
        .id_allowin         (id_allowin),
        .br_bus             (br_bus),
        .if_to_id_valid     (if_to_id_valid),
        .if_to_id_bus       (if_to_id_bus),
        .icache_cpu_req   (icache_cpu_req),
        .icache_cpu_op      (icache_cpu_op),
        .icache_cpu_index   (icache_cpu_index),
        .icache_cpu_tag     (icache_cpu_tag),
        .icache_cpu_offset  (icache_cpu_offset),
        .icache_cpu_wstrb   (icache_cpu_wstrb),
        .icache_cpu_wdata   (icache_cpu_wdata),
        .icache_cpu_cached  (icache_cpu_cached),
        .icache_cpu_addr_ok (icache_cpu_addr_ok),
        .icache_cpu_data_ok (icache_cpu_data_ok),
        .icache_cpu_rdata   (icache_cpu_rdata),
        .icache_cpu_accept  (icache_cpu_accept),
        .if_to_mmu_vaddr    (if_to_mmu_vaddr),
        .padd               (paddr_to_if),
        .if_tlb_exc         (if_tlb_exc),
        .if_cached          (if_cached),
        .exc_no_rf          (exc_not_rf),
        .wb_ertn_flush      (wb_ertn_flush),
        .exc_entry          (exc_entry),
        .exc_back_pc        (exc_back_pc),
        .rf_valid           (rf_valid),
        .rf_pc              (wb_pc_back)
    );

    // ================================================================
    // 第二阶段：译码阶段 (ID - Instruction Decode)
    // ================================================================
    id_stage u_id_stage (
        .clk               (clk),
        .reset             (reset),
        .ex_allowin        (ex_allowin),
        .id_allowin        (id_allowin),
        .if_to_id_valid    (if_to_id_valid),
        .if_to_id_bus      (if_to_id_bus),
        .id_to_ex_valid    (id_to_ex_valid),
        .id_to_ex_bus      (id_to_ex_bus),
        .br_bus            (br_bus),
        .wb_to_rf_bus      (wb_to_rf_bus),
        .ex_to_id_dest     (ex_to_id_dest),
        .mem_to_id_dest    (mem_to_id_dest),
        .wb_to_id_dest     (wb_to_id_dest),
        .ex_to_id_load_op  (ex_to_id_load_op),
        .ex_to_id_result   (ex_to_id_result),
        .mem_to_id_result  (mem_to_id_result),
        .wb_to_id_result   (wb_to_id_result),
        .mem_to_id_data_ok (mem_to_id_data_ok),
        .mem_exc_valid     (mem_exc_valid),
        .ex_csr_we         (ex_csr_we),
        .ex_csr_num        (ex_csr_num),
        .ex_ertn_flush     (ex_ertn_flush),
        .mem_csr_we        (mem_csr_we),
        .mem_csr_num       (mem_csr_num),
        .mem_ertn_flush    (mem_ertn_flush),
        .ex_mem_exc_valid   (ex_mem_exc_valid),
        .wb_csr_we         (wb_csr_we),
        .wb_csr_num        (wb_csr_num),
        .wb_exc_valid      (wb_exc_valid),
        .wb_ertn_flush     (wb_ertn_flush),
        .csr_rvalue        (csr_rvalue),
        .csr_id_num        (csr_id_num),
        .has_int           (has_int),
        .timer_64          (timer_value),
        .csr_da_pg         (da_pg_out)
        `ifdef DIFFTEST_EN
        ,
        .rf_to_diff        (regs)
        `endif
    );

    // ================================================================
    // 第三阶段：执行阶段 (EX - Execute)
    // ================================================================
    exe_stage u_exe_stage (
        .clk                (clk),
        .reset              (reset),
        .mem_allowin        (mem_allowin),
        .ex_allowin         (ex_allowin),
        .id_to_ex_valid     (id_to_ex_valid),
        .id_to_ex_bus       (id_to_ex_bus),
        .ex_to_mem_valid    (ex_to_mem_valid),
        .ex_to_mem_bus      (ex_to_mem_bus),
        .ex_to_mmu_vaddr    (ex_to_mmu_vaddr),
        .dcache_cpu_req   (dcache_cpu_req),
        .dcache_cpu_op      (dcache_cpu_op),
        .dcache_cpu_index   (dcache_cpu_index),
        .dcache_cpu_tag     (dcache_cpu_tag),
        .dcache_cpu_offset  (dcache_cpu_offset),
        .dcache_cpu_wstrb   (dcache_cpu_wstrb),
        .dcache_cpu_wdata   (dcache_cpu_wdata),
        .dcache_cpu_cached  (dcache_cpu_cached),
        .dcache_cpu_addr_ok (dcache_cpu_addr_ok),
        .vtlb_enop          (vtlb_enop),
        .ld_and_str         (ld_and_str),
        .padd               (paddr_to_ex),
        .srch_value         (srch_value),
        .mem_tlb_exc        (ex_tlb_exc),
        .ex_cached          (ex_cached),
        .ex_to_id_dest      (ex_to_id_dest),
        .ex_to_id_result    (ex_to_id_result),
        .ex_to_id_load_op   (ex_to_id_load_op),
        .ex_mem_exc_valid   (ex_mem_exc_valid),
        .wb_exc_valid       (wb_exc_valid),
        .wb_ertn_flush      (wb_ertn_flush),
        .mem_exc_valid      (mem_exc_valid),
        .mem_ertn_flush     (mem_ertn_flush),
        .ex_csr_we          (ex_csr_we),
        .ex_csr_num         (ex_csr_num),
        .ex_ertn_flush      (ex_ertn_flush),
        .timer_value        (timer_value),
        // CACOP
        .cacop_code         (cacop_code),
        .cacop_en_final     (cacop_en_final),
        .cacop_va           (cacop_va),
        .cacop_tag          (cacop_tag),
        .icache_cacop_rdy   (icache_cacop_rdy),
        .dcache_cacop_rdy   (dcache_cacop_rdy)
    );

    // ================================================================
    // 第四阶段：访存阶段 (MEM - Memory Access)
    // ================================================================
    mem_stage u_mem_stage (
        .clk                  (clk),
        .reset                (reset),
        .wb_allowin           (wb_allowin),
        .mem_allowin          (mem_allowin),
        .ex_to_mem_valid      (ex_to_mem_valid),
        .ex_to_mem_bus        (ex_to_mem_bus),
        .mem_to_wb_valid      (mem_to_wb_valid),
        .mem_to_wb_bus        (mem_to_wb_bus),
        .dcache_cpu_rdata     (dcache_cpu_rdata),
        .dcache_cpu_data_ok   (dcache_cpu_data_ok),
        .mem_to_id_dest       (mem_to_id_dest),
        .mem_to_id_result     (mem_to_id_result),
        .mem_to_id_data_ok    (mem_to_id_data_ok),
        .wb_exc_valid         (wb_exc_valid),
        .wb_ertn_flush        (wb_ertn_flush),
        .mem_exc_valid        (mem_exc_valid),
        .mem_ertn_flush       (mem_ertn_flush),
        .mem_csr_we           (mem_csr_we),
        .mem_csr_num          (mem_csr_num),
        .dcache_cpu_accept    (dcache_cpu_accept)
    );

    // ================================================================
    // 第五阶段：写回阶段 (WB - Write Back)
    // ================================================================
    wb_stage u_wb_stage (
        .clk               (clk),
        .reset             (reset),
        .wb_allowin        (wb_allowin),
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
        .wb_exc_valid      (wb_exc_valid),
        .wb_csr_we         (wb_csr_we),
        .wb_csr_num        (wb_csr_num),
        .wb_to_csr_bus     (wb_to_csr_bus),
        .exc_no_rf         (exc_not_rf),
        .rf_valid          (rf_valid),
        .wb_pc_back        (wb_pc_back),
        .tlbrwf_valid      (tlbrwf_valid)
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
        .clk           (clk),
        .reset         (reset),

        // if interact
        .vaddr_from_if (if_to_mmu_vaddr),
        .paddr_to_if   (paddr_to_if),
        .if_tlb_exc    (if_tlb_exc),
        .if_mat        (if_mat),
        .if_cached     (if_cached),

        // ex interact
        .vaddr_from_ex (ex_to_mmu_vaddr),
        .vtlb_enop     (vtlb_enop),
        .ld_and_str    (ld_and_str),
        .paddr_to_ex   (paddr_to_ex),
        .srch_value    (srch_value),
        .ex_tlb_exc    (ex_tlb_exc),
        .ex_mat        (ex_mat),
        .ex_cached     (ex_cached),

        // wb interact
        .tlbrwf_en     (tlbrwf_valid),

        // csr interact
        .plv_in        (plv_out),
        .ecode_in      (ecode_out),
        .dapg_in       (da_pg_out),
        .datf_in       (datf_out),
        .datm_in       (datm_out),
        .dmw           (dmw_out),
        .tlbcsr        (tlbcsr_bus),
        .tlbrd_value   (tlbrd_value)
    );

    // ================================================================
    // 计数器
    // ================================================================
    timer_64bit u_timer_64bit (
        .clk         (clk),
        .reset       (reset),
        .timer_value (timer_value)
    );

    // ================================================================
    // ICache
    // ================================================================
    cache u_icache (
        .clk          (clk),
        .resetn       (~reset),
        // CPU 接口
        .cpu_req      (icache_cpu_req),
        .cpu_op       (icache_cpu_op),
        .cpu_index    (icache_cpu_index),
        .cpu_tag      (icache_cpu_tag),
        .cpu_offset   (icache_cpu_offset),
        .cpu_wstrb    (icache_cpu_wstrb),
        .cpu_wdata    (icache_cpu_wdata),
        .cpu_cached   (icache_cpu_cached),
        .cpu_addr_ok  (icache_cpu_addr_ok),
        .cpu_data_ok  (icache_cpu_data_ok),
        .cpu_rdata    (icache_cpu_rdata),
        .cpu_accept       (icache_cpu_accept),
        // CACOP
        .cacop_en         (icache_cacop_en),
        .cacop_code       (cacop_code),
        .cacop_va         (cacop_va),
        .cacop_tag        (cacop_tag),
        .cacop_rdy        (icache_cacop_rdy),
        // AXI 接口
        .rd_req       (icache_rd_req),
        .rd_type      (icache_rd_type),
        .rd_addr      (icache_rd_addr),
        .rd_rdy       (icache_rd_rdy),
        .return_valid (icache_return_valid),
        .return_last  (icache_return_last),
        .return_data  (icache_return_data),
        .wr_req       (),
        .wr_type      (),
        .wr_addr      (),
        .wr_wstrb     (),
        .wr_data      (),
        .wr_rdy       (1'b1),
        .wr_done      (1'b0),
        .bus_accept   (icache_bus_accept)
    );

    // ================================================================
    // DCache
    // ================================================================
    cache u_dcache (
        .clk          (clk),
        .resetn       (~reset),
        // CPU 接口
        .cpu_req      (dcache_cpu_req),
        .cpu_op       (dcache_cpu_op),
        .cpu_index    (dcache_cpu_index),
        .cpu_tag      (dcache_cpu_tag),
        .cpu_offset   (dcache_cpu_offset),
        .cpu_wstrb    (dcache_cpu_wstrb),
        .cpu_wdata    (dcache_cpu_wdata),
        .cpu_cached   (dcache_cpu_cached),
        .cpu_addr_ok  (dcache_cpu_addr_ok),
        .cpu_data_ok  (dcache_cpu_data_ok),
        .cpu_rdata    (dcache_cpu_rdata),
        .cpu_accept       (dcache_cpu_accept),
        // CACOP
        .cacop_en         (dcache_cacop_en),
        .cacop_code       (cacop_code),
        .cacop_va         (cacop_va),
        .cacop_tag        (cacop_tag),
        .cacop_rdy        (dcache_cacop_rdy),
        // AXI 接口
        .rd_req       (dcache_rd_req),
        .rd_type      (dcache_rd_type),
        .rd_addr      (dcache_rd_addr),
        .rd_rdy       (dcache_rd_rdy),
        .return_valid (dcache_return_valid),
        .return_last  (dcache_return_last),
        .return_data  (dcache_return_data),
        .wr_req       (dcache_wr_req),
        .wr_type      (dcache_wr_type),
        .wr_addr      (dcache_wr_addr),
        .wr_wstrb     (dcache_wr_wstrb),
        .wr_data      (dcache_wr_data),
        .wr_rdy       (dcache_wr_rdy),
        .wr_done      (dcache_wr_done),
        .bus_accept   (dcache_bus_accept)
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
        .icache_accept        (icache_bus_accept),
        .icache_wr_req        (1'b0),
        .icache_wr_type       (3'b0),
        .icache_wr_addr       (32'b0),
        .icache_wr_wstrb      (4'b0),
        .icache_wr_data       (128'b0),
        .icache_wr_rdy        (),
        // DCache 接口
        .dcache_rd_req        (dcache_rd_req),
        .dcache_rd_type       (dcache_rd_type),
        .dcache_rd_addr       (dcache_rd_addr),
        .dcache_rd_rdy        (dcache_rd_rdy),
        .dcache_return_valid  (dcache_return_valid),
        .dcache_return_last   (dcache_return_last),
        .dcache_return_data   (dcache_return_data),
        .dcache_accept        (dcache_bus_accept),
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
            cmt_tlbfill_en  <= tlbrwf_valid[0]           ;
            cmt_rand_index  <= 5'b0                      ;

            trap            <= 0                        ;
            trap_code       <= regs[10][7:0]            ;
            cycleCnt        <= cycleCnt + 1             ;
            instrCnt        <= instrCnt + inst_valid_diff;

            cmt_csr_crmd        <= csr_crmd_nxt      ;
            cmt_csr_prmd        <= csr_prmd_nxt      ;
            cmt_csr_ectl        <= csr_ectl_nxt      ;
            cmt_csr_estat       <= csr_estat_nxt     ;
            cmt_csr_era         <= csr_era_nxt       ;
            cmt_csr_badv        <= csr_badv_nxt      ;
            cmt_csr_eentry      <= csr_eentry_nxt    ;
            cmt_csr_tlbidx      <= csr_tlbidx_nxt    ;
            cmt_csr_tlbehi      <= csr_tlbehi_nxt    ;
            cmt_csr_tlbelo0     <= csr_tlbelo0_nxt   ;
            cmt_csr_tlbelo1     <= csr_tlbelo1_nxt   ;
            cmt_csr_asid        <= csr_asid_nxt      ;
            cmt_csr_save0       <= csr_save0_nxt     ;
            cmt_csr_save1       <= csr_save1_nxt     ;
            cmt_csr_save2       <= csr_save2_nxt     ;
            cmt_csr_save3       <= csr_save3_nxt     ;
            cmt_csr_tid         <= csr_tid_nxt       ;
            cmt_csr_tcfg        <= csr_tcfg_nxt      ;
            cmt_csr_tval        <= csr_tval_nxt      ;
            cmt_csr_ticlr       <= csr_ticlr_nxt     ;
            cmt_csr_llbctl      <= csr_llbctl_nxt    ;
            cmt_csr_tlbrentry   <= csr_tlbrentry_nxt ;
            cmt_csr_dmw0        <= csr_dmw0_nxt      ;
            cmt_csr_dmw1        <= csr_dmw1_nxt      ;
            cmt_csr_pgdl        <= csr_pgdl_nxt      ;
            cmt_csr_pgdh        <= csr_pgdh_nxt      ;
            cmt_csr_intrNo      <= csr_intrNo_nxt    ;
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
        .intrNo             (cmt_csr_intrNo ),
        .cause              (cmt_csr_ecode  ),
        .exceptionPC        (cmt_pc         ),
        .exceptionInst      (cmt_inst       )
    );

    DifftestTrapEvent DifftestTrapEvent(
        .clock              (aclk           ),
        .coreid             (0              ),
        .valid              (trap           ),
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
        .crmd               (cmt_csr_crmd       ),
        .prmd               (cmt_csr_prmd       ),
        .euen               (0                  ),
        .ecfg               (cmt_csr_ectl       ),
        .estat              (cmt_csr_estat      ),
        .era                (cmt_csr_era        ),
        .badv               (cmt_csr_badv       ),
        .eentry             (cmt_csr_eentry     ),
        .tlbidx             (cmt_csr_tlbidx     ),
        .tlbehi             (cmt_csr_tlbehi     ),
        .tlbelo0            (cmt_csr_tlbelo0    ),
        .tlbelo1            (cmt_csr_tlbelo1    ),
        .asid               (cmt_csr_asid       ),
        .pgdl               (cmt_csr_pgdl       ),
        .pgdh               (cmt_csr_pgdh       ),
        .save0              (cmt_csr_save0      ),
        .save1              (cmt_csr_save1      ),
        .save2              (cmt_csr_save2      ),
        .save3              (cmt_csr_save3      ),
        .tid                (cmt_csr_tid        ),
        .tcfg               (cmt_csr_tcfg       ),
        .tval               (cmt_csr_tval       ),
        .ticlr              (cmt_csr_ticlr      ),
        .llbctl             (cmt_csr_llbctl     ),
        .tlbrentry          (cmt_csr_tlbrentry  ),
        .dmw0               (cmt_csr_dmw0       ),
        .dmw1               (cmt_csr_dmw1       )
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
