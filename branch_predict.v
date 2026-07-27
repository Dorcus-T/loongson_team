`include "mycpu.h"

module branch_predict (
    input  wire                     clk,
    input  wire                     reset,

    // ===== 预测接口（IF/pre_if 级使用，与 I-Cache 并行）=====
    input  wire [29:0]              lookup_pc_i,         // PC[31:2]，查表地址
    output wire                     btb_hit_o,           // BTB 命中（组合输出，0气泡关键）
    output wire [29:0]              btb_target_o,        // BTB 预测目标（组合输出）
    output wire [ 1:0]              btb_counter_o,       // BTB 2-bit 计数器
    output wire [ 4:0]              btb_index_o,         // BTB 命中项索引
    output wire                     ras_hit_o,           // RAS CAM 命中（组合输出）
    output wire [29:0]              ras_target_o,        // RAS 栈顶目标（组合输出）
    output wire [ 3:0]              ras_index_o,         // RAS CAM 命中索引

    // ===== 更新接口（ID/EX 级使用，不在关键路径）=====
    input  wire                     update_en,           // 更新使能
    input  wire [`BP_BUS_WD-1:0]    update_bus           // 更新数据总线（EX 编码）
);

    // ── 解码 update_bus ──
    wire [29:0] update_pc;
    wire        update_is_branch;
    wire [ 1:0] update_br_type;
    wire        update_taken;
    wire [29:0] update_target;
    wire [ 4:0] update_btb_index;
    wire        update_push_ras;
    wire [29:0] update_ras_data;
    wire        update_pop_ras;
    wire        update_delete_entry;

    assign {
        update_pc,          // 103:74
        update_is_branch,   // 73
        update_br_type,     // 72:71
        update_taken,       // 70
        update_target,      // 69:40
        update_btb_index,   // 39:35
        update_push_ras,    // 34
        update_ras_data,    // 33:4
        update_pop_ras,     // 3
        update_delete_entry // 2
    } = update_bus;

    // ============================================================
    // 输入寄存器：切断 IF 级 MUX → 预测器 CAM 的长组合路径
    // ============================================================
    reg [29:0] lookup_pc_r;

    always @(posedge clk) begin
        if (reset)
            lookup_pc_r <= 30'd0;
        else
            lookup_pc_r <= lookup_pc_i;
    end

    // ============================================================
    // BTB 表：32 项，每项 {tag[30], target[30], counter[2], valid[1]}
    // ============================================================
    reg  [29:0] btb_tag    [0:`BTB_ENTRIES-1];
    reg  [29:0] btb_target [0:`BTB_ENTRIES-1];
    reg  [ 1:0] btb_counter[0:`BTB_ENTRIES-1];
    reg         btb_valid  [0:`BTB_ENTRIES-1];

    // 查找逻辑：32 路并行比较，纯组合
    wire [`BTB_ENTRIES-1:0] btb_match;
    genvar i;
    generate
        for (i = 0; i < `BTB_ENTRIES; i = i + 1) begin : btb_cam
            assign btb_match[i] = btb_valid[i] && (btb_tag[i] == lookup_pc_r);
        end
    endgenerate

    // 命中信号
    assign btb_hit_o = |btb_match;

    // 优先编码器（取第一个命中项）
    wire [4:0] btb_match_index;
    assign btb_match_index = btb_match[ 0] ? 5'd0  :
                             btb_match[ 1] ? 5'd1  :
                             btb_match[ 2] ? 5'd2  :
                             btb_match[ 3] ? 5'd3  :
                             btb_match[ 4] ? 5'd4  :
                             btb_match[ 5] ? 5'd5  :
                             btb_match[ 6] ? 5'd6  :
                             btb_match[ 7] ? 5'd7  :
                             btb_match[ 8] ? 5'd8  :
                             btb_match[ 9] ? 5'd9  :
                             btb_match[10] ? 5'd10 :
                             btb_match[11] ? 5'd11 :
                             btb_match[12] ? 5'd12 :
                             btb_match[13] ? 5'd13 :
                             btb_match[14] ? 5'd14 :
                             btb_match[15] ? 5'd15 :
                             btb_match[16] ? 5'd16 :
                             btb_match[17] ? 5'd17 :
                             btb_match[18] ? 5'd18 :
                             btb_match[19] ? 5'd19 :
                             btb_match[20] ? 5'd20 :
                             btb_match[21] ? 5'd21 :
                             btb_match[22] ? 5'd22 :
                             btb_match[23] ? 5'd23 :
                             btb_match[24] ? 5'd24 :
                             btb_match[25] ? 5'd25 :
                             btb_match[26] ? 5'd26 :
                             btb_match[27] ? 5'd27 :
                             btb_match[28] ? 5'd28 :
                             btb_match[29] ? 5'd29 :
                             btb_match[30] ? 5'd30 :
                             btb_match[31] ? 5'd31 : 5'd0;
    assign btb_index_o = btb_match_index;

    // 目标地址和计数器（用 index 做 MUX 选通）
    // 注意：未命中时 btb_match_index=0，输出为 entry0 的垃圾数据。
    // IF 阶段必须用 btb_hit_o 门控后使用，此处不引入 MUX 以保持 0 气泡时序路径。
    assign btb_target_o  = btb_target[btb_match_index];
    assign btb_counter_o = btb_counter[btb_match_index];

    // ============================================================
    // RAS CAM 表：16 项，识别 JIRL (ret) 指令的 PC
    // ============================================================
    reg  [29:0] ras_cam_tag   [0:`RAS_CAM_ENTRIES-1];
    reg         ras_cam_valid [0:`RAS_CAM_ENTRIES-1];

    wire [`RAS_CAM_ENTRIES-1:0] ras_match;
    generate
        for (i = 0; i < `RAS_CAM_ENTRIES; i = i + 1) begin : ras_cam_cmp
            assign ras_match[i] = ras_cam_valid[i] && (ras_cam_tag[i] == lookup_pc_r);
        end
    endgenerate

    assign ras_hit_o = |ras_match;

    wire [3:0] ras_match_index;
    assign ras_match_index = ras_match[ 0] ? 4'd0  :
                             ras_match[ 1] ? 4'd1  :
                             ras_match[ 2] ? 4'd2  :
                             ras_match[ 3] ? 4'd3  :
                             ras_match[ 4] ? 4'd4  :
                             ras_match[ 5] ? 4'd5  :
                             ras_match[ 6] ? 4'd6  :
                             ras_match[ 7] ? 4'd7  :
                             ras_match[ 8] ? 4'd8  :
                             ras_match[ 9] ? 4'd9  :
                             ras_match[10] ? 4'd10 :
                             ras_match[11] ? 4'd11 :
                             ras_match[12] ? 4'd12 :
                             ras_match[13] ? 4'd13 :
                             ras_match[14] ? 4'd14 :
                             ras_match[15] ? 4'd15 : 4'd0;
    assign ras_index_o = ras_match_index;

    // 更新侧 RAS CAM 全相联匹配（独立于 BTB 索引，避免冷启动退化）
    wire [`RAS_CAM_ENTRIES-1:0] update_ras_match;
    genvar g;
    generate
        for (g = 0; g < `RAS_CAM_ENTRIES; g = g + 1) begin : update_ras_cam_cmp
            assign update_ras_match[g] = ras_cam_valid[g] && (ras_cam_tag[g] == update_pc);
        end
    endgenerate

    wire update_ras_hit;
    assign update_ras_hit = |update_ras_match;

    // ============================================================
    // RAS 栈：8 项 × 30-bit，纯寄存器实现（读零延迟）
    // ============================================================
    reg  [29:0] ras_stack [0:`RAS_STACK_DEPTH-1];
    reg  [`RAS_PTR_WD-1:0] ras_ptr;              // 指向下一个空位
    reg  [ 3:0] ras_cam_alloc_ptr;               // RAS CAM 轮转分配指针

    // 栈顶 = ras_stack[ras_ptr - 1]
    wire [29:0] ras_stack_top;
    assign ras_stack_top = (ras_ptr == `RAS_PTR_WD'd0) ? 30'd0 : ras_stack[ras_ptr - `RAS_PTR_WD'd1];

    assign ras_target_o = ras_stack_top;

    // ============================================================
    // Tree-PLRU 替换策略（31 bit 树，管理 32 项 BTB）
    // ============================================================
    reg [30:0] plru_tree;  // 0=左子更久未用, 1=右子更久未用

    // 无效项检测
    wire [`BTB_ENTRIES-1:0] btb_invalid;
    generate
        for (i = 0; i < `BTB_ENTRIES; i = i + 1) begin : btb_inv_gen
            assign btb_invalid[i] = ~btb_valid[i];
        end
    endgenerate

    wire invalid_exists;
    assign invalid_exists = |btb_invalid;

    // 无效项优先编码器
    wire [4:0] invalid_index;
    assign invalid_index = btb_invalid[ 0] ? 5'd0  :
                           btb_invalid[ 1] ? 5'd1  :
                           btb_invalid[ 2] ? 5'd2  :
                           btb_invalid[ 3] ? 5'd3  :
                           btb_invalid[ 4] ? 5'd4  :
                           btb_invalid[ 5] ? 5'd5  :
                           btb_invalid[ 6] ? 5'd6  :
                           btb_invalid[ 7] ? 5'd7  :
                           btb_invalid[ 8] ? 5'd8  :
                           btb_invalid[ 9] ? 5'd9  :
                           btb_invalid[10] ? 5'd10 :
                           btb_invalid[11] ? 5'd11 :
                           btb_invalid[12] ? 5'd12 :
                           btb_invalid[13] ? 5'd13 :
                           btb_invalid[14] ? 5'd14 :
                           btb_invalid[15] ? 5'd15 :
                           btb_invalid[16] ? 5'd16 :
                           btb_invalid[17] ? 5'd17 :
                           btb_invalid[18] ? 5'd18 :
                           btb_invalid[19] ? 5'd19 :
                           btb_invalid[20] ? 5'd20 :
                           btb_invalid[21] ? 5'd21 :
                           btb_invalid[22] ? 5'd22 :
                           btb_invalid[23] ? 5'd23 :
                           btb_invalid[24] ? 5'd24 :
                           btb_invalid[25] ? 5'd25 :
                           btb_invalid[26] ? 5'd26 :
                           btb_invalid[27] ? 5'd27 :
                           btb_invalid[28] ? 5'd28 :
                           btb_invalid[29] ? 5'd29 :
                           btb_invalid[30] ? 5'd30 :
                           btb_invalid[31] ? 5'd31 : 5'd0;

    // PLRU 遍历函数：从根走到叶子
    function [4:0] plru_get_lru;
        input [30:0] tree;
        integer lvl;
        reg [5:0] node;
        begin
            node = 6'd0;
            for (lvl = 0; lvl < 5; lvl = lvl + 1) begin
                node = (node << 1) + 6'd1 + {5'd0, tree[node]};
            end
            plru_get_lru = node[4:0] - 5'd31;
        end
    endfunction

    // 最终替换索引：无效优先 → PLRU
    wire [4:0] replace_index;
    assign replace_index = invalid_exists ? invalid_index : plru_get_lru(plru_tree);

    // PLRU 节点路径（命中/建项时标记 MRU，从叶父节点向根方向翻转 5 层）
    // 叶父节点 = (entry+30)>>1，范围 15~30（plru_tree 内部节点，非虚拟叶节点）
    // 逐层: (node-1)>>1 → level3 → level2 → level1 → root(0)
    // 命中路径（基于 update_btb_index）
    wire [4:0] plru_hit_l4 = (update_btb_index + 5'd30) >> 1;
    wire [4:0] plru_hit_l3 = (plru_hit_l4 - 5'd1) >> 1;
    wire [4:0] plru_hit_l2 = (plru_hit_l3 - 5'd1) >> 1;
    wire [4:0] plru_hit_l1 = (plru_hit_l2 - 5'd1) >> 1;
    wire [4:0] plru_hit_l0 = (plru_hit_l1 - 5'd1) >> 1;
    // 建项路径（基于 replace_index）
    wire [4:0] plru_new_l4 = (replace_index + 5'd30) >> 1;
    wire [4:0] plru_new_l3 = (plru_new_l4 - 5'd1) >> 1;
    wire [4:0] plru_new_l2 = (plru_new_l3 - 5'd1) >> 1;
    wire [4:0] plru_new_l1 = (plru_new_l2 - 5'd1) >> 1;
    wire [4:0] plru_new_l0 = (plru_new_l1 - 5'd1) >> 1;

    // ============================================================
    // BTB/BHT 更新逻辑（含 PLRU）
    // ============================================================
    integer j;
    always @(posedge clk) begin
        if (reset) begin
            for (j = 0; j < `BTB_ENTRIES; j = j + 1) begin
                btb_valid[j]   <= 1'b0;
                btb_tag[j]     <= 30'd0;
                btb_target[j]  <= 30'd0;
                btb_counter[j] <= 2'b00;
            end
            plru_tree <= 31'd0;
        end
        else if (update_delete_entry && btb_valid[update_btb_index]
                 && btb_tag[update_btb_index] == update_pc) begin
            // 删除脏 BTB 项
            btb_valid[update_btb_index] <= 1'b0;
        end
        else if (update_en) begin
            if (btb_valid[update_btb_index]
                && btb_tag[update_btb_index] == update_pc) begin
                // ===== BTB 命中 =====
                if (update_br_type != 2'b10 && update_br_type != 2'b11) begin
                    // 非 call/ret：更新 BHT 计数器
                    if (update_taken) begin
                        if (btb_counter[update_btb_index] < 2'b11)
                            btb_counter[update_btb_index] <= btb_counter[update_btb_index] + 1'b1;
                    end
                    else begin
                        if (btb_counter[update_btb_index] > 2'b00)
                            btb_counter[update_btb_index] <= btb_counter[update_btb_index] - 1'b1;
                    end
                end
                // 所有命中（含 call/ret）：更新 PLRU 标记为 MRU（5层全部翻转，含根节点）
                plru_tree[plru_hit_l4] <= ~plru_tree[plru_hit_l4];
                plru_tree[plru_hit_l3] <= ~plru_tree[plru_hit_l3];
                plru_tree[plru_hit_l2] <= ~plru_tree[plru_hit_l2];
                plru_tree[plru_hit_l1] <= ~plru_tree[plru_hit_l1];
                plru_tree[plru_hit_l0] <= ~plru_tree[plru_hit_l0];
            end
            else if (update_is_branch && update_taken) begin
                // ===== BTB miss + 实际跳转 → 建项（用 PLRU 选替换位）=====
                btb_valid[replace_index]   <= 1'b1;
                btb_tag[replace_index]     <= update_pc;
                btb_target[replace_index]  <= update_target;
                btb_counter[replace_index] <= 2'b10;  // weakly taken
                // 新项标记为 MRU（5层全部翻转，含根节点）
                plru_tree[plru_new_l4] <= ~plru_tree[plru_new_l4];
                plru_tree[plru_new_l3] <= ~plru_tree[plru_new_l3];
                plru_tree[plru_new_l2] <= ~plru_tree[plru_new_l2];
                plru_tree[plru_new_l1] <= ~plru_tree[plru_new_l1];
                plru_tree[plru_new_l0] <= ~plru_tree[plru_new_l0];
            end
        end
    end

    // ============================================================
    // RAS 栈 + CAM 更新
    // ============================================================
    always @(posedge clk) begin
        if (reset) begin
            for (j = 0; j < `RAS_STACK_DEPTH; j = j + 1)
                ras_stack[j] <= 30'd0;
            for (j = 0; j < `RAS_CAM_ENTRIES; j = j + 1) begin
                ras_cam_valid[j] <= 1'b0;
                ras_cam_tag[j]   <= 30'd0;
            end
            ras_ptr           <= `RAS_PTR_WD'd0;
            ras_cam_alloc_ptr <= 4'd0;
        end
        else if (update_en) begin
            // RAS push（BL/call 指令）
            if (update_push_ras && ras_ptr < `RAS_STACK_DEPTH) begin
                ras_stack[ras_ptr] <= update_ras_data;
                ras_ptr             <= ras_ptr + `RAS_PTR_WD'd1;
            end
            // RAS pop（JIRL/ret 指令）
            if (update_pop_ras && ras_ptr > `RAS_PTR_WD'd0) begin
                ras_ptr <= ras_ptr - `RAS_PTR_WD'd1;
            end
            // RAS CAM 建项（ret 指令独立轮转分配，不再依赖 BTB 索引）
            if (update_br_type == 2'b11 && !update_ras_hit) begin
                ras_cam_valid[ras_cam_alloc_ptr] <= 1'b1;
                ras_cam_tag[ras_cam_alloc_ptr]   <= update_pc;
                ras_cam_alloc_ptr                 <= ras_cam_alloc_ptr + 4'd1;
            end
        end
    end

endmodule
