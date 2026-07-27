`include "mycpu.h"

// ============================================================
// linectrl — 集中式流水线控制器
//
// 替换原始分散式 allowin 握手链，由"上一拍状态→本拍控制"，
// 将所有 7 级 empty/lvalid/lpower/ldata/lready 计算集中于
// 一个模块内，便于综合工具 flatten 且走线不跨模块边界。
//
// 流水级索引（输入侧，上一拍寄存值）：
//   0 = pre_if, 1 = if, 2 = id, 3 = ex, 4 = pre_mem, 5 = mem, 6 = wb
// ============================================================

module linectrl (
    input  wire        clk,
    input  wire        reset,

    // ── 每级输入（本拍组合值，linectrl 内部寄存） ──
    input  wire [6:0]  valid_i,       // 各级 valid（组合）
    input  wire [6:0]  readygo_i,     // 各级 ready_go（组合）
    input  wire [6:0]  exc_i,         // 各级异常有效（组合，wb 不接入）
    input  wire [6:0]  ertn_i,        // 各级 ertn（组合，wb 不接入）
    input  wire [6:0]  mispred_i,     // 各级分支误预测（组合，仅 ex 级有效）

    // ── 输出给每级 ──
    (* max_fanout = 64 *) output wire [6:0]  lvalid,        // 本拍指令有效
    (* max_fanout = 64 *) output wire [6:0]  lpower,        // 本拍有权发请求
    (* max_fanout = 64 *) output wire [6:0]  ldata,         // 0=用旧寄存器, 1=用新寄存器
    (* max_fanout = 64 *) output wire [6:0]  lready,        // 维持就绪（下游阻塞时）

    // ── 分支预测器更新许可 ──
    output wire         bp_valid,      // 上拍 pre_mem 准备+有效+无冲刷+下级空 → 本拍可更新分支预测器

    // ── μTLB refill 抑制 ──
    output wire         s0_flush       // pre_if 之后有冲刷（含分支）→ 抑制 s0 μTLB refill
);

    // ================================================================
    // 内部寄存器：锁存上拍 valid / ready_go / exc / ertn
    // ================================================================
    (* max_fanout = 64 *) reg  [6:0] v;          // valid_reg
    (* max_fanout = 64 *) reg  [6:0] r;          // readygo_reg
    (* max_fanout = 64 *) reg  [6:0] exc;        // exc_reg
    (* max_fanout = 64 *) reg  [6:0] ertn;       // ertn_reg
    (* max_fanout = 64 *) reg  [6:0] mispred;    // mispred_reg

    always @(posedge clk) begin
        if (reset) begin
            v       <= 7'b0;
            r       <= 7'b1111111;
            exc     <= 7'b0;
            ertn    <= 7'b0;
            mispred <= 7'b0;
        end
        else begin
            v       <= valid_i;
            r       <= readygo_i;
            exc     <= exc_i;
            ertn    <= ertn_i;
            mispred <= mispred_i;
        end
    end

    // ================================================================
    // empty 信号（2 级 LUT）
    //
    //   empty[i] = 本拍第 i 级可接收新数据
    //            = ~v[i] | (r[i] & empty[i+1]),   empty[6] = 1
    //
    //   L1: {e5,e4,e3} 展开到 e6=1，全并行
    //   L2: {e2,e1}     展开到 e3，全并行
    //
    //   最大扇入：e3 = 6 输入 (v3..v5, r3..r5) ≤ LUT6
    // ================================================================
    wire [6:0] empty;

    assign empty[6] = 1'b1;                     // WB 下游始终可接收

    // ── L1: 全并行展开到 e6=1 ──
    assign empty[5] = ~v[5] | r[5];
    assign empty[4] = ~v[4]
                    | (r[4] & ~v[5])
                    | (r[4] &  r[5]);
    assign empty[3] = ~v[3]
                    | (r[3] & ~v[4])
                    | (r[3] &  r[4] & ~v[5])
                    | (r[3] &  r[4] &  r[5]);

    // ── L2: 全并行展开到 e3 ──
    assign empty[2] = ~v[2]
                    | (r[2] & empty[3]);
    assign empty[1] = ~v[1]
                    | (r[1] & ~v[2])
                    | (r[1] &  r[2] & empty[3]);
    // empty[0] 无消费者，不计算
    assign empty[0] = 1'b1;
    // 组合深度：reg → L1(e5,e4,e3) → L2(e2,e1) = 2 级 LUT

    // ================================================================
    // ldata: 本拍使用新数据寄存器
    //
    //   = 上级上拍准备 && 本级上拍准备 && 下级这拍空
    //   | 上级上拍准备 && 本级上拍无效    （气泡填充）
    //
    //   pre_if（i=0）无上级 → r[-1] ≡ 1
    //   wb（i=6）无下级   → empty[7] ≡ 1
    // ================================================================
    assign ldata[0] = (r[0] & empty[1]) | s0_flush | !v[0];
    assign ldata[1] = (r[0] & r[1] & empty[2]) | (r[0] & !v[1]);
    assign ldata[2] = (r[1] & r[2] & empty[3]) | (r[1] & !v[2]);
    assign ldata[3] = (r[2] & r[3] & empty[4]) | (r[2] & !v[3]);
    assign ldata[4] = (r[3] & r[4] & empty[5]) | (r[3] & !v[4]);
    assign ldata[5] = (r[4] & r[5] & empty[6]) | (r[4] & !v[5]);
    assign ldata[6] = (r[5] & r[6])            | (r[5] & !v[6]);

    // ================================================================
    // fs: 后缀冲刷（2 级 LUT）
    //
    //   fs[i] = OR (exc[j] | ertn[j] | mispred[j])  for j = i..6
    //
    //   exc[6]=ertn[6]=0（wb 不接入）, mispred 仅 ex(3) 有效
    //   分组：{6,5}, {4,3}, {2,1} → L1 组内 OR → L2 后缀 OR
    // ================================================================
    wire [6:0] fs;

    // flush source per stage
    wire [6:0] src;
    assign src[0] = (exc[0] | ertn[0]) & ~mispred[3];
    assign src[1] = (exc[1] | ertn[1]) & ~mispred[3];
    assign src[2] = (exc[2] | ertn[2]) & ~mispred[3];
    assign src[3] = exc[3] | ertn[3];
    assign src[4] = exc[4] | ertn[4];
    assign src[5] = exc[5] | ertn[5];
    assign src[6] = 1'b0;

    //后缀 OR(全并行)
    assign fs[6] = src[6];
    assign fs[5] = src[6];
    assign fs[4] = src[5];
    assign fs[3] = src[4] | src[5];
    assign fs[2] = src[3] | src[4] | src[5];
    assign fs[1] = src[2] | src[3] | src[4] | src[5];
    assign fs[0] = src[1] | src[2] | src[3] | src[4] | src[5];

    // ================================================================
    // lvalid: 本级本拍可以呈现数据
    //
    //   = ~r[i] | ~empty[i+1] | (r[i-1] & ~fs[i])
    //
    //   置 0 条件（r && empty && 某条件）：
    //     a. 气泡: ~r[i-1]   （上级上拍未准备）
    //     b. 冲刷: fs[i]     （本级及之后有冲刷信号）
    //
    //   pre_if（i=0）: r[-1] ≡ 1
    // ================================================================
    assign lvalid[0] = (~r[0] | ~empty[1] | ~src[0]) & ~fs[0];
    assign lvalid[1] = (~r[1] | ~empty[2] | (r[0] & ~src[1])) & ~fs[1] & ~mispred[3];
    assign lvalid[2] = (~r[2] | ~empty[3] | (r[1] & ~src[2])) & ~fs[2] & ~mispred[3];
    assign lvalid[3] = (~r[3] | ~empty[4] | (r[2] & ~(src[3] | mispred[3]))) & ~fs[3];
    assign lvalid[4] = (~r[4] | ~empty[5] | (r[3] & ~src[4])) & ~fs[4];
    assign lvalid[5] = (~r[5] | ~empty[6] | (r[4] & ~src[5])) & ~fs[5];
    assign lvalid[6] = (~r[6] | (r[5] & ~src[6])) & ~fs[6];

    // ================================================================
    // lpower: 本拍是否有权发出请求（与有效性正交）
    //
    //   有权 = 上拍未准备 || 使用新数据
    //        = !r[i] || ldata[i]
    //
    //   r[i]=0: 工作进行中，可能需要发完成信号
    //   ldata[i]=1: 新指令到达，需要开始工作
    //   r[i]=1 && ldata[i]=0: 已完成且阻塞 → 无权力
    //
    //   与 lvalid 正交。发送请求处:
    //     can_issue = internal_req && lpower && lvalid
    // ================================================================
    assign lpower[0] = ~r[0] | ldata[0];
    assign lpower[1] = ~r[1] | ldata[1];
    assign lpower[2] = ~r[2] | ldata[2];
    assign lpower[3] = ~r[3] | ldata[3];
    assign lpower[4] = ~r[4] | ldata[4];
    assign lpower[5] = ~r[5] | ldata[5];
    assign lpower[6] = ~r[6] | ldata[6];

    // ================================================================
    // lready: 维持就绪
    //
    //   仅一种情况发：上拍准备 && 下级这拍非空
    //   = r[i] & ~empty[i+1]
    //
    //   本级 ready_go 公式：
    //     stage_ready_go = work_done || !stage_valid || lready
    // ================================================================
    assign lready[0] = v[0] & r[0] & ~empty[1] & ~ldata[0];
    assign lready[1] = v[1] & r[1] & ~empty[2] & ~ldata[1];
    assign lready[2] = v[2] & r[2] & ~empty[3] & ~ldata[2];
    assign lready[3] = v[3] & r[3] & ~empty[4] & ~ldata[3];
    assign lready[4] = v[4] & r[4] & ~empty[5] & ~ldata[4];
    assign lready[5] = v[5] & r[5] & ~empty[6] & ~ldata[5];
    assign lready[6] = 1'b0;

    // ================================================================
    // s0_flush: pre_if(0) 之后有冲刷（含分支）→ 抑制 s0 μTLB refill
    // ================================================================
    assign s0_flush = fs[0] | mispred[3];

    // ================================================================
    // bp_valid: 分支预测器更新许可（PRE_MEM 级，4=pre_mem）
    // ================================================================
    assign bp_valid = r[4] && v[4] && ~fs[4] && empty[5];

endmodule
