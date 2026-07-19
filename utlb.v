`include "mycpu.h"

module utlb (
    input  wire        clk,
    input  wire        reset,

    // 搜索端口（组合逻辑，同拍输出）
    input  wire [18:0] s_vppn,
    input  wire        s_va_bit12,
    input  wire [ 9:0] s_asid,
    output wire        s_found,
    output wire [ 1:0] s_index,
    output wire [19:0] s_ppn,
    output wire [ 5:0] s_ps,
    output wire [ 1:0] s_plv,
    output wire [ 1:0] s_mat,
    output wire        s_d,
    output wire        s_v,

    // LRU victim 索引（供 mmu 回填选择）
    output wire [ 1:0] lru_victim,

    // 写端口（大 TLB 未命中 → 回填）
    input  wire        we,
    input  wire [ 1:0] w_index,
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

    // INVTLB 清空
    input  wire        invtlb_valid
);

    // ========== μTLB 表项（4 项全相联） ==========
    reg         valid [3:0];
    reg         ps    [3:0];   // 1:4MB, 0:4KB
    reg  [18:0] vppn  [3:0];
    reg  [ 9:0] asid  [3:0];
    reg         g     [3:0];
    reg  [19:0] ppn0  [3:0];
    reg  [ 1:0] plv0  [3:0];
    reg  [ 1:0] mat0  [3:0];
    reg         d0    [3:0];
    reg         v0    [3:0];
    reg  [19:0] ppn1  [3:0];
    reg  [ 1:0] plv1  [3:0];
    reg  [ 1:0] mat1  [3:0];
    reg         d1    [3:0];
    reg         v1    [3:0];

    // ========== LRU 状态（6 bit 矩阵） ==========
    reg lr_01, lr_02, lr_03;  // entry 0 vs 1,2,3
    reg lr_12, lr_13;          // entry 1 vs 2,3
    reg lr_23;                 // entry 2 vs 3

    // ========== 查找匹配（组合逻辑） ==========
    wire [3:0] match;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_match
            assign match[i] = (s_vppn[18:9] == vppn[i][18:9])
                           && (ps[i] || s_vppn[8:0] == vppn[i][8:0])
                           && ((s_asid == asid[i]) || g[i])
                           && valid[i];
        end
    endgenerate

    assign s_found = |match;

    // ========== 命中项 MUX（组合逻辑） ==========
    // s_index
    wire [3:0] index_term [1:0];
    genvar b;
    generate
        for (b = 0; b < 2; b = b + 1) begin : gen_index
            for (i = 0; i < 4; i = i + 1) begin : gen_term
                assign index_term[b][i] = match[i] & ((i >> b) & 1'b1);
            end
            assign s_index[b] = |index_term[b];
        end

        // s_ppn
        for (b = 0; b < 20; b = b + 1) begin : gen_ppn
            wire [3:0] term;
            for (i = 0; i < 4; i = i + 1) begin : gen_ppn_term
                assign term[i] = match[i] & (ps[i] ? (s_vppn[8] ? ppn1[i][b] : ppn0[i][b])
                                                 : (s_va_bit12 ? ppn1[i][b] : ppn0[i][b]));
            end
            assign s_ppn[b] = |term;
        end

        // s_ps
        for (b = 0; b < 6; b = b + 1) begin : gen_ps
            wire [3:0] term;
            for (i = 0; i < 4; i = i + 1) begin : gen_ps_term
                assign term[i] = match[i] & (ps[i] ? ((6'd21 >> b) & 1'b1) : ((6'd12 >> b) & 1'b1));
            end
            assign s_ps[b] = |term;
        end

        // s_plv
        for (b = 0; b < 2; b = b + 1) begin : gen_plv
            wire [3:0] term;
            for (i = 0; i < 4; i = i + 1) begin : gen_plv_term
                assign term[i] = match[i] & (ps[i] ? (s_vppn[8] ? plv1[i][b] : plv0[i][b])
                                                 : (s_va_bit12 ? plv1[i][b] : plv0[i][b]));
            end
            assign s_plv[b] = |term;
        end

        // s_mat
        for (b = 0; b < 2; b = b + 1) begin : gen_mat
            wire [3:0] term;
            for (i = 0; i < 4; i = i + 1) begin : gen_mat_term
                assign term[i] = match[i] & (ps[i] ? (s_vppn[8] ? mat1[i][b] : mat0[i][b])
                                                 : (s_va_bit12 ? mat1[i][b] : mat0[i][b]));
            end
            assign s_mat[b] = |term;
        end
    endgenerate

    // s_d
    wire [3:0] d_term;
    for (i = 0; i < 4; i = i + 1) begin : gen_d
        assign d_term[i] = match[i] & (ps[i] ? (s_vppn[8] ? d1[i] : d0[i])
                                            : (s_va_bit12 ? d1[i] : d0[i]));
    end
    assign s_d = |d_term;

    // s_v
    wire [3:0] v_term;
    for (i = 0; i < 4; i = i + 1) begin : gen_v
        assign v_term[i] = match[i] & (ps[i] ? (s_vppn[8] ? v1[i] : v0[i])
                                            : (s_va_bit12 ? v1[i] : v0[i]));
    end
    assign s_v = |v_term;

    // ========== LRU 命中更新 → 标记为 MRU ==========
    wire [1:0] lru_access;
    assign lru_access = we ? w_index : s_index;

    always @(posedge clk) begin
        if (reset || invtlb_valid) begin
            {lr_01, lr_02, lr_03, lr_12, lr_13, lr_23} <= 6'd0;
        end
        else if (we || (|match)) begin
            case (lru_access)
                2'd0: begin
                    lr_01 <= 1'b1; lr_02 <= 1'b1; lr_03 <= 1'b1;
                end
                2'd1: begin
                    lr_01 <= 1'b0; lr_12 <= 1'b1; lr_13 <= 1'b1;
                end
                2'd2: begin
                    lr_02 <= 1'b0; lr_12 <= 1'b0; lr_23 <= 1'b1;
                end
                2'd3: begin
                    lr_03 <= 1'b0; lr_13 <= 1'b0; lr_23 <= 1'b0;
                end
            endcase
        end
    end

    // ========== LRU victim 选择 ==========
    wire lru_is_0, lru_is_1, lru_is_2, lru_is_3;
    assign lru_is_0 = !lr_01 && !lr_02 && !lr_03;
    assign lru_is_1 =  lr_01 && !lr_12 && !lr_13;
    assign lru_is_2 =  lr_02 &&  lr_12 && !lr_23;
    assign lru_is_3 =  lr_03 &&  lr_13 &&  lr_23;

    assign lru_victim = lru_is_1 ? 2'd1 :
                        lru_is_2 ? 2'd2 :
                        lru_is_3 ? 2'd3 : 2'd0;

    // ========== 写 / INVTLB ==========
    integer a;
    always @(posedge clk) begin
        if (reset || invtlb_valid) begin
            for (a = 0; a < 4; a = a + 1) begin
                valid[a] <= 1'b0;
            end
        end
        else if (we) begin
            valid[w_index] <= 1'b1;
            ps[w_index]    <= (w_ps == 6'd21) ? 1'b1 : 1'b0;
            vppn[w_index]  <= w_vppn;
            asid[w_index]  <= w_asid;
            g[w_index]     <= w_g;
            ppn0[w_index]  <= w_ppn0;
            plv0[w_index]  <= w_plv0;
            mat0[w_index]  <= w_mat0;
            d0[w_index]    <= w_d0;
            v0[w_index]    <= w_v0;
            ppn1[w_index]  <= w_ppn1;
            plv1[w_index]  <= w_plv1;
            mat1[w_index]  <= w_mat1;
            d1[w_index]    <= w_d1;
            v1[w_index]    <= w_v1;
        end
    end

endmodule
