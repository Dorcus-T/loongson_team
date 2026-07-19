`include "mycpu.h"

module tlb #(
    parameter TLBNUM = 32
) (
    input  wire        clk,
    input  wire        reset,

    // 搜索端口port 0(if_stage)
    input  wire [18:0] s0_vppn,
    input  wire        s0_va_bit12,
    input  wire [ 9:0] s0_asid,
    output wire        s0_found,
    output wire [$clog2(TLBNUM)-1:0] s0_index,
    output wire [19:0] s0_ppn,
    output wire [ 5:0] s0_ps,
    output wire [ 1:0] s0_plv,
    output wire [ 1:0] s0_mat,
    output wire        s0_d,
    output wire        s0_v,

    // 搜索端口port 1(mem_stage)
    input  wire [18:0] s1_vppn,
    input  wire        s1_va_bit12,
    input  wire [ 9:0] s1_asid,
    output wire        s1_found,
    output wire [$clog2(TLBNUM)-1:0] s1_index,
    output wire [19:0] s1_ppn,
    output wire [ 5:0] s1_ps,
    output wire [ 1:0] s1_plv,
    output wire [ 1:0] s1_mat,
    output wire        s1_d,
    output wire        s1_v,

    // s1 未 mux 输出（供 μTLB 回填使用）
    output wire [19:0] s1_ppn0,
    output wire [19:0] s1_ppn1,
    output wire [ 1:0] s1_plv0,
    output wire [ 1:0] s1_plv1,
    output wire [ 1:0] s1_mat0,
    output wire [ 1:0] s1_mat1,
    output wire        s1_d0,
    output wire        s1_d1,
    output wire        s1_v0,
    output wire        s1_v1,

    // INVTLB opcode
    input  wire        invtlb_valid,
    input  wire [ 4:0] invtlb_op,

    // 写端口(TLBWR,TLBFILL)
    input  wire        we,
    input  wire [$clog2(TLBNUM)-1:0] w_index,
    input  wire        w_e,
    input  wire [18:0] w_vppn,
    input  wire [ 5:0] w_ps,
    input  wire [ 9:0] w_asid,
    input  wire        w_g,
    input  wire [19:0] w_ppn0,
    input  wire [ 1:0] w_plv0,
    input  wire [ 1:0] w_mat0,
    input  wire        w_d0,
    input  wire        w_v0,
    input  wire [19:0] w_ppn1,
    input  wire [ 1:0] w_plv1,
    input  wire [ 1:0] w_mat1,
    input  wire        w_d1,
    input  wire        w_v1,

    // 读端口(TLBRD)
    input  wire [$clog2(TLBNUM)-1:0] r_index,
    output wire        r_e,
    output wire [18:0] r_vppn,
    output wire [ 5:0] r_ps,
    output wire [ 9:0] r_asid,
    output wire        r_g,
    output wire [19:0] r_ppn0,
    output wire [ 1:0] r_plv0,
    output wire [ 1:0] r_mat0,
    output wire        r_d0,
    output wire        r_v0,
    output wire [19:0] r_ppn1,
    output wire [ 1:0] r_plv1,
    output wire [ 1:0] r_mat1,
    output wire        r_d1,
    output wire        r_v1
);

    // tlb表项定义
    reg  [TLBNUM-1:0] tlb_e;
    reg  [TLBNUM-1:0] tlb_ps; //1:4MB, 0:4KB
    reg  [18:0] tlb_vppn [TLBNUM-1:0];
    reg  [ 9:0] tlb_asid [TLBNUM-1:0];
    reg         tlb_g    [TLBNUM-1:0];
    reg  [19:0] tlb_ppn0 [TLBNUM-1:0];
    reg  [ 1:0] tlb_plv0 [TLBNUM-1:0];
    reg  [ 1:0] tlb_mat0 [TLBNUM-1:0];
    reg         tlb_d0   [TLBNUM-1:0];
    reg         tlb_v0   [TLBNUM-1:0];
    reg  [19:0] tlb_ppn1 [TLBNUM-1:0];
    reg  [ 1:0] tlb_plv1 [TLBNUM-1:0];
    reg  [ 1:0] tlb_mat1 [TLBNUM-1:0];
    reg         tlb_d1   [TLBNUM-1:0];
    reg         tlb_v1   [TLBNUM-1:0];

    // 工具线路定义
    wire [TLBNUM-1:0] match0;    // 查找匹配0
    wire [TLBNUM-1:0] match1;    // 查找匹配1
    wire [TLBNUM-1:0] inv_match; // INVTLB匹配
    wire [TLBNUM-1:0] inv_cond1; // tlb_g == 0
    wire [TLBNUM-1:0] inv_cond2; // tlb_g == 1
    wire [TLBNUM-1:0] inv_cond3; // s1_asid == tlb_asid
    wire [TLBNUM-1:0] inv_cond4; // s1_vppn == tlb_vppn & s1_ps == tlb_ps

    // 读逻辑
    assign r_e     = tlb_e[r_index];
    assign r_vppn  = tlb_vppn[r_index];
    assign r_ps    = tlb_ps[r_index] ? 6'd21 : 6'd12;
    assign r_asid  = tlb_asid[r_index];
    assign r_g     = tlb_g[r_index];
    assign r_ppn0  = tlb_ppn0[r_index];
    assign r_plv0  = tlb_plv0[r_index];
    assign r_mat0  = tlb_mat0[r_index];
    assign r_d0    = tlb_d0[r_index];
    assign r_v0    = tlb_v0[r_index];
    assign r_ppn1  = tlb_ppn1[r_index];
    assign r_plv1  = tlb_plv1[r_index];
    assign r_mat1  = tlb_mat1[r_index];
    assign r_d1    = tlb_d1[r_index];
    assign r_v1    = tlb_v1[r_index];

    // INVTLB操作逻辑
    genvar b, i;
    generate
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_cond1
            assign inv_cond1[i] = ~tlb_g[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_cond2
            assign inv_cond2[i] = tlb_g[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_cond3
            assign inv_cond3[i] = s1_asid == tlb_asid[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_cond4
            assign inv_cond4[i] = (s1_vppn[18:9] == tlb_vppn[i][18:9])
                               && (tlb_ps[i] || s1_vppn[8:0] == tlb_vppn[i][8:0]);
        end
    endgenerate

    assign inv_match = {TLBNUM{(invtlb_op == 5'd0) || (invtlb_op == 5'd1)}}
                     | ({TLBNUM{invtlb_op == 5'd2}} & inv_cond2)
                     | ({TLBNUM{invtlb_op == 5'd3}} & inv_cond1)
                     | ({TLBNUM{invtlb_op == 5'd4}} & inv_cond1 & inv_cond3)
                     | ({TLBNUM{invtlb_op == 5'd5}} & inv_cond1 & inv_cond3 & inv_cond4)
                     | ({TLBNUM{invtlb_op == 5'd6}} & (inv_cond2 || inv_cond3) && inv_cond4);

    // 写逻辑
    integer a;
    always @(posedge clk) begin
        if (reset) begin
            tlb_e  <= {TLBNUM{1'b0}};      // 所有项无效
            tlb_ps <= {TLBNUM{1'b0}};      // 默认为4KB页
            for (a = 0; a < TLBNUM; a = a + 1) begin
                tlb_vppn[a] <= 19'd0;
                tlb_asid[a] <= 10'd0;
                tlb_g[a]    <= 1'b0;
                tlb_ppn0[a] <= 20'd0;
                tlb_plv0[a] <= 2'd0;
                tlb_mat0[a] <= 2'd0;
                tlb_d0[a]   <= 1'b0;
                tlb_v0[a]   <= 1'b0;
                tlb_ppn1[a] <= 20'd0;
                tlb_plv1[a] <= 2'd0;
                tlb_mat1[a] <= 2'd0;
                tlb_d1[a]   <= 1'b0;
                tlb_v1[a]   <= 1'b0;
            end
        end
        else if (invtlb_valid) begin
            tlb_e <= tlb_e & ~inv_match;
        end
        else if (we) begin
            tlb_e[w_index]    <= w_e;
            tlb_vppn[w_index] <= w_vppn;
            tlb_ps[w_index]   <= (w_ps == 6'd21) ? 1'b1 : 1'b0;
            tlb_asid[w_index] <= w_asid;
            tlb_g[w_index]    <= w_g;
            tlb_ppn0[w_index] <= w_ppn0;
            tlb_plv0[w_index] <= w_plv0;
            tlb_mat0[w_index] <= w_mat0;
            tlb_d0[w_index]   <= w_d0;
            tlb_v0[w_index]   <= w_v0;
            tlb_ppn1[w_index] <= w_ppn1;
            tlb_plv1[w_index] <= w_plv1;
            tlb_mat1[w_index] <= w_mat1;
            tlb_d1[w_index]   <= w_d1;
            tlb_v1[w_index]   <= w_v1;
        end
    end

    // 查找逻辑
    generate
        // 查找逻辑0
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_match0
            assign match0[i] = (s0_vppn[18:9] == tlb_vppn[i][18:9])
                            && (tlb_ps[i] || s0_vppn[8:0] == tlb_vppn[i][8:0])
                            && ((s0_asid == tlb_asid[i]) || tlb_g[i]) && tlb_e[i];
        end

        // 查找逻辑1
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_match1
            assign match1[i] = (s1_vppn[18:9] == tlb_vppn[i][18:9])
                            && (tlb_ps[i] || s1_vppn[8:0] == tlb_vppn[i][8:0])
                            && ((s1_asid == tlb_asid[i]) || tlb_g[i]) && tlb_e[i];
        end
    endgenerate

    // 查找读出
    assign s0_found = |match0;
    generate
        // s0_index
        for (b = 0; b < $clog2(TLBNUM); b = b + 1) begin : gen_s0_index
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_term
                assign term[i] = match0[i] & ((i >> b) & 1'b1);
            end
            assign s0_index[b] = |term;
        end

        // s0_ppn
        for (b = 0; b < 20; b = b + 1) begin : gen_s0_ppn
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_term
                assign term[i] = match0[i] & (tlb_ps[i] ? (s0_vppn[8] ? tlb_ppn1[i][b] : tlb_ppn0[i][b])
                                             : (s0_va_bit12 ? tlb_ppn1[i][b] : tlb_ppn0[i][b]));
            end
            assign s0_ppn[b] = |term;
        end

        // s0_ps
        for (b = 0; b < 6; b = b + 1) begin : gen_s0_ps
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s0_ps_term
                assign term[i] = match0[i] & (tlb_ps[i] ? ((6'd21 >> b) & 1'b1) : ((6'd12 >> b) & 1'b1));
            end
            assign s0_ps[b] = |term;
        end

        // s0_plv
        for (b = 0; b < 2; b = b + 1) begin : gen_s0_plv
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s0_plv_term
                assign term[i] = match0[i] & (tlb_ps[i] ? (s0_vppn[8] ? tlb_plv1[i][b] : tlb_plv0[i][b])
                                             : (s0_va_bit12 ? tlb_plv1[i][b] : tlb_plv0[i][b]));
            end
            assign s0_plv[b] = |term;
        end

        // s0_mat
        for (b = 0; b < 2; b = b + 1) begin : gen_s0_mat
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s0_mat_term
                assign term[i] = match0[i] & (tlb_ps[i] ? (s0_vppn[8] ? tlb_mat1[i][b] : tlb_mat0[i][b])
                                             : (s0_va_bit12 ? tlb_mat1[i][b] : tlb_mat0[i][b]));
            end
            assign s0_mat[b] = |term;
        end

        // s0_d
        wire [TLBNUM-1:0] s0_d_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s0_d
            assign s0_d_term[i] = match0[i] & (tlb_ps[i] ? (s0_vppn[8] ? tlb_d1[i] : tlb_d0[i])
                                              : (s0_va_bit12 ? tlb_d1[i] : tlb_d0[i]));
        end
        assign s0_d = |s0_d_term;

        // s0_v
        wire [TLBNUM-1:0] s0_v_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s0_v
            assign s0_v_term[i] = match0[i] & (tlb_ps[i] ? (s0_vppn[8] ? tlb_v1[i] : tlb_v0[i])
                                              : (s0_va_bit12 ? tlb_v1[i] : tlb_v0[i]));
        end
        assign s0_v = |s0_v_term;
    endgenerate

    // s1 组合输出（下一拍寄存后对外）
    wire        s1_found_comb;
    wire [ 4:0] s1_index_comb;
    wire [19:0] s1_ppn_comb;
    wire [ 5:0] s1_ps_comb;
    wire [ 1:0] s1_plv_comb;
    wire [ 1:0] s1_mat_comb;
    wire        s1_d_comb;
    wire        s1_v_comb;

    // s1 未 mux 组合输出（供 μTLB 回填）
    wire [19:0] s1_ppn0_comb;
    wire [19:0] s1_ppn1_comb;
    wire [ 1:0] s1_plv0_comb;
    wire [ 1:0] s1_plv1_comb;
    wire [ 1:0] s1_mat0_comb;
    wire [ 1:0] s1_mat1_comb;
    wire        s1_d0_comb;
    wire        s1_d1_comb;
    wire        s1_v0_comb;
    wire        s1_v1_comb;

    assign s1_found_comb = |match1;
    generate
        // s1_index
        for (b = 0; b < $clog2(TLBNUM); b = b + 1) begin : gen_s1_index
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_index_term
                assign term[i] = match1[i] & ((i >> b) & 1'b1);
            end
            assign s1_index_comb[b] = |term;
        end

        // s1_ppn
        for (b = 0; b < 20; b = b + 1) begin : gen_s1_ppn
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ppn_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_ppn1[i][b] : tlb_ppn0[i][b])
                                             : (s1_va_bit12 ? tlb_ppn1[i][b] : tlb_ppn0[i][b]));
            end
            assign s1_ppn_comb[b] = |term;
        end

        // s1_ps
        for (b = 0; b < 6; b = b + 1) begin : gen_s1_ps
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ps_term
                assign term[i] = match1[i] & (tlb_ps[i] ? ((6'd21 >> b) & 1'b1) : ((6'd12 >> b) & 1'b1));
            end
            assign s1_ps_comb[b] = |term;
        end

        // s1_plv
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_plv
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_plv_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_plv1[i][b] : tlb_plv0[i][b])
                                             : (s1_va_bit12 ? tlb_plv1[i][b] : tlb_plv0[i][b]));
            end
            assign s1_plv_comb[b] = |term;
        end

        // s1_mat
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_mat
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_mat_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_mat1[i][b] : tlb_mat0[i][b])
                                             : (s1_va_bit12 ? tlb_mat1[i][b] : tlb_mat0[i][b]));
            end
            assign s1_mat_comb[b] = |term;
        end

        // s1_d
        wire [TLBNUM-1:0] s1_d_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_d
            assign s1_d_term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_d1[i] : tlb_d0[i])
                                              : (s1_va_bit12 ? tlb_d1[i] : tlb_d0[i]));
        end
        assign s1_d_comb = |s1_d_term;

        // s1_v
        wire [TLBNUM-1:0] s1_v_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_v
            assign s1_v_term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_v1[i] : tlb_v0[i])
                                              : (s1_va_bit12 ? tlb_v1[i] : tlb_v0[i]));
        end
        assign s1_v_comb = |s1_v_term;

        // ====== s1 未 mux 输出（供 μTLB 回填，不做 va_bit12 选择） ======
        // s1_ppn0
        for (b = 0; b < 20; b = b + 1) begin : gen_s1_ppn0
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ppn0_term
                assign term[i] = match1[i] & tlb_ppn0[i][b];
            end
            assign s1_ppn0_comb[b] = |term;
        end

        // s1_ppn1
        for (b = 0; b < 20; b = b + 1) begin : gen_s1_ppn1
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ppn1_term
                assign term[i] = match1[i] & tlb_ppn1[i][b];
            end
            assign s1_ppn1_comb[b] = |term;
        end

        // s1_plv0
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_plv0
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_plv0_term
                assign term[i] = match1[i] & tlb_plv0[i][b];
            end
            assign s1_plv0_comb[b] = |term;
        end

        // s1_plv1
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_plv1
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_plv1_term
                assign term[i] = match1[i] & tlb_plv1[i][b];
            end
            assign s1_plv1_comb[b] = |term;
        end

        // s1_mat0
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_mat0
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_mat0_term
                assign term[i] = match1[i] & tlb_mat0[i][b];
            end
            assign s1_mat0_comb[b] = |term;
        end

        // s1_mat1
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_mat1
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_mat1_term
                assign term[i] = match1[i] & tlb_mat1[i][b];
            end
            assign s1_mat1_comb[b] = |term;
        end

        // s1_d0
        wire [TLBNUM-1:0] s1_d0_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_d0
            assign s1_d0_term[i] = match1[i] & tlb_d0[i];
        end
        assign s1_d0_comb = |s1_d0_term;

        // s1_d1
        wire [TLBNUM-1:0] s1_d1_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_d1
            assign s1_d1_term[i] = match1[i] & tlb_d1[i];
        end
        assign s1_d1_comb = |s1_d1_term;

        // s1_v0
        wire [TLBNUM-1:0] s1_v0_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_v0
            assign s1_v0_term[i] = match1[i] & tlb_v0[i];
        end
        assign s1_v0_comb = |s1_v0_term;

        // s1_v1
        wire [TLBNUM-1:0] s1_v1_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_v1
            assign s1_v1_term[i] = match1[i] & tlb_v1[i];
        end
        assign s1_v1_comb = |s1_v1_term;
    endgenerate

    // ========== s1 输出寄存器（切断 TLB 查找 → MMU 异常编码的组合长链） ==========
    reg         s1_found_r;
    reg  [ 4:0] s1_index_r;
    reg  [19:0] s1_ppn_r;
    reg  [ 5:0] s1_ps_r;
    reg  [ 1:0] s1_plv_r;
    reg  [ 1:0] s1_mat_r;
    reg         s1_d_r;
    reg         s1_v_r;

    // s1 未 mux 输出寄存器（供 μTLB 回填）
    reg  [19:0] s1_ppn0_r;
    reg  [19:0] s1_ppn1_r;
    reg  [ 1:0] s1_plv0_r;
    reg  [ 1:0] s1_plv1_r;
    reg  [ 1:0] s1_mat0_r;
    reg  [ 1:0] s1_mat1_r;
    reg         s1_d0_r;
    reg         s1_d1_r;
    reg         s1_v0_r;
    reg         s1_v1_r;

    always @(posedge clk) begin
        if (reset) begin
            s1_found_r <= 1'b0;
            s1_index_r <= 5'd0;
            s1_ppn_r   <= 20'd0;
            s1_ps_r    <= 6'd0;
            s1_plv_r   <= 2'd0;
            s1_mat_r   <= 2'd0;
            s1_d_r     <= 1'b0;
            s1_v_r     <= 1'b0;
            s1_ppn0_r  <= 20'd0;
            s1_ppn1_r  <= 20'd0;
            s1_plv0_r  <= 2'd0;
            s1_plv1_r  <= 2'd0;
            s1_mat0_r  <= 2'd0;
            s1_mat1_r  <= 2'd0;
            s1_d0_r    <= 1'b0;
            s1_d1_r    <= 1'b0;
            s1_v0_r    <= 1'b0;
            s1_v1_r    <= 1'b0;
        end
        else begin
            s1_found_r <= s1_found_comb;
            s1_index_r <= s1_index_comb;
            s1_ppn_r   <= s1_ppn_comb;
            s1_ps_r    <= s1_ps_comb;
            s1_plv_r   <= s1_plv_comb;
            s1_mat_r   <= s1_mat_comb;
            s1_d_r     <= s1_d_comb;
            s1_v_r     <= s1_v_comb;
            s1_ppn0_r  <= s1_ppn0_comb;
            s1_ppn1_r  <= s1_ppn1_comb;
            s1_plv0_r  <= s1_plv0_comb;
            s1_plv1_r  <= s1_plv1_comb;
            s1_mat0_r  <= s1_mat0_comb;
            s1_mat1_r  <= s1_mat1_comb;
            s1_d0_r    <= s1_d0_comb;
            s1_d1_r    <= s1_d1_comb;
            s1_v0_r    <= s1_v0_comb;
            s1_v1_r    <= s1_v1_comb;
        end
    end

    assign s1_found = s1_found_r;
    assign s1_index = s1_index_r;
    assign s1_ppn   = s1_ppn_r;
    assign s1_ps    = s1_ps_r;
    assign s1_plv   = s1_plv_r;
    assign s1_mat   = s1_mat_r;
    assign s1_d     = s1_d_r;
    assign s1_v     = s1_v_r;

    assign s1_ppn0  = s1_ppn0_r;
    assign s1_ppn1  = s1_ppn1_r;
    assign s1_plv0  = s1_plv0_r;
    assign s1_plv1  = s1_plv1_r;
    assign s1_mat0  = s1_mat0_r;
    assign s1_mat1  = s1_mat1_r;
    assign s1_d0    = s1_d0_r;
    assign s1_d1    = s1_d1_r;
    assign s1_v0    = s1_v0_r;
    assign s1_v1    = s1_v1_r;

endmodule