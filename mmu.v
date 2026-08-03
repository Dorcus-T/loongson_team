`include "mycpu.h"

module mmu (
    input  wire        clk,
    input  wire        reset,

    // if interact
    input  wire [31:0] vaddr_from_if,
    output wire [19:0] if_tag,         // 物理 tag → ICache，固定 paddr[31:12] 20-bit
    output wire [ 2:0] if_tlb_exc,
    output wire        if_cached,       // IF 访问可缓存
    output wire [31:0] paddr_to_if,     // 完整物理地址

    // id interact
    // ex interact
    input  wire [31:0] vaddr_from_ex,
    input  wire [35:0] vtlb_enop,
    input  wire [ 1:0] ld_and_str,
    output wire [19:0] ex_tag,         // 物理 tag → DCache，固定 paddr[31:12] 20-bit
    output wire [31:0] paddr_to_ex,     // 完整物理地址 → mem_stage
    output wire [ 5:0] srch_value,
    output wire [ 4:0] ex_tlb_exc,
    output wire        ex_cached,       // MEM 访问可缓存

    // mem interact
    // wb interact
    input  wire [ 2:0] tlbrwf_en,

    // csr interact
    input  wire [ 1:0] plv_in,
    input  wire [ 5:0] ecode_in,
    input  wire [ 1:0] dapg_in,
    input  wire [ 1:0] datf_in,         // CRMD.DATF — IF 直接翻译 MAT
    input  wire [ 1:0] datm_in,         // CRMD.DATM — MEM 直接翻译 MAT
    input  wire [63:0] dmw,
    input  wire [`TLBCSR_BUS_WD-1:0] tlbcsr,
    output wire [`TLBRD_BUS_WD-1:0]  tlbrd_value,
    output wire [ 4:0]               tlbfill_rand_index,  // TLBFILL 随机替换 index（for difftest）
    output wire        s0_cancel,       // IF 有 TLB 异常
    output wire        s1_cancel,       // MEM 有 TLB 异常
    output reg         s0_need_mmu_r,   // s0_need_mmu 寄存一拍 → if_stage
    output reg         s1_need_mmu_r,   // s1_need_mmu 寄存一拍 → mem_stage
    input  wire        s0_need_mmu,    // IF 需要 MMU 翻译
    input  wire        s1_need_mmu     // MEM 需要 MMU 翻译
);
    // if decode
    wire [18:0] if_vppn;
    wire        if_va_bit12;
    wire [11:0] if_offset;
    wire [ 2:0] s0_tlb_exc;

    // exe decode
    wire [18:0] ex_vppn;
    wire        ex_va_bit12;
    wire [11:0] ex_offset;
    wire        tlbsrch_en;
    wire        invtlb_en;
    wire [ 4:0] invtlb_opcode;
    wire [ 9:0] invtlb_asid;
    wire [18:0] invtlb_vppn;
    wire        load;
    wire        store;
    wire [ 4:0] s1_tlb_exc;

    // wb decode
    wire        tlbrd_en;
    wire        tlbwr_en;
    wire        tlbfill_en;

    // csr decode
    wire [ 1:0] plv;
    wire [ 5:0] ecode;
    wire [ 1:0] dapg;
    wire [31:0] dmw0;
    wire [31:0] dmw1;
    wire [31:0] tlbidx;
    wire [31:0] tlbehi;
    wire [31:0] tlbelo0;
    wire [31:0] tlbelo1;
    wire [31:0] asid;

    // ========== tlb io ==========
    // s0 io
    wire [18:0] s0_vppn;
    wire        s0_va_bit12;
    wire [ 9:0] s0_asid;
    wire        s0_found;
    wire [ 4:0] s0_index;
    wire [19:0] s0_ppn;
    wire [ 5:0] s0_ps;
    wire [ 1:0] s0_plv;
    wire [ 1:0] s0_mat;
    wire        s0_d;
    wire        s0_v;

    // s1 io
    wire [18:0] s1_vppn;
    wire        s1_va_bit12;
    wire [ 9:0] s1_asid;
    wire        s1_found;
    wire [ 4:0] s1_index;
    wire [19:0] s1_ppn;
    wire [ 5:0] s1_ps;
    wire [ 1:0] s1_plv;
    wire [ 1:0] s1_mat;
    wire        s1_d;
    wire        s1_v;

    // invtlb opcode
    wire        invtlb_valid;
    wire [ 4:0] invtlb_op;

    // write
    wire        we;
    wire [ 4:0] w_index;
    wire        w_e;
    wire [18:0] w_vppn;
    wire [ 5:0] w_ps;
    wire [ 9:0] w_asid;
    wire        w_g;
    wire [19:0] w_ppn0;
    wire [ 1:0] w_plv0;
    wire [ 1:0] w_mat0;
    wire        w_d0;
    wire        w_v0;
    wire [19:0] w_ppn1;
    wire [ 1:0] w_plv1;
    wire [ 1:0] w_mat1;
    wire        w_d1;
    wire        w_v1;

    // read
    wire [ 4:0] r_index;
    wire        r_e;
    wire [18:0] r_vppn;
    wire [ 5:0] r_ps;
    wire [ 9:0] r_asid;
    wire        r_g;
    wire [19:0] r_ppn0;
    wire [ 1:0] r_plv0;
    wire [ 1:0] r_mat0;
    wire        r_d0;
    wire        r_v0;
    wire [19:0] r_ppn1;
    wire [ 1:0] r_plv1;
    wire [ 1:0] r_mat1;
    wire        r_d1;
    wire        r_v1;

    // random number generate
    reg  [ 4:0] rand_index;

    // dmw match
    wire [ 1:0] if_match;
    wire [ 1:0] ex_match;

    //实例化tlb
    tlb #(
        .TLBNUM(32)
    ) u_tlb (
        .clk            (clk            ),
        .reset          (reset          ),

        .s0_vppn        (s0_vppn        ),
        .s0_va_bit12    (s0_va_bit12    ),
        .s0_asid        (s0_asid        ),
        .s0_found       (s0_found       ),
        .s0_index       (s0_index       ),
        .s0_ppn         (s0_ppn         ),
        .s0_ps          (s0_ps          ),
        .s0_plv         (s0_plv         ),
        .s0_mat         (s0_mat         ),
        .s0_d           (s0_d           ),
        .s0_v           (s0_v           ),

        .s1_vppn        (s1_vppn        ),
        .s1_va_bit12    (s1_va_bit12    ),
        .s1_asid        (s1_asid        ),
        .s1_found       (s1_found       ),
        .s1_index       (s1_index       ),
        .s1_ppn         (s1_ppn         ),
        .s1_ps          (s1_ps          ),
        .s1_plv         (s1_plv         ),
        .s1_mat         (s1_mat         ),
        .s1_d           (s1_d           ),
        .s1_v           (s1_v           ),

        .invtlb_valid   (invtlb_valid   ),
        .invtlb_op      (invtlb_op      ),

        .we             (we             ),
        .w_index        (w_index        ),
        .w_e            (w_e            ),
        .w_vppn         (w_vppn         ),
        .w_ps           (w_ps           ),
        .w_asid         (w_asid         ),
        .w_g            (w_g            ),
        .w_ppn0         (w_ppn0         ),
        .w_plv0         (w_plv0         ),
        .w_mat0         (w_mat0         ),
        .w_d0           (w_d0           ),
        .w_v0           (w_v0           ),
        .w_ppn1         (w_ppn1         ),
        .w_plv1         (w_plv1         ),
        .w_mat1         (w_mat1         ),
        .w_d1           (w_d1           ),
        .w_v1           (w_v1           ),

        .r_index        (r_index        ),
        .r_e            (r_e            ),
        .r_vppn         (r_vppn         ),
        .r_ps           (r_ps           ),
        .r_asid         (r_asid         ),
        .r_g            (r_g            ),
        .r_ppn0         (r_ppn0         ),
        .r_plv0         (r_plv0         ),
        .r_mat0         (r_mat0         ),
        .r_d0           (r_d0           ),
        .r_v0           (r_v0           ),
        .r_ppn1         (r_ppn1         ),
        .r_plv1         (r_plv1         ),
        .r_mat1         (r_mat1         ),
        .r_d1           (r_d1           ),
        .r_v1           (r_v1           )
    );

    // random index gen
    always @(posedge clk) begin
        if (reset) begin
            rand_index <= 0;
        end
        else begin
            rand_index <= rand_index + 1'b1;
        end
    end

    // 判断是否需要 TLB 翻译，寄存一拍后过滤异常码
    wire s0_need_tlb;
    wire s1_need_tlb;
    assign s0_need_tlb = (dapg == 2'b01) && (if_match == 2'b00) && s0_need_mmu;
    assign s1_need_tlb = (dapg == 2'b01) && (ex_match == 2'b00) && s1_need_mmu;

    reg s0_need_tlb_r;
    reg s1_need_tlb_r;
    reg [ 1:0] plv_r;
    reg        load_r;
    reg        store_r;
    always @(posedge clk) begin
        if (reset) begin
            s0_need_tlb_r  <= 1'b0;
            s1_need_tlb_r  <= 1'b0;
            plv_r          <= 2'd0;
            load_r         <= 1'b0;
            store_r        <= 1'b0;
            s0_need_mmu_r  <= 1'b0;
            s1_need_mmu_r  <= 1'b0;
        end
        else begin
            s0_need_tlb_r  <= s0_need_tlb;
            s1_need_tlb_r  <= s1_need_tlb;
            plv_r          <= plv;
            load_r         <= load;
            store_r        <= store;
            s0_need_mmu_r  <= s0_need_mmu;
            s1_need_mmu_r  <= s1_need_mmu;
        end
    end

    assign tlbfill_rand_index = rand_index;

    // ================================================================
    // 统一 1 拍流水：寄存虚地址 + DMW 匹配，对齐 TLB 1 拍输出
    // ================================================================
    reg [31:0] if_vaddr_r;
    reg [31:0] ex_vaddr_r;
    always @(posedge clk) begin
        if (reset) begin
            if_vaddr_r <= 32'b0;
            ex_vaddr_r <= 32'b0;
        end
        else begin
            if_vaddr_r <= vaddr_from_if;
            ex_vaddr_r <= vaddr_from_ex;
        end
    end

    // dmw命中判定
    assign if_match[0] = vaddr_from_if[31:29] == dmw0[`CSR_DMW_VSEG]
                     && (plv == 2'b0 && dmw0[`CSR_DMW_PLV0] || plv == 2'b11 && dmw0[`CSR_DMW_PLV3]);
    assign if_match[1] = vaddr_from_if[31:29] == dmw1[`CSR_DMW_VSEG]
                     && (plv == 2'b0 && dmw1[`CSR_DMW_PLV0] || plv == 2'b11 && dmw1[`CSR_DMW_PLV3]);
    assign ex_match[0] = vaddr_from_ex[31:29] == dmw0[`CSR_DMW_VSEG]
                     && (plv == 2'b0 && dmw0[`CSR_DMW_PLV0] || plv == 2'b11 && dmw0[`CSR_DMW_PLV3]);
    assign ex_match[1] = vaddr_from_ex[31:29] == dmw1[`CSR_DMW_VSEG]
                     && (plv == 2'b0 && dmw1[`CSR_DMW_PLV0] || plv == 2'b11 && dmw1[`CSR_DMW_PLV3]);

    // if logic
    assign {if_vppn, if_va_bit12, if_offset} = vaddr_from_if;
    assign s0_vppn     = if_vppn;
    assign s0_va_bit12 = if_va_bit12;
    assign s0_asid     = asid[`CSR_ASID_ASID];

    // s0 TLB 异常检测 — 优先级编码
    // 优先级: PPF(2) > PIL(1) > PPL(0)
    wire s0_exc_ppf;  // Page Fault (not found)
    wire s0_exc_pil;  // Page Invalid (Load / Fetch)
    wire s0_exc_ppl;  // Privilege Violation

    assign s0_exc_ppf = (s0_found == 1'b0);
    assign s0_exc_pil = (s0_v == 1'b0);
    assign s0_exc_ppl = (plv_r > s0_plv);

    assign s0_tlb_exc = s0_exc_ppf ? 3'b100 :
                        s0_exc_pil ? 3'b010 :
                        s0_exc_ppl ? 3'b001 : 3'b000;

    // ---------- IF 输出：统一 1 拍 ----------
    // 第一拍：DMW/直翻结果（组合），寄存
    // 第二拍：s0_need_tlb_r 选 TLB 还是寄存的 DMW
    assign if_tlb_exc = s0_tlb_exc & {3{s0_need_tlb_r}};
    assign s0_cancel  = |if_tlb_exc;

    wire [1:0] if_mat_dmw_comb;
    wire [31:0] paddr_if_dmw_comb;
    assign if_mat_dmw_comb = (dapg == 2'b10) ? datf_in                :
                             if_match[0]     ? dmw0[`CSR_DMW_MAT]     :
                             if_match[1]     ? dmw1[`CSR_DMW_MAT]     :
                                               2'b00;  // unreachable
    assign paddr_if_dmw_comb = (dapg == 2'b10) ? vaddr_from_if                              :
                               if_match[0]     ? {dmw0[`CSR_DMW_PSEG], vaddr_from_if[28:0]} :
                               if_match[1]     ? {dmw1[`CSR_DMW_PSEG], vaddr_from_if[28:0]} :
                                                  32'b0;

    reg  [ 1:0] if_mat_dmw_r;
    reg  [31:0] paddr_if_dmw_r;
    always @(posedge clk) begin
        if (reset) begin
            if_mat_dmw_r   <= 2'd0;
            paddr_if_dmw_r <= 32'b0;
        end
        else begin
            if_mat_dmw_r   <= if_mat_dmw_comb;
            paddr_if_dmw_r <= paddr_if_dmw_comb;
        end
    end

    assign if_cached = ((s0_need_tlb_r ? s0_mat : if_mat_dmw_r) == 2'b01);

    // 展平 tag MUX：高位 ppn 统一，低位按 page size 选，消除两级 MUX
    wire        ps_is_4mb = (s0_ps == 6'd21);
    wire [19:0] if_tag_tlb;
    assign if_tag_tlb[19:10] = s0_ppn[19:10];
    assign if_tag_tlb[ 9: 0] = ps_is_4mb ? if_vaddr_r[21:12] : s0_ppn[9:0];
    assign if_tag = s0_need_tlb_r ? if_tag_tlb : paddr_if_dmw_r[31:12];

    // paddr_to_if 仅 MEM/difftest 使用，非关键路径，保持完整 paddr
    wire [31:0] paddr_if_tlb;
    assign paddr_if_tlb = (s0_ps == 6'd12) ? {s0_ppn[19:0], if_vaddr_r[11:0]}  :
                          (s0_ps == 6'd21) ? {s0_ppn[19:10], if_vaddr_r[21:0]} :
                                             32'b0;
    wire [31:0] paddr_if;
    assign paddr_if    = s0_need_tlb_r ? paddr_if_tlb : paddr_if_dmw_r;
    assign paddr_to_if = paddr_if;

    // ex logic
    assign {ex_vppn, ex_va_bit12, ex_offset} = vaddr_from_ex;
    assign {tlbsrch_en, invtlb_en, invtlb_opcode, invtlb_asid, invtlb_vppn} = vtlb_enop;
    assign {load, store} = ld_and_str;
    assign s1_vppn     = tlbsrch_en ? tlbehi[`CSR_TLBEHI_VPPN] : invtlb_en ? invtlb_vppn : ex_vppn;
    assign s1_va_bit12 = ex_va_bit12;
    assign s1_asid     = invtlb_en ? invtlb_asid : asid[`CSR_ASID_ASID];

    // s1 TLB 异常检测 — 优先级编码
    // 优先级: PPE(4) > PPL(3) > PIL(2) > PIS(1) > PME(0)
    wire exc_ppe;  // Page Fault (not found)
    wire exc_ppl;  // Privilege Violation
    wire exc_pil;  // Page Invalid (Load)
    wire exc_pis;  // Page Invalid (Store)
    wire exc_pme;  // Page Modified (Dirty=0, Store)

    assign exc_ppe = s1_found == 1'b0;
    assign exc_ppl = plv_r > s1_plv;
    assign exc_pil = load_r  && !s1_v;
    assign exc_pis = store_r && !s1_v;
    assign exc_pme = store_r && !s1_d;

    assign s1_tlb_exc = exc_ppe ? 5'b10000 :
                        exc_ppl ? 5'b01000 :
                        exc_pil ? 5'b00100 :
                        exc_pis ? 5'b00010 :
                        exc_pme ? 5'b00001 : 5'b00000;
    // ---------- MEM 输出：统一 1 拍 ----------
    assign ex_tlb_exc = s1_tlb_exc & {5{s1_need_tlb_r}};
    assign s1_cancel  = |ex_tlb_exc;

    wire [ 1:0] ex_mat_dmw_comb;
    wire [31:0] paddr_ex_dmw_comb;
    assign ex_mat_dmw_comb = (dapg == 2'b10) ? datm_in                :
                             ex_match[0]     ? dmw0[`CSR_DMW_MAT]     :
                             ex_match[1]     ? dmw1[`CSR_DMW_MAT]     :
                                               2'b00;
    assign paddr_ex_dmw_comb = tlbsrch_en || invtlb_en ? 32'b0                                      :
                               dapg == 2'b10           ? vaddr_from_ex                              :
                               ex_match[0]             ? {dmw0[`CSR_DMW_PSEG], vaddr_from_ex[28:0]} :
                               ex_match[1]             ? {dmw1[`CSR_DMW_PSEG], vaddr_from_ex[28:0]} :
                                                         32'b0;

    reg  [ 1:0] ex_mat_dmw_r;
    reg  [31:0] paddr_ex_dmw_r;
    always @(posedge clk) begin
        if (reset) begin
            ex_mat_dmw_r   <= 2'd0;
            paddr_ex_dmw_r <= 32'b0;
        end
        else begin
            ex_mat_dmw_r   <= ex_mat_dmw_comb;
            paddr_ex_dmw_r <= paddr_ex_dmw_comb;
        end
    end

    assign ex_cached = ((s1_need_tlb_r ? s1_mat : ex_mat_dmw_r) == 2'b01);

    // 展平 s1 tag MUX（同 s0）：高位 ppn 统一，低位按 page size 选
    wire        s1_ps_is_4mb = (s1_ps == 6'd21);
    wire [19:0] ex_tag_tlb;
    assign ex_tag_tlb[19:10] = s1_ppn[19:10];
    assign ex_tag_tlb[ 9: 0] = s1_ps_is_4mb ? ex_vaddr_r[21:12] : s1_ppn[9:0];
    assign ex_tag = s1_need_tlb_r ? ex_tag_tlb : paddr_ex_dmw_r[31:12];

    // paddr_to_ex 仅 MEM/difftest 使用，非关键路径，保持完整 paddr
    wire [31:0] paddr_ex;
    wire [31:0] paddr_ex_tlb;
    assign paddr_ex_tlb = (s1_ps == 6'd12) ? {s1_ppn[19:0], ex_vaddr_r[11:0]}  :
                          (s1_ps == 6'd21) ? {s1_ppn[19:10], ex_vaddr_r[21:0]} :
                                             32'b0;
    assign paddr_ex    = s1_need_tlb_r ? paddr_ex_tlb : paddr_ex_dmw_r;
    assign paddr_to_ex = paddr_ex;
    assign srch_value    = {s1_found, s1_index};
    assign invtlb_valid  = invtlb_en;
    assign invtlb_op     = invtlb_opcode;

    // write and read logic
    assign {tlbrd_en, tlbwr_en, tlbfill_en} = tlbrwf_en;
    assign plv   = plv_in;
    assign ecode = ecode_in;
    assign dapg  = dapg_in;
    assign {dmw0, dmw1} = dmw;
    assign {tlbidx, tlbelo0, tlbelo1, asid, tlbehi} = tlbcsr;

    assign r_index = tlbidx[`CSR_TLBIDX_INDEX];
    assign tlbrd_value = r_e ?
                        {tlbrd_en,
                         r_ps,
                         1'b0,
                         r_vppn,
                         4'b0, r_ppn0, 1'b0, r_g, r_mat0, r_plv0, r_d0, r_v0,
                         4'b0, r_ppn1, 1'b0, r_g, r_mat1, r_plv1, r_d1, r_v1,
                         r_asid} :
                        {tlbrd_en, 6'b0, 1'b1, 93'b0};
    assign we       = tlbwr_en || tlbfill_en;
    assign w_index  = tlbwr_en ? tlbidx[`CSR_TLBIDX_INDEX] : rand_index;
    assign w_e      = ecode == `ECODE_TLBR ? 1'b1 : ~tlbidx[`CSR_TLBIDX_NE];
    assign w_vppn   = tlbehi[`CSR_TLBEHI_VPPN];
    assign w_ps     = tlbidx[`CSR_TLBIDX_PS];
    assign w_asid   = asid[`CSR_ASID_ASID];
    assign w_g      = tlbelo0[`CSR_TLBELO_G] && tlbelo1[`CSR_TLBELO_G];
    assign w_v0     = tlbelo0[`CSR_TLBELO_V];
    assign w_d0     = tlbelo0[`CSR_TLBELO_D];
    assign w_plv0   = tlbelo0[`CSR_TLBELO_PLV];
    assign w_mat0   = tlbelo0[`CSR_TLBELO_MAT];
    assign w_ppn0   = tlbelo0[`CSR_TLBELO_PPN];
    assign w_v1     = tlbelo1[`CSR_TLBELO_V];
    assign w_d1     = tlbelo1[`CSR_TLBELO_D];
    assign w_plv1   = tlbelo1[`CSR_TLBELO_PLV];
    assign w_mat1   = tlbelo1[`CSR_TLBELO_MAT];
    assign w_ppn1   = tlbelo1[`CSR_TLBELO_PPN];

endmodule