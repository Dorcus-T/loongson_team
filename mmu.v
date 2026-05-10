`include "mycpu.h"

module mmu (
    input  wire        clk,
    input  wire        reset,

    // if interact
    input  wire [31:0] vaddr_from_if,
    output wire [31:0] paddr_to_if,
    output wire [ 2:0] if_tlb_exc,
    output wire [ 1:0] if_mat,

    // id interact
    // ex interact
    input  wire [31:0] vaddr_from_ex,
    input  wire [35:0] vtlb_enop,
    input  wire [ 1:0] ld_and_str,
    output wire [31:0] paddr_to_ex,
    output wire [ 5:0] srch_value,
    output wire [ 4:0] ex_tlb_exc,
    output wire [ 1:0] ex_mat,

    // mem interact
    // wb interact
    input  wire [ 2:0] tlbrwf_en,

    // csr interact
    input  wire [ 1:0] plv_in,
    input  wire [ 5:0] ecode_in,
    input  wire [ 1:0] dapg_in,
    input  wire [63:0] dmw,
    input  wire [`TLBCSR_BUS_WD-1:0] tlbcsr,
    output wire [`TLBRD_BUS_WD-1:0]  tlbrd_value
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

    assign s0_tlb_exc[2] = s0_found == 1'b0;
    assign s0_tlb_exc[1] = s0_v == 1'b0 && !s0_tlb_exc[2];
    assign s0_tlb_exc[0] = (plv > s0_plv) && !s0_tlb_exc[2] && !s0_tlb_exc[1];
    assign if_tlb_exc = s0_tlb_exc & {3{dapg==2'b01}} & {3{if_match==2'b0}};
    assign if_mat = s0_mat;
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

    assign s1_tlb_exc[4] = s1_found == 1'b0 && !tlbsrch_en && !invtlb_en;
    assign s1_tlb_exc[3] = plv > s1_plv && !s1_tlb_exc[4] && !tlbsrch_en && !invtlb_en;
    assign s1_tlb_exc[2] = load && s1_v == 1'b0 && !s1_tlb_exc[4] && !s1_tlb_exc[3] && !tlbsrch_en && !invtlb_en;
    assign s1_tlb_exc[1] = store && s1_v == 1'b0 && !s1_tlb_exc[4] && !s1_tlb_exc[3] && !s1_tlb_exc[2] && !tlbsrch_en && !invtlb_en;
    assign s1_tlb_exc[0] = store && s1_d == 1'b0 && !s1_tlb_exc[4] && !s1_tlb_exc[3] && !s1_tlb_exc[2] && !s1_tlb_exc[1] && !tlbsrch_en && !invtlb_en;
    assign ex_tlb_exc = s1_tlb_exc & {5{dapg==2'b01}} & {5{ex_match==2'b0}};
    assign ex_mat = s1_mat;
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