`include "mycpu.h"

module mmu (
    input  wire        clk,
    input  wire        reset,

    // if interact
    input  wire [31:0] vaddr_from_if,
    output wire [31:0] paddr_to_if,
    output wire [ 2:0] if_tlb_exc,
    output wire [ 1:0] if_mat,
    output wire         if_cached,       // IF 访问可缓存（MAT==1）

    // id interact
    // ex interact
    input  wire [31:0] vaddr_from_ex,
    input  wire [35:0] vtlb_enop,
    input  wire [ 1:0] ld_and_str,
    output wire [31:0] paddr_to_ex,
    output wire [ 5:0] srch_value,
    output wire [ 4:0] ex_tlb_exc,
    output wire [ 1:0] ex_mat,
    output wire         ex_cached,       // EX 访问可缓存（MAT==1）

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

    // pre_mem 访存 TLB 查询控制
    output wire         mem_tlb_req,    // 访存需要查 TLB 页表（页表翻译模式 && DMW 未命中）
    output wire         utlb_hit        // μTLB 命中（发 pre_mem_stage，跳过 tlb_wait）
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

    // s1 io — 大 TLB 输出（已寄存）
    wire [18:0] s1_vppn;
    wire        s1_va_bit12;
    wire [ 9:0] s1_asid;
    wire        tlb_s1_found;
    wire [ 4:0] tlb_s1_index;
    wire [19:0] tlb_s1_ppn;
    wire [ 5:0] tlb_s1_ps;
    wire [ 1:0] tlb_s1_plv;
    wire [ 1:0] tlb_s1_mat;
    wire        tlb_s1_d;
    wire        tlb_s1_v;
    wire [19:0] tlb_s1_ppn0;
    wire [19:0] tlb_s1_ppn1;
    wire [ 1:0] tlb_s1_plv0;
    wire [ 1:0] tlb_s1_plv1;
    wire [ 1:0] tlb_s1_mat0;
    wire [ 1:0] tlb_s1_mat1;
    wire        tlb_s1_d0;
    wire        tlb_s1_d1;
    wire        tlb_s1_v0;
    wire        tlb_s1_v1;

    // μTLB 输出（组合逻辑）
    wire        utlb_found;
    wire [ 1:0] utlb_index;
    wire [19:0] utlb_ppn;
    wire [ 5:0] utlb_ps;
    wire [ 1:0] utlb_plv;
    wire [ 1:0] utlb_mat;
    wire        utlb_d;
    wire        utlb_v;

    // 最终选源: μTLB 命中 → μTLB, 否则 → 大 TLB（TLBSRCH/INVTLB 强制走大 TLB）
    wire        s1_found;
    wire [ 4:0] s1_index;
    wire [19:0] s1_ppn;
    wire [ 5:0] s1_ps;
    wire [ 1:0] s1_plv;
    wire [ 1:0] s1_mat;
    wire        s1_d;
    wire        s1_v;

    assign utlb_hit    = utlb_found && !tlbsrch_en && !invtlb_en;
    assign s1_found    = utlb_hit ? 1'b1      : tlb_s1_found;
    assign s1_index    = tlb_s1_index;  // 始终用大 TLB index（TLBSRCH 需要）
    assign s1_ppn      = utlb_hit ? utlb_ppn   : tlb_s1_ppn;
    assign s1_ps       = utlb_hit ? utlb_ps    : tlb_s1_ps;
    assign s1_plv      = utlb_hit ? utlb_plv   : tlb_s1_plv;
    assign s1_mat      = utlb_hit ? utlb_mat   : tlb_s1_mat;
    assign s1_d        = utlb_hit ? utlb_d     : tlb_s1_d;
    assign s1_v        = utlb_hit ? utlb_v     : tlb_s1_v;

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
        .s1_found       (tlb_s1_found   ),
        .s1_index       (tlb_s1_index   ),
        .s1_ppn         (tlb_s1_ppn     ),
        .s1_ps          (tlb_s1_ps      ),
        .s1_plv         (tlb_s1_plv     ),
        .s1_mat         (tlb_s1_mat     ),
        .s1_d           (tlb_s1_d       ),
        .s1_v           (tlb_s1_v       ),
        .s1_ppn0        (tlb_s1_ppn0    ),
        .s1_ppn1        (tlb_s1_ppn1    ),
        .s1_plv0        (tlb_s1_plv0    ),
        .s1_plv1        (tlb_s1_plv1    ),
        .s1_mat0        (tlb_s1_mat0    ),
        .s1_mat1        (tlb_s1_mat1    ),
        .s1_d0          (tlb_s1_d0      ),
        .s1_d1          (tlb_s1_d1      ),
        .s1_v0          (tlb_s1_v0      ),
        .s1_v1          (tlb_s1_v1      ),

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

    // ============================================================
    // μTLB（4 项全相联，组合查找，同拍命中）
    // ============================================================
    // 回填写端口
    wire        utlb_we;
    wire [ 1:0] utlb_w_index;
    wire [18:0] utlb_w_vppn;
    wire [ 5:0] utlb_w_ps;
    wire [ 9:0] utlb_w_asid;
    wire        utlb_w_g;
    wire [19:0] utlb_w_ppn0;
    wire [ 1:0] utlb_w_plv0;
    wire [ 1:0] utlb_w_mat0;
    wire        utlb_w_d0;
    wire        utlb_w_v0;
    wire [19:0] utlb_w_ppn1;
    wire [ 1:0] utlb_w_plv1;
    wire [ 1:0] utlb_w_mat1;
    wire        utlb_w_d1;
    wire        utlb_w_v1;

    wire [ 1:0] utlb_lru_victim;

    utlb u_utlb (
        .clk            (clk            ),
        .reset          (reset          ),

        .s_vppn         (s1_vppn        ),
        .s_va_bit12     (s1_va_bit12    ),
        .s_asid         (s1_asid        ),
        .s_found        (utlb_found     ),
        .s_index        (utlb_index     ),
        .s_ppn          (utlb_ppn       ),
        .s_ps           (utlb_ps        ),
        .s_plv          (utlb_plv       ),
        .s_mat          (utlb_mat       ),
        .s_d            (utlb_d         ),
        .s_v            (utlb_v         ),
        .lru_victim     (utlb_lru_victim),

        .we             (utlb_we        ),
        .w_index        (utlb_w_index   ),
        .w_vppn         (utlb_w_vppn    ),
        .w_ps           (utlb_w_ps      ),
        .w_asid         (utlb_w_asid    ),
        .w_g            (utlb_w_g       ),
        .w_ppn0         (utlb_w_ppn0    ),
        .w_plv0         (utlb_w_plv0    ),
        .w_mat0         (utlb_w_mat0    ),
        .w_d0           (utlb_w_d0      ),
        .w_v0           (utlb_w_v0      ),
        .w_ppn1         (utlb_w_ppn1    ),
        .w_plv1         (utlb_w_plv1    ),
        .w_mat1         (utlb_w_mat1    ),
        .w_d1           (utlb_w_d1      ),
        .w_v1           (utlb_w_v1      ),

        .invtlb_valid   (invtlb_valid   )
    );

    // ========== μTLB 回填逻辑 ==========
    // 访存类指令 μTLB miss 时，下一拍大 TLB 结果有效后回填
    reg utlb_miss_r;

    always @(posedge clk) begin
        if (reset)
            utlb_miss_r <= 1'b0;
        else if (utlb_we)
            utlb_miss_r <= 1'b0;
        else if (!utlb_found && !tlbsrch_en && !invtlb_en)
            utlb_miss_r <= 1'b1;
    end

    assign utlb_we      = utlb_miss_r && tlb_s1_found;
    assign utlb_w_index = utlb_lru_victim;
    assign utlb_w_vppn  = s1_vppn;
    assign utlb_w_ps    = tlb_s1_ps;
    assign utlb_w_asid  = s1_asid;
    assign utlb_w_g     = 1'b0;
    assign utlb_w_ppn0  = tlb_s1_ppn0;
    assign utlb_w_ppn1  = tlb_s1_ppn1;
    assign utlb_w_plv0  = tlb_s1_plv0;
    assign utlb_w_plv1  = tlb_s1_plv1;
    assign utlb_w_mat0  = tlb_s1_mat0;
    assign utlb_w_mat1  = tlb_s1_mat1;
    assign utlb_w_d0    = tlb_s1_d0;
    assign utlb_w_d1    = tlb_s1_d1;
    assign utlb_w_v0    = tlb_s1_v0;
    assign utlb_w_v1    = tlb_s1_v1;

    // random index gen
    always @(posedge clk) begin
        if (reset) begin
            rand_index <= 0;
        end
        else begin
            rand_index <= rand_index + 1'b1;
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

    // 所有异常条件并行计算（1 级 LUT），优先选择器编码（1 级 LUT）
    // 优先级: PPF(2) > PIL(1) > PPL(0)
    wire s0_exc_ppf;  // Page Fault (not found)
    wire s0_exc_pil;  // Page Invalid (Load / 取指)
    wire s0_exc_ppl;  // Privilege Violation

    assign s0_exc_ppf = (s0_found == 1'b0);
    assign s0_exc_pil = (s0_v == 1'b0);
    assign s0_exc_ppl = (plv > s0_plv);

    assign s0_tlb_exc = s0_exc_ppf ? 3'b100 :
                        s0_exc_pil ? 3'b010 :
                        s0_exc_ppl ? 3'b001 : 3'b000;
    assign if_tlb_exc = s0_tlb_exc & {3{dapg==2'b01}} & {3{if_match==2'b0}};
    // MAT 选源：直接翻译 → DATF / DMW窗口 → DMW MAT / 页表 → TLB MAT
    wire [1:0] if_mat_final;
    assign if_mat_final = (dapg == 2'b10) ? datf_in           :
                          if_match[0]     ? dmw0[`CSR_DMW_MAT]:
                          if_match[1]     ? dmw1[`CSR_DMW_MAT]:
                                            s0_mat;
    assign if_mat    = if_mat_final;
    assign if_cached = (if_mat_final == 2'b01);
    assign paddr_to_if = dapg == 2'b10    ? vaddr_from_if                              :
                         if_match[0]      ? {dmw0[`CSR_DMW_PSEG], vaddr_from_if[28:0]} :
                         if_match[1]      ? {dmw1[`CSR_DMW_PSEG], vaddr_from_if[28:0]} :
                         (s0_ps == 6'd12) ? {s0_ppn[19:0], vaddr_from_if[11:0]}        :
                         (s0_ps == 6'd21) ? {s0_ppn[19:10], vaddr_from_if[21:0]}       :
                                            32'b0;

    // ex logic
    assign {ex_vppn, ex_va_bit12, ex_offset} = vaddr_from_ex;
    assign {tlbsrch_en, invtlb_en, invtlb_opcode, invtlb_asid, invtlb_vppn} = vtlb_enop;
    assign {load, store} = ld_and_str;
    assign s1_vppn     = tlbsrch_en ? tlbehi[`CSR_TLBEHI_VPPN] : invtlb_en ? invtlb_vppn : ex_vppn;
    assign s1_va_bit12 = ex_va_bit12;
    assign s1_asid     = invtlb_en ? invtlb_asid : asid[`CSR_ASID_ASID];

    // 所有异常条件并行计算（1 级 LUT），优先选择器编码（1 级 LUT）
    // 优先级: PPE(4) > PPL(3) > PIL(2) > PIS(1) > PME(0)
    wire exc_ppe;  // Page Fault (not found)
    wire exc_ppl;  // Privilege Violation
    wire exc_pil;  // Page Invalid (Load)
    wire exc_pis;  // Page Invalid (Store)
    wire exc_pme;  // Page Modified (Dirty=0, Store)

    assign exc_ppe = (s1_found == 1'b0) && !tlbsrch_en && !invtlb_en;
    assign exc_ppl = (plv > s1_plv)      && !tlbsrch_en && !invtlb_en;
    assign exc_pil = load  && !s1_v      && !tlbsrch_en && !invtlb_en;
    assign exc_pis = store && !s1_v      && !tlbsrch_en && !invtlb_en;
    assign exc_pme = store && !s1_d      && !tlbsrch_en && !invtlb_en;

    assign s1_tlb_exc = exc_ppe ? 5'b10000 :
                        exc_ppl ? 5'b01000 :
                        exc_pil ? 5'b00100 :
                        exc_pis ? 5'b00010 :
                        exc_pme ? 5'b00001 : 5'b00000;
    assign ex_tlb_exc = s1_tlb_exc & {5{dapg==2'b01}} & {5{ex_match==2'b0}};
    assign mem_tlb_req = (dapg == 2'b01) && (ex_match == 2'b00)
                       && !tlbsrch_en && !invtlb_en;
    // MAT 选源：直接翻译 → DATM / DMW窗口 → DMW MAT / 页表 → TLB MAT
    wire [1:0] ex_mat_final;
    assign ex_mat_final = (dapg == 2'b10) ? datm_in           :
                          ex_match[0]     ? dmw0[`CSR_DMW_MAT]:
                          ex_match[1]     ? dmw1[`CSR_DMW_MAT]:
                                            s1_mat;
    assign ex_mat    = ex_mat_final;
    assign ex_cached = (ex_mat_final == 2'b01);
    assign paddr_to_ex = tlbsrch_en || invtlb_en ? 32'b0                               :
                         dapg == 2'b10    ? vaddr_from_ex                              :
                         ex_match[0]      ? {dmw0[`CSR_DMW_PSEG], vaddr_from_ex[28:0]} :
                         ex_match[1]      ? {dmw1[`CSR_DMW_PSEG], vaddr_from_ex[28:0]} :
                         (s1_ps == 6'd12) ? {s1_ppn[19:0], vaddr_from_ex[11:0]}        :
                         (s1_ps == 6'd21) ? {s1_ppn[19:10], vaddr_from_ex[21:0]}       :
                                            32'b0;
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