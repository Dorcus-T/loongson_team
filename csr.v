`include "mycpu.h"
module csr_regfile (
    // 时钟与复位
    input  wire                         clk,
    input  wire                         reset,
    // 与 IF 阶段交互
    output wire [31:0]                  exc_entry,     // 异常入口地址（供PC跳转）
    output wire [31:0]                  exc_back_pc,   // 异常返回地址
    // 与 ID 阶段交互
    input  wire [13:0]                  csr_id_num,    // ID阶段读CSR号码
    output wire [31:0]                  csr_rvalue,    // 读出数据，送给ID阶段
    output wire                         has_int,       // 有待处理的中断
    // 与 WB 阶段交互
    input  wire [`WB_TO_CSR_BUS_WD-1:0] wb_to_csr_bus,
    // 来自顶层
    input  wire [31:0]                  coreid_in,
    // 中断输入（异步）
    input  wire [ 7:0]                  hw_inter_num,  // 硬件中断号（2-9）
    input  wire                         ipi_inter,     // 核间中断（中断号12）
    // 特殊 CSR 相关
    output wire [ 1:0]                  plv_out,
    output wire [ 5:0]                  ecode_out,     // 例外码输出
    output wire [ 1:0]                  da_pg_out,
    output wire [63:0]                  dmw_out,
    input  wire [`TLBRD_BUS_WD-1:0]     tlbrd_bus,     // TLB数据传入（由MMU加工）
    output wire [`TLBCSR_BUS_WD-1:0]    tlbcsr_bus     // TLB相关CSR数据总线
);

    // ========== CSR 值输出（供流水线使用） ==========
    wire [31:0] csr_crmd_rvalue;
    wire [31:0] csr_prmd_rvalue;
    wire [31:0] csr_euen_rvalue;
    wire [31:0] csr_ecfg_rvalue;
    wire [31:0] csr_estat_rvalue;
    wire [31:0] csr_era_rvalue;
    wire [31:0] csr_badv_rvalue;
    wire [31:0] csr_eentry_rvalue;
    wire [31:0] csr_tlbidx_rvalue;
    wire [31:0] csr_tlbehi_rvalue;
    wire [31:0] csr_tlbelo0_rvalue;
    wire [31:0] csr_tlbelo1_rvalue;
    wire [31:0] csr_asid_rvalue;
    wire [31:0] csr_pgdl_rvalue;
    wire [31:0] csr_pgdh_rvalue;
    wire [31:0] csr_pgd_rvalue;
    wire [31:0] csr_cpuid_rvalue;
    wire [31:0] csr_save0_rvalue;
    wire [31:0] csr_save1_rvalue;
    wire [31:0] csr_save2_rvalue;
    wire [31:0] csr_save3_rvalue;
    wire [31:0] csr_tid_rvalue;
    wire [31:0] csr_tcfg_rvalue;
    wire [31:0] csr_tval_rvalue;
    wire [31:0] csr_ticlr_rvalue;
    wire [31:0] csr_llbctl_rvalue;
    wire [31:0] csr_tlbrentry_rvalue;
    wire [31:0] csr_ctag_rvalue;
    wire [31:0] csr_dmw0_rvalue;
    wire [31:0] csr_dmw1_rvalue;

    // ========== 异常种类判断 ==========
    wire wb_exc_badv_err; // badv
    wire wb_exc_ehi_err;  // tlbehi

    // ========== 内部生成定时器中断 ==========
    wire timer_inter;

    // ========== 来自 WB 的信号 ==========
    wire [13:0] csr_num;         // CSR号码
    wire        csr_we;          // CSR写使能
    wire [31:0] csr_wmask;       // CSR写掩码
    wire [31:0] csr_wvalue;      // CSR写数据
    wire        wb_ertn_flush;   // 异常返回冲刷信号
    wire        wb_exc_valid;    // 异常有效标志
    wire [ 5:0] wb_exc_ecode;    // 异常码
    wire [ 8:0] wb_exc_esubcode; // 异常子码
    wire [31:0] wb_exc_badv;     // 异常地址（BADV）
    wire [31:0] wb_exc_pc;       // 异常PC（ERA）

    // ========== 解析来自 WB 的总线 ==========
    assign {
        csr_num,            // [159:146] 14位 CSR号码
        csr_we,             // [145]     1位  CSR写使能
        csr_wmask,          // [144:113] 32位 CSR写掩码
        csr_wvalue,         // [112:81]  32位 CSR写数据
        wb_ertn_flush,      // [80]      1位  异常返回冲刷信号
        wb_exc_valid,       // [79]      1位  异常有效标志
        wb_exc_ecode,       // [78:73]   6位  异常码
        wb_exc_esubcode,    // [72:64]   9位  异常子码
        wb_exc_badv,        // [63:32]   32位 异常地址（BADV）
        wb_exc_pc           // [31:0]    32位 异常PC（ERA）
    } = wb_to_csr_bus;

    // ========== 特殊 CSR 相关输出 ==========
    assign plv_out   = csr_crmd_rvalue[1:0];
    assign da_pg_out = {csr_crmd_rvalue[3], csr_crmd_rvalue[4]};// 映射模式输出
    assign dmw_out   = {csr_dmw0_rvalue, csr_dmw1_rvalue};      // 直接映射窗口输出
    assign ecode_out = csr_estat_rvalue[21:16];                 // ecode输出

    assign tlbcsr_bus = {
        csr_tlbidx_rvalue,
        csr_tlbelo0_rvalue,
        csr_tlbelo1_rvalue,
        csr_asid_rvalue,
        csr_tlbehi_rvalue
    };                                                          // 组装tlbcsr总线

    // 解析来自 WB 的 TLB 读数据
    wire [ 5:0] tlbrd_tlbidx_ps;
    wire        tlbrd_tlbidx_ne;
    wire        tlbrd_en;
    wire [18:0] tlbrd_tlbehi;
    wire [31:0] tlbrd_tlbelo0;
    wire [31:0] tlbrd_tlbelo1;
    wire [ 9:0] tlbrd_asid;
    assign {
        tlbrd_en,                                               // tlb输入写使能
        tlbrd_tlbidx_ps,
        tlbrd_tlbidx_ne,
        tlbrd_tlbehi,
        tlbrd_tlbelo0,
        tlbrd_tlbelo1,
        tlbrd_asid
    } = tlbrd_bus;                                              // 解析从wb来的tlb读数据用于写入

    // ============================================================
    // CSR 寄存器定义
    // ============================================================
    reg  [31:0] csr_crmd;
    reg  [31:0] csr_prmd;
    reg  [31:0] csr_euen;
    reg  [31:0] csr_ecfg;
    reg  [31:0] csr_estat;
    reg  [31:0] csr_era;
    reg  [31:0] csr_badv;
    reg  [31:0] csr_eentry;
    reg  [31:0] csr_tlbidx;
    reg  [31:0] csr_tlbehi;
    reg  [31:0] csr_tlbelo0;
    reg  [31:0] csr_tlbelo1;
    reg  [31:0] csr_asid;
    reg  [31:0] csr_pgdl;
    reg  [31:0] csr_pgdh;
    reg  [31:0] csr_pgd;
    reg  [31:0] csr_cpuid;
    reg  [31:0] csr_save0;
    reg  [31:0] csr_save1;
    reg  [31:0] csr_save2;
    reg  [31:0] csr_save3;
    reg  [31:0] csr_tid;
    reg  [31:0] csr_tcfg;
    wire [31:0] tcfg_next_value;                                // 定时器下次加载值
    reg  [31:0] csr_tval;
    reg  [31:0] csr_ticlr;
    reg  [31:0] csr_llbctl;
    reg  [31:0] csr_tlbrentry;
    reg  [31:0] csr_ctag;
    reg  [31:0] csr_dmw0;
    reg  [31:0] csr_dmw1;

    // ============================================================
    // CSR 寄存器读逻辑
    // ============================================================
    assign csr_crmd_rvalue    = {23'b0, csr_crmd[8:0]};
    assign csr_prmd_rvalue    = {29'b0, csr_prmd[2:0]};
    assign csr_euen_rvalue    = {31'b0, csr_euen[0]};
    assign csr_ecfg_rvalue    = {19'b0, csr_ecfg[12:11], 1'b0, csr_ecfg[9:0]};
    assign csr_estat_rvalue   = {1'b0, csr_estat[30:16], 3'b0, csr_estat[12:11], 1'b0, csr_estat[9:0]};
    assign csr_era_rvalue     = csr_era;
    assign csr_badv_rvalue    = csr_badv;
    assign csr_eentry_rvalue  = {csr_eentry[31:6], 6'b0};
    assign csr_tlbidx_rvalue  = {csr_tlbidx[31], 1'b0, csr_tlbidx[29:24], 19'b0, csr_tlbidx[`CSR_TLBIDX_INDEX]};
    assign csr_tlbehi_rvalue  = {csr_tlbehi[31:13], 13'b0};
    assign csr_tlbelo0_rvalue = {4'b0, csr_tlbelo0[27:8], 1'b0, csr_tlbelo0[6:0]};
    assign csr_tlbelo1_rvalue = {4'b0, csr_tlbelo1[27:8], 1'b0, csr_tlbelo1[6:0]};
    assign csr_asid_rvalue    = {8'b0, csr_asid[23:16], 6'b0, csr_asid[9:0]};
    assign csr_pgdl_rvalue    = {csr_pgdl[31:12], 12'b0};
    assign csr_pgdh_rvalue    = {csr_pgdh[31:12], 12'b0};
    assign csr_pgd_rvalue     = {csr_pgd[31:12], 12'b0};
    assign csr_cpuid_rvalue   = {23'b0, csr_cpuid[8:0]};
    assign csr_save0_rvalue   = csr_save0;
    assign csr_save1_rvalue   = csr_save1;
    assign csr_save2_rvalue   = csr_save2;
    assign csr_save3_rvalue   = csr_save3;
    assign csr_tid_rvalue     = csr_tid;
    assign csr_tcfg_rvalue    = csr_tcfg;
    assign csr_tval_rvalue    = csr_tval;
    assign csr_ticlr_rvalue   = 32'b0;
    assign csr_llbctl_rvalue  = {29'b0, csr_llbctl[2], 1'b0, csr_llbctl[1:0]};
    assign csr_tlbrentry_rvalue = {csr_tlbrentry[31:6], 6'b0};
    assign csr_ctag_rvalue    = 32'b0;  // 占位
    assign csr_dmw0_rvalue    = {csr_dmw0[31:29], 1'b0, csr_dmw0[27:25], 19'b0, csr_dmw0[5:3], 2'b0, csr_dmw0[0]};
    assign csr_dmw1_rvalue    = {csr_dmw1[31:29], 1'b0, csr_dmw1[27:25], 19'b0, csr_dmw1[5:3], 2'b0, csr_dmw1[0]};

    // ========== CSR 读操作（按CSR号选择对应读值） ==========
    assign csr_rvalue = ({32{csr_id_num == `CSR_CRMD}}      & csr_crmd_rvalue)
                      | ({32{csr_id_num == `CSR_PRMD}}      & csr_prmd_rvalue)
                      | ({32{csr_id_num == `CSR_EUEN}}      & csr_euen_rvalue)
                      | ({32{csr_id_num == `CSR_ECFG}}      & csr_ecfg_rvalue)
                      | ({32{csr_id_num == `CSR_ESTAT}}     & csr_estat_rvalue)
                      | ({32{csr_id_num == `CSR_ERA}}       & csr_era_rvalue)
                      | ({32{csr_id_num == `CSR_BADV}}      & csr_badv_rvalue)
                      | ({32{csr_id_num == `CSR_EENTRY}}    & csr_eentry_rvalue)
                      | ({32{csr_id_num == `CSR_TLBIDX}}    & csr_tlbidx_rvalue)
                      | ({32{csr_id_num == `CSR_TLBEHI}}    & csr_tlbehi_rvalue)
                      | ({32{csr_id_num == `CSR_TLBELO0}}   & csr_tlbelo0_rvalue)
                      | ({32{csr_id_num == `CSR_TLBELO1}}   & csr_tlbelo1_rvalue)
                      | ({32{csr_id_num == `CSR_ASID}}      & csr_asid_rvalue)
                      | ({32{csr_id_num == `CSR_PGDL}}      & csr_pgdl_rvalue)
                      | ({32{csr_id_num == `CSR_PGDH}}      & csr_pgdh_rvalue)
                      | ({32{csr_id_num == `CSR_PGD}}       & csr_pgd_rvalue)
                      | ({32{csr_id_num == `CSR_CPUID}}     & csr_cpuid_rvalue)
                      | ({32{csr_id_num == `CSR_SAVE0}}     & csr_save0_rvalue)
                      | ({32{csr_id_num == `CSR_SAVE1}}     & csr_save1_rvalue)
                      | ({32{csr_id_num == `CSR_SAVE2}}     & csr_save2_rvalue)
                      | ({32{csr_id_num == `CSR_SAVE3}}     & csr_save3_rvalue)
                      | ({32{csr_id_num == `CSR_TID}}       & csr_tid_rvalue)
                      | ({32{csr_id_num == `CSR_TCFG}}      & csr_tcfg_rvalue)
                      | ({32{csr_id_num == `CSR_TVAL}}      & csr_tval_rvalue)
                      | ({32{csr_id_num == `CSR_TICLR}}     & csr_ticlr_rvalue)
                      | ({32{csr_id_num == `CSR_LLBCTL}}    & csr_llbctl_rvalue)
                      | ({32{csr_id_num == `CSR_TLBRENTRY}} & csr_tlbrentry_rvalue)
                      | ({32{csr_id_num == `CSR_CTAG}}      & csr_ctag_rvalue)
                      | ({32{csr_id_num == `CSR_DMW0}}      & csr_dmw0_rvalue)
                      | ({32{csr_id_num == `CSR_DMW1}}      & csr_dmw1_rvalue);

    // ============================================================
    // CRMD 写操作（写 PLV、IE）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_crmd[`CSR_CRMD_PLV]  <= 2'b0;
            csr_crmd[`CSR_CRMD_IE]   <= 1'b0;
            csr_crmd[`CSR_CRMD_DA]   <= 1'b1;
            csr_crmd[`CSR_CRMD_PG]   <= 1'b0;
            csr_crmd[`CSR_CRMD_DATF] <= 2'b00;  // 占位
            csr_crmd[`CSR_CRMD_DATM] <= 2'b00;  // 占位
        end
        else if (wb_exc_valid) begin
            csr_crmd[`CSR_CRMD_PLV] <= 2'b0;
            csr_crmd[`CSR_CRMD_IE]  <= 1'b0;
            if (wb_exc_ecode == `ECODE_TLBR) begin
                csr_crmd[`CSR_CRMD_DA] <= 1'b1;
                csr_crmd[`CSR_CRMD_PG] <= 1'b0;
            end
        end
        else if (wb_ertn_flush) begin
            csr_crmd[`CSR_CRMD_PLV] <= csr_prmd[`CSR_PRMD_PPLV];
            csr_crmd[`CSR_CRMD_IE]  <= csr_prmd[`CSR_PRMD_PIE];
            if (csr_estat[`CSR_ESTAT_ECODE] == `ECODE_TLBR) begin
                csr_crmd[`CSR_CRMD_DA] <= 1'b0;
                csr_crmd[`CSR_CRMD_PG] <= 1'b1;
            end
        end
        else if (csr_we && csr_num == `CSR_CRMD) begin
            csr_crmd <= (csr_wmask & csr_wvalue & 32'h1ff)
                      | (~csr_wmask & csr_crmd);
        end
    end

    // ============================================================
    // PRMD 写操作（写 PPLV、PIE）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_prmd[`CSR_PRMD_PPLV] <= 2'b0;
            csr_prmd[`CSR_PRMD_PIE]  <= 1'b0;
        end
        else if (wb_exc_valid) begin
            csr_prmd[`CSR_PRMD_PPLV] <= csr_crmd[`CSR_CRMD_PLV];
            csr_prmd[`CSR_PRMD_PIE]  <= csr_crmd[`CSR_CRMD_IE];
        end
        else if (csr_we && csr_num == `CSR_PRMD) begin
            csr_prmd <= (csr_wmask & csr_wvalue & 32'h3)
                      | (~csr_wmask & csr_prmd);
        end
    end

    // ============================================================
    // EUEN 写操作（占位）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_euen[`CSR_EUEN_FPE] <= 1'b1;
        end
    end

    // ============================================================
    // ECFG 写操作（写 LIE）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_ecfg[`CSR_ECFG_LIE] <= 13'b0;
        end
        else if (csr_we && csr_num == `CSR_ECFG) begin
            csr_ecfg[10] <= 1'b0;
            csr_ecfg[9:0] <= (csr_wmask[9:0] & csr_wvalue[9:0])
                           | (~csr_wmask[9:0] & csr_ecfg[9:0]);
            csr_ecfg[12:11] <= (csr_wmask[12:11] & csr_wvalue[12:11])
                             | (~csr_wmask[12:11] & csr_ecfg[12:11]);
        end
    end

    // ============================================================
    // ESTAT 写操作（写 IS、Ecode、EsubCode）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_estat <= 32'b0;
        end
        else if (csr_we && csr_num == `CSR_ESTAT) begin
            csr_estat[`CSR_ESTAT_IS10] <= (csr_wmask[`CSR_ESTAT_IS10] & csr_wvalue[`CSR_ESTAT_IS10])
                                        | (~csr_wmask[`CSR_ESTAT_IS10] & csr_estat[`CSR_ESTAT_IS10]);
        end

        // 以下逻辑与 reset 分支并行（非 reset 时执行）
        if (!reset) begin
            csr_estat[`CSR_ESTAT_IS92] <= hw_inter_num[7:0];
            csr_estat[10] <= 1'b0;
        end

        if (csr_we && csr_num == `CSR_TICLR && csr_wmask[`CSR_TICLR_CLR]
                   && csr_wvalue[`CSR_TICLR_CLR])
            csr_estat[11] <= 1'b0;
        else if (timer_inter)
            csr_estat[11] <= 1'b1;

        csr_estat[12] <= ipi_inter;
    end

    assign timer_inter = (csr_tval == 32'b0) && csr_tcfg[`CSR_TCFG_EN];

    // Ecode、EsubCode
    always @(posedge clk) begin
        if (reset) begin
            csr_estat[`CSR_ESTAT_ECODE]    <= 6'b0;
            csr_estat[`CSR_ESTAT_ESUBCODE] <= 9'b0;
        end
        else if (wb_exc_valid) begin
            csr_estat[`CSR_ESTAT_ECODE]    <= wb_exc_ecode;
            csr_estat[`CSR_ESTAT_ESUBCODE] <= wb_exc_esubcode;
        end
    end

    // ============================================================
    // ERA 写操作（写 PC）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_era <= 32'b0;
        end
        else if (wb_exc_valid) begin
            csr_era <= wb_exc_pc;
        end
        else if (csr_we && csr_num == `CSR_ERA) begin
            csr_era <= (csr_wmask & csr_wvalue)
                     | (~csr_wmask & csr_era);
        end
    end

    // ============================================================
    // BADV 写操作（写 VADDR）
    // ============================================================
    assign wb_exc_badv_err = (wb_exc_ecode == `ECODE_ADE && wb_exc_esubcode == `ESUBCODE_ADEF)
                          || (wb_exc_ecode == `ECODE_ALE)
                          || (wb_exc_ecode == `ECODE_TLBR)
                          || (wb_exc_ecode == `ECODE_PIL)
                          || (wb_exc_ecode == `ECODE_PIS)
                          || (wb_exc_ecode == `ECODE_PIF)
                          || (wb_exc_ecode == `ECODE_PME)
                          || (wb_exc_ecode == `ECODE_PPI);

    always @(posedge clk) begin
        if (reset) begin
            csr_badv <= 32'b0;
        end
        else if (wb_exc_valid && wb_exc_badv_err) begin
            csr_badv <= (wb_exc_ecode == `ECODE_ADE
                         && wb_exc_esubcode == `ESUBCODE_ADEF) ? wb_exc_pc : wb_exc_badv;
        end
    end

    // ============================================================
    // EENTRY 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_eentry[`CSR_EENTRY_VA] <= 26'b0;
        end
        else if (csr_we && csr_num == `CSR_EENTRY) begin
            csr_eentry[`CSR_EENTRY_VA] <= (csr_wmask[`CSR_EENTRY_VA] & csr_wvalue[`CSR_EENTRY_VA])
                                        | (~csr_wmask[`CSR_EENTRY_VA] & csr_eentry[`CSR_EENTRY_VA]);
        end
    end

    // ============================================================
    // CPUID 写操作（占位）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_cpuid[`CSR_CPUID_COREID] <= coreid_in;
        end
    end

    // ============================================================
    // SAVE0~3 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_save0 <= 32'b0;
            csr_save1 <= 32'b0;
            csr_save2 <= 32'b0;
            csr_save3 <= 32'b0;
        end
        else if (csr_we && csr_num == `CSR_SAVE0) begin
            csr_save0 <= (csr_wmask & csr_wvalue)
                       | (~csr_wmask & csr_save0);
        end
        else if (csr_we && csr_num == `CSR_SAVE1) begin
            csr_save1 <= (csr_wmask & csr_wvalue)
                       | (~csr_wmask & csr_save1);
        end
        else if (csr_we && csr_num == `CSR_SAVE2) begin
            csr_save2 <= (csr_wmask & csr_wvalue)
                       | (~csr_wmask & csr_save2);
        end
        else if (csr_we && csr_num == `CSR_SAVE3) begin
            csr_save3 <= (csr_wmask & csr_wvalue)
                       | (~csr_wmask & csr_save3);
        end
    end

    // ============================================================
    // LLBCTL 写操作（占位）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_llbctl[`CSR_LLBCTL_KLO] <= 1'b0;
        end
    end

    // ============================================================
    // TLBIDX 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tlbidx <= 32'h80000000;
        end
        else if (tlbrd_en) begin
            csr_tlbidx[`CSR_TLBIDX_NE] <= tlbrd_tlbidx_ne;
            csr_tlbidx[`CSR_TLBIDX_PS] <= tlbrd_tlbidx_ps;
        end
        else if (csr_we && csr_num == `CSR_TLBIDX) begin
            csr_tlbidx <= (csr_wmask & csr_wvalue & 32'hbf00001f)
                        | (~csr_wmask & csr_tlbidx);
        end
    end

    // ============================================================
    // TLBEHI 写操作
    // ============================================================
    assign wb_exc_ehi_err = (wb_exc_ecode == `ECODE_TLBR)
                         || (wb_exc_ecode == `ECODE_PIL)
                         || (wb_exc_ecode == `ECODE_PIS)
                         || (wb_exc_ecode == `ECODE_PIF)
                         || (wb_exc_ecode == `ECODE_PME)
                         || (wb_exc_ecode == `ECODE_PPI);

    always @(posedge clk) begin
        if (reset) begin
            csr_tlbehi <= 32'b0;
        end
        else if (wb_exc_valid && wb_exc_ehi_err) begin
            csr_tlbehi[`CSR_TLBEHI_VPPN] <= wb_exc_badv[`CSR_TLBEHI_VPPN];
        end
        else if (tlbrd_en) begin
            csr_tlbehi[`CSR_TLBEHI_VPPN] <= tlbrd_tlbehi;
        end
        else if (csr_we && csr_num == `CSR_TLBEHI) begin
            csr_tlbehi[`CSR_TLBEHI_VPPN] <= (csr_wmask[`CSR_TLBEHI_VPPN] & csr_wvalue[`CSR_TLBEHI_VPPN])
                                          | (~csr_wmask[`CSR_TLBEHI_VPPN] & csr_tlbehi[`CSR_TLBEHI_VPPN]);
        end
    end

    // ============================================================
    // TLBELO0~1 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tlbelo0 <= 32'b0;
            csr_tlbelo1 <= 32'b0;
        end
        else if (tlbrd_en) begin
            csr_tlbelo0 <= tlbrd_tlbelo0 & 32'h0fffff7f;
            csr_tlbelo1 <= tlbrd_tlbelo1 & 32'h0fffff7f;
        end
        else if (csr_we && csr_num == `CSR_TLBELO0) begin
            csr_tlbelo0 <= (csr_wmask & csr_wvalue & 32'h0fffff7f)
                         | (~csr_wmask & csr_tlbelo0);
        end
        else if (csr_we && csr_num == `CSR_TLBELO1) begin
            csr_tlbelo1 <= (csr_wmask & csr_wvalue & 32'h0fffff7f)
                         | (~csr_wmask & csr_tlbelo1);
        end
    end

    // ============================================================
    // ASID 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_asid[`CSR_ASID_ASID]     <= 10'b0;
            csr_asid[`CSR_ASID_ASIDBITS] <= 8'd10;
        end
        else if (tlbrd_en) begin
            csr_asid[`CSR_ASID_ASID] <= tlbrd_asid;
        end
        else if (csr_we && csr_num == `CSR_ASID) begin
            csr_asid[`CSR_ASID_ASID] <= (csr_wmask[`CSR_ASID_ASID] & csr_wvalue[`CSR_ASID_ASID])
                                      | (~csr_wmask[`CSR_ASID_ASID] & csr_asid[`CSR_ASID_ASID]);
        end
    end

    // ============================================================
    // TLBRENTRY 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tlbrentry[`CSR_TLBRENTRY_PA] <= 26'b0;
        end
        else if (csr_we && csr_num == `CSR_TLBRENTRY) begin
            csr_tlbrentry[`CSR_TLBRENTRY_PA] <= (csr_wmask[`CSR_TLBRENTRY_PA] & csr_wvalue[`CSR_TLBRENTRY_PA])
                                              | (~csr_wmask[`CSR_TLBRENTRY_PA] & csr_tlbrentry[`CSR_TLBRENTRY_PA]);
        end
    end

    // ============================================================
    // DMW0~1 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_dmw0 <= 32'b0;
            csr_dmw1 <= 32'b0;
        end
        else if (csr_we && csr_num == `CSR_DMW0) begin
            csr_dmw0 <= (csr_wmask & csr_wvalue & 32'hEE000039)
                      | (~csr_wmask & csr_dmw0);
        end
        else if (csr_we && csr_num == `CSR_DMW1) begin
            csr_dmw1 <= (csr_wmask & csr_wvalue & 32'hEE000039)
                      | (~csr_wmask & csr_dmw1);
        end
    end

    // ============================================================
    // TID 写操作
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tid <= coreid_in;
        end
        else if (csr_we && csr_num == `CSR_TID) begin
            csr_tid <= (csr_wmask[`CSR_TID_TID] & csr_wvalue[`CSR_TID_TID])
                     | (~csr_wmask[`CSR_TID_TID] & csr_tid);
        end
    end

    // ============================================================
    // TCFG 写操作（写 EN、Periodic、InitVal）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_tcfg[`CSR_TCFG_EN]       <= 1'b0;
            csr_tcfg[`CSR_TCFG_PERIODIC] <= 1'b0;
            csr_tcfg[`CSR_TCFG_INITVAL]  <= 30'b0;
        end
        else if (csr_we && csr_num == `CSR_TCFG) begin
            csr_tcfg[`CSR_TCFG_EN] <= (csr_wmask[`CSR_TCFG_EN] & csr_wvalue[`CSR_TCFG_EN])
                                    | (~csr_wmask[`CSR_TCFG_EN] & csr_tcfg[`CSR_TCFG_EN]);
            csr_tcfg[`CSR_TCFG_PERIODIC] <= (csr_wmask[`CSR_TCFG_PERIODIC] & csr_wvalue[`CSR_TCFG_PERIODIC])
                                          | (~csr_wmask[`CSR_TCFG_PERIODIC] & csr_tcfg[`CSR_TCFG_PERIODIC]);
            csr_tcfg[`CSR_TCFG_INITVAL] <= (csr_wmask[`CSR_TCFG_INITVAL] & csr_wvalue[`CSR_TCFG_INITVAL])
                                         | (~csr_wmask[`CSR_TCFG_INITVAL] & csr_tcfg[`CSR_TCFG_INITVAL]);
        end
    end

    // ============================================================
    // TVAL 写操作
    // ============================================================
    assign tcfg_next_value = (csr_wmask[31:0] & csr_wvalue[31:0])
                           | (~csr_wmask[31:0] & csr_tcfg);

    always @(posedge clk) begin
        if (reset) begin
            csr_tval <= 32'hffffffff;
        end
        else if (csr_we && csr_num == `CSR_TCFG && tcfg_next_value[`CSR_TCFG_EN]) begin
            csr_tval <= {tcfg_next_value[`CSR_TCFG_INITVAL], 2'b0};
        end
        else if (csr_tcfg[`CSR_TCFG_EN] && csr_tval != 32'hffffffff) begin
            if (csr_tval == 32'b0 && csr_tcfg[`CSR_TCFG_PERIODIC])
                csr_tval <= {csr_tcfg[`CSR_TCFG_INITVAL], 2'b0};
            else
                csr_tval <= csr_tval - 1'b1;
        end
    end

    // ============================================================
    // TICLR 写操作（写 CLR）
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            csr_ticlr <= 32'b0;
        end
    end

    // ========== 中断状态输出给 ID 阶段 ==========
    assign has_int = ((csr_estat[12:0] & csr_ecfg[12:0]) != 13'b0)
                  && (csr_crmd[`CSR_CRMD_IE] == 1'b1);

    // ========== 异常入口地址输出 ==========
    assign exc_entry   = (wb_exc_ecode == `ECODE_TLBR) ? csr_tlbrentry_rvalue : csr_eentry_rvalue;
    assign exc_back_pc = csr_era;

endmodule