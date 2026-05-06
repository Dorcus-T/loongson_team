`include "mycpu.h"

module tlb #
(
    parameter TLBNUM = 32
)
(
    input clk,
    input reset,

    // 搜索端口port 0(if_stage)
    input  [18:0] s0_vppn,
    input  s0_va_bit12,
    input  [9:0] s0_asid,
    output s0_found,
    output [$clog2(TLBNUM) - 1:0] s0_index,
    output [19:0] s0_ppn,
    output [5:0] s0_ps,
    output [1:0] s0_plv,
    output [1:0] s0_mat,
    output s0_d,
    output s0_v,

    // 搜索端口port 1(mem_stage)
    input  [18:0] s1_vppn,
    input  s1_va_bit12,
    input  [9:0] s1_asid,
    output s1_found,
    output [$clog2(TLBNUM) - 1:0] s1_index,
    output [19:0] s1_ppn,
    output [5:0] s1_ps,
    output [1:0] s1_plv,
    output [1:0] s1_mat,
    output s1_d,
    output s1_v,

    // INVTLB opcode
    input  invtlb_valid,
    input  [4:0] invtlb_op,

    // 写端口(TLBWR,TLBFILL)
    input  we,    
    input  [$clog2(TLBNUM) - 1:0] w_index,
    input  w_e,
    input  [18:0] w_vppn,
    input  [5:0] w_ps,
    input  [9:0] w_asid,
    input  w_g,
    input  [19:0] w_ppn0,
    input  [1:0] w_plv0,
    input  [1:0] w_mat0,
    input  w_d0,
    input  w_v0,
    input  [19:0] w_ppn1,
    input  [1:0] w_plv1,
    input  [1:0] w_mat1,
    input  w_d1,
    input  w_v1,

    // 读端口(TLBRD)
    input  [$clog2(TLBNUM) - 1:0] r_index,
    output r_e,
    output [18:0] r_vppn,
    output [5:0] r_ps,
    output [9:0] r_asid,
    output r_g,
    output [19:0] r_ppn0,
    output [1:0] r_plv0,
    output [1:0] r_mat0,
    output r_d0,
    output r_v0,
    output [19:0] r_ppn1,
    output [1:0] r_plv1,
    output [1:0] r_mat1,
    output r_d1,
    output r_v1
);
    
    // tlb表项定义
    reg [TLBNUM - 1:0] tlb_e;
    reg [TLBNUM - 1:0] tlb_ps; //1:4MB, 0:4KB
    reg [18:0] tlb_vppn [TLBNUM - 1:0];
    reg [9:0]  tlb_asid [TLBNUM - 1:0];
    reg        tlb_g    [TLBNUM - 1:0];
    reg [19:0] tlb_ppn0 [TLBNUM - 1:0];
    reg [1:0]  tlb_plv0 [TLBNUM - 1:0];
    reg [1:0]  tlb_mat0 [TLBNUM - 1:0];
    reg        tlb_d0   [TLBNUM - 1:0];
    reg        tlb_v0   [TLBNUM - 1:0];
    reg [19:0] tlb_ppn1 [TLBNUM - 1:0];
    reg [1:0]  tlb_plv1 [TLBNUM - 1:0];
    reg [1:0]  tlb_mat1 [TLBNUM - 1:0];
    reg        tlb_d1   [TLBNUM - 1:0];
    reg        tlb_v1   [TLBNUM - 1:0];

    // 工具线路定义
    wire [TLBNUM - 1:0] match0; // 查找匹配0
    wire [TLBNUM - 1:0] match1; // 查找匹配1
    wire [TLBNUM - 1:0] inv_match; // INVTLB匹配
    wire [TLBNUM - 1:0] inv_cond1; // tlb_g == 0
    wire [TLBNUM - 1:0] inv_cond2; // tlb_g == 1
    wire [TLBNUM - 1:0] inv_cond3; // s1_asid == tlb_asid
    wire [TLBNUM - 1:0] inv_cond4; // s1_vppn == tlb_vppn & s1_ps == tlb_ps

    // 读逻辑
    assign r_e = tlb_e[r_index];
    assign r_vppn = tlb_vppn[r_index];
    assign r_ps = tlb_ps[r_index] ? 6'd21 : 6'd12;
    assign r_asid = tlb_asid[r_index];
    assign r_g = tlb_g[r_index];
    assign r_ppn0 = tlb_ppn0[r_index];
    assign r_plv0 = tlb_plv0[r_index];
    assign r_mat0 = tlb_mat0[r_index];
    assign r_d0 = tlb_d0[r_index];
    assign r_v0 = tlb_v0[r_index];
    assign r_ppn1 = tlb_ppn1[r_index];
    assign r_plv1 = tlb_plv1[r_index];
    assign r_mat1 = tlb_mat1[r_index];
    assign r_d1 = tlb_d1[r_index];
    assign r_v1 = tlb_v1[r_index];

    // INVTLB操作逻辑
    genvar b, i;
    generate
        for (i = 0; i < TLBNUM; i = i + 1)begin : gen_cond1
           assign inv_cond1[i] = ~ tlb_g[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1)begin : gen_cond2
           assign inv_cond2[i] = tlb_g[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1)begin : gen_cond3
           assign inv_cond3[i] = s1_asid == tlb_asid[i];
        end
        for (i = 0; i < TLBNUM; i = i + 1)begin : gen_cond4
           assign inv_cond4[i] = (s1_vppn[18:9]==tlb_vppn[i][18:9])
                            && (tlb_ps[i] || s1_vppn[8:0]==tlb_vppn[i][8:0]);
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
            tlb_e   <= {TLBNUM{1'b0}};      // 所有项无效
            tlb_ps  <= {TLBNUM{1'b0}};      // 默认为4KB页
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
            tlb_e[w_index] <= w_e;
            tlb_vppn[w_index] <= w_vppn;
            tlb_ps[w_index] <= (w_ps == 6'd21) ? 1'b1 : 1'b0;
            tlb_asid[w_index] <= w_asid;
            tlb_g[w_index] <= w_g;
            tlb_ppn0[w_index] <= w_ppn0;
            tlb_plv0[w_index] <= w_plv0;
            tlb_mat0[w_index] <= w_mat0;
            tlb_d0[w_index] <= w_d0;
            tlb_v0[w_index] <= w_v0;
            tlb_ppn1[w_index] <= w_ppn1;
            tlb_plv1[w_index] <= w_plv1;
            tlb_mat1[w_index] <= w_mat1;
            tlb_d1[w_index] <= w_d1;
            tlb_v1[w_index] <= w_v1;
        end
    end

    // 查找逻辑
    generate
        // 查找逻辑0
        for(i = 0; i < TLBNUM; i = i + 1)begin : gen_match0
            assign match0[i] = (s0_vppn[18:9]==tlb_vppn[i][18:9])
                            && (tlb_ps[i] || s0_vppn[8:0]==tlb_vppn[i][8:0])
                            && ((s0_asid == tlb_asid[i]) || tlb_g[i]) && tlb_e[i];
        end

        // 查找逻辑1
        for(i = 0; i < TLBNUM; i = i + 1)begin : gen_match1
            assign match1[i] = (s1_vppn[18:9]==tlb_vppn[i][18:9])
                            && (tlb_ps[i] || s1_vppn[8:0]==tlb_vppn[i][8:0])
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

    assign s1_found = |match1;
    generate
        // s1_index
        for (b = 0; b < $clog2(TLBNUM); b = b + 1) begin : gen_s1_index
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_index_term
                assign term[i] = match1[i] & ((i >> b) & 1'b1);
            end
            assign s1_index[b] = |term;
        end

        // s1_ppn
        for (b = 0; b < 20; b = b + 1) begin : gen_s1_ppn
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ppn_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_ppn1[i][b] : tlb_ppn0[i][b]) 
                                           : (s1_va_bit12 ? tlb_ppn1[i][b] : tlb_ppn0[i][b]));
            end
            assign s1_ppn[b] = |term;
        end

        // s1_ps
        for (b = 0; b < 6; b = b + 1) begin : gen_s1_ps
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_ps_term
                assign term[i] = match1[i] & (tlb_ps[i] ? ((6'd21 >> b) & 1'b1) : ((6'd12 >> b) & 1'b1));
            end
            assign s1_ps[b] = |term;
        end

        // s1_plv
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_plv
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_plv_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_plv1[i][b] : tlb_plv0[i][b]) 
                                           : (s1_va_bit12 ? tlb_plv1[i][b] : tlb_plv0[i][b]));
            end
            assign s1_plv[b] = |term;
        end

        // s1_mat
        for (b = 0; b < 2; b = b + 1) begin : gen_s1_mat
            wire [TLBNUM-1:0] term;
            for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_mat_term
                assign term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_mat1[i][b] : tlb_mat0[i][b]) 
                                           : (s1_va_bit12 ? tlb_mat1[i][b] : tlb_mat0[i][b]));
            end
            assign s1_mat[b] = |term;
        end

        // s1_d
        wire [TLBNUM-1:0] s1_d_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_d
            assign s1_d_term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_d1[i] : tlb_d0[i]) 
                                            : (s1_va_bit12 ? tlb_d1[i] : tlb_d0[i]));
        end
        assign s1_d = |s1_d_term;

        // s1_v
        wire [TLBNUM-1:0] s1_v_term;
        for (i = 0; i < TLBNUM; i = i + 1) begin : gen_s1_v
            assign s1_v_term[i] = match1[i] & (tlb_ps[i] ? (s1_vppn[8] ? tlb_v1[i] : tlb_v0[i]) 
                                            : (s1_va_bit12 ? tlb_v1[i] : tlb_v0[i]));
        end
        assign s1_v = |s1_v_term;
    endgenerate


endmodule