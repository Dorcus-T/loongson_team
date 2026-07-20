`include "mycpu.h"

module mem_stage (
    input  wire                         clk,
    input  wire                         reset,
    // allowin
    input  wire                         wb_allowin,            // WB阶段允许接收
    output wire                         mem_allowin,           // MEM阶段允许接收
    // 来自pre_mem阶段
    input  wire                         pre_mem_to_mem_valid,  // PRE_MEM到MEM有效
    input  wire [`PRE_MEM_TO_MEM_BUS_WD-1:0] pre_mem_to_mem_bus, // 来自PRE_MEM的总线
    input  wire                         pre_mem_ready_go,     // PRE_MEM阶段就绪标志
    // 输出给wb阶段
    output wire                         mem_to_wb_valid,       // MEM到WB有效
    output wire [`MEM_TO_WB_BUS_WD-1:0] mem_to_wb_bus,         // MEM到WB总线
    output wire                         mem_ready_go,          // MEM阶段就绪标志
     // 来自 DCache
    input  wire [31:0]                  dcache_cpu_rdata,      // DCache 读数据
    input  wire                         dcache_cpu_data_ok,    // DCache 数据就绪
    // 前递控制
    output wire [ 4:0]                  mem_to_id_dest,        // MEM阶段写回寄存器号
    output wire [31:0]                  mem_to_id_result,      // MEM阶段计算结果
    output wire                         mem_to_id_data_ok,     // MEM前递给id的数据是否准备好
    // 异常冲刷
    input  wire                         wb_exc_valid,          // WB阶段异常冲刷流水线
    input  wire                         wb_ertn_flush,         // WB阶段有ertn指令则冲刷流水线
    output wire                         mem_exc_valid,         // 防止有异常时pre_mem阶段发出访存请求
    output wire                         mem_ertn_flush,        // 防止ertn位于mem时,pre_mem发出访存请求
    // csr与ertn冒险
    output wire                         mem_csr_we,            // mem阶段确定要写csr
    output wire [13:0]                  mem_csr_num,           // mem阶段写csr的号码
    // cpu可接受数据
    output wire                         dcache_cpu_accept      // MEM可接受 cache 读数据
);

    reg  mem_valid;                                   // MEM阶段有效标志
    reg  [`PRE_MEM_TO_MEM_BUS_WD-1:0] pre_mem_to_mem_bus_r; // 锁存的PRE_MEM级数据
    reg  [31:0] load_data_r;                          // 锁存 cache 返回的读数据（打断长组合路径）
    reg         load_data_latched;                    // 数据已锁存，本拍正在处理

    // ========== 异常信号 ==========
    wire [15:0] mem_exc;
    wire        mem_rf_valid;             // mem阶段重取指标志

    // ========== 控制信号解析 ==========
    wire        tlbrd_en;                 // WB读tlb并写csr
    wire        tlbwr_en;                 // tlbwrWB写tlb
    wire        tlbfill_en;
    wire        res_from_mem;             // 结果是否来自存储器
    wire        gr_we;                    // 寄存器写使能
    wire [ 4:0] dest;                     // 目标寄存器号
    wire [31:0] alu_result;               // ALU计算结果（地址）
    wire [31:0] mem_pc;                   // 指令PC
    wire [31:0] final_result;             // 最终结果（来自ALU或存储器）
    wire        ertn_flush;               // 异常返回冲刷信号
    wire [ 2:0] mem_size;                 // 访存大小
    wire        mem_sign_ext;             // 符号扩展标志
    // 访存数据控制信号
    wire [ 1:0] offset;                   // 偏移量，地址低两位
    wire [31:0] shift_data;               // 偏移后的数据
    wire [31:0] data_result;              // 最终读的数据
    // csr交互信号
    wire        res_from_csr;             // 结果来自csr寄存器堆
    wire [31:0] csr_rvalue;               // csr读数据
    wire        csr_we;                   // csr写使能
    wire [31:0] csr_wmask;                // csr写掩码
    wire [31:0] csr_wvalue;               // csr写数据
    // 计数器数值筛选
    wire        res_from_timer;           // 结果来自计数器
    wire [31:0] timer_finalval;           // 筛选后的计数器读取数据
    // 访存指令
    wire        is_mem_inst;              // 是访存指令
    wire        mem_we;                   // 存储器写使能

    `ifdef DIFFTEST_EN
    // difftest 信号
    wire [31:0] dift_csr_data;
    wire        dift_csr_rstat_en;
    wire [ 7:0] dift_inst_st_en;
    wire [ 7:0] dift_inst_ld_en;
    wire        dift_cnt_inst;
    wire [63:0] dift_timer_64;
    wire [31:0] dift_id_inst;
    wire [31:0] dift_vaddr;
    wire [31:0] dift_st_data;
    `else
    // 占位 dummy wire（保持总线位宽不变）
    wire [209:0] _unused_diff_pad;
    `endif

    // ========== 解析来自EX阶段的总线 ==========
    assign {
        `ifdef DIFFTEST_EN
        dift_csr_data,       // 452:421 csr读数据 for difftest
        dift_csr_rstat_en,   // 420     csr estat读使能 for difftest
        dift_inst_st_en,     // 419:412 store使能 for difftest
        dift_inst_ld_en,     // 411:404 load使能 for difftest
        dift_cnt_inst,       // 403     计数器指令 for difftest
        dift_timer_64,       // 402:339 定时器值 for difftest
        dift_id_inst,        // 338:307 指令编码 for difftest
        dift_vaddr,          // 306:275 load/store虚地址 for difftest
        dift_st_data,        // 274:243 store数据 for difftest
        `else
        _unused_diff_pad,   // 占位：保持非difftest字段bit位置不变
        `endif
        tlbrd_en,            // 242     tlbrd使能
        tlbwr_en,            // 241     tlbwf使能
        tlbfill_en,          // 240
        mem_rf_valid,        // 239     重取指标志
        is_mem_inst,         // 238     是访存指令
        mem_we,              // 237     存储器写使能
        timer_finalval,      // 236:205 筛选后的计数器数据
        res_from_timer,      // 204     结果来自计数器
        res_from_csr,        // 203     结果来自csr寄存器堆
        mem_csr_num,         // 202:189 csr号码
        csr_rvalue,          // 188:157 csr读数据
        csr_we,              // 156      csr写使能
        csr_wmask,           // 155:124 csr写掩码
        csr_wvalue,          // 123:92  csr写数据
        ertn_flush,          // 91      异常返回冲刷信号
        mem_exc,             // 90:75   异常类型
        res_from_mem,        // 74      结果来源
        mem_sign_ext,        // 73      符号扩展标志
        mem_size,            // 72:70   访存大小
        gr_we,               // 69      寄存器写使能
        dest,                // 68:64   目标寄存器号
        alu_result,          // 63:32   ALU结果
        mem_pc               // 31:0    PC
    } = pre_mem_to_mem_bus_r;

    `ifdef DIFFTEST_EN
    wire [31:0] dift_paddr;         // load/store物理地址 for difftest
    assign dift_paddr = alu_result; // TODO: 替换为MMU转换后的物理地址

    // st.b/st.h 按地址偏移定位到正确的 byte lane
    wire [ 1:0] st_addr_offset = alu_result[1:0];
    wire [31:0] dift_st_data_masked;
    assign dift_st_data_masked = mem_we ? (
        |mem_size[0] ? (dift_st_data[7:0] << (st_addr_offset * 8)) :
        |mem_size[1] ? (dift_st_data[15:0] << ({st_addr_offset[1], 1'b0} * 8)) :
        dift_st_data
    ) : dift_st_data;
    `endif

    // ========== 输出到WB阶段的总线 ==========
    assign mem_to_wb_bus = {
        `ifdef DIFFTEST_EN
        dift_csr_data,       // 443:412 csr读数据 for difftest
        dift_csr_rstat_en,   // 411     csr estat读使能 for difftest
        dift_inst_st_en,     // 410:403 store使能 for difftest
        dift_inst_ld_en,     // 402:395 load使能 for difftest
        dift_cnt_inst,       // 394     计数器指令 for difftest
        dift_timer_64,       // 393:330 定时器值 for difftest
        dift_id_inst,        // 329:298 指令编码 for difftest
        dift_vaddr,          // 297:266 load/store虚地址 for difftest
        dift_st_data_masked, // 265:234 store数据 for difftest (st.b/h 已截位)
        dift_paddr,          // 233:202 load/store物理地址 for difftest
        `else
        242'd0,              // 占位：保持非difftest字段bit位置不变
        `endif
        tlbrd_en,            // 201     tlbrd使能
        tlbwr_en,            // 200     tlbwf使能
        tlbfill_en,          // 199
        mem_rf_valid,        // 198     重取指标志
        mem_csr_num,         // 197:184 csr号码
        csr_we,              // 183      csr写使能
        csr_wmask,           // 182:151 csr写掩码
        csr_wvalue,          // 150:119 csr写数据
        ertn_flush,          // 118     异常返回冲刷信号
        mem_exc,             // 117:102 异常类型
        alu_result,          // 101:70  传递异常访存地址
        gr_we,               // 69      寄存器写使能
        dest,                // 68:64   目标寄存器号
        final_result,        // 63:32   最终结果
        mem_pc               // 31:0    PC
    };

    // ========== 流水线控制 ==========
    // load:  数据锁存到 load_data_r 后下一拍就绪（打断 cache→MEM→ID 长组合路径）
    // store: 写请求已在 PRE_MEM 发出，MEM 恒就绪（避免错过 cache write_done 脉冲）
    // 其他:  恒就绪
    assign mem_ready_go    = mem_valid && (is_mem_inst && !mem_we && !mem_exc_valid) ? load_data_latched : 1'b1;
    assign mem_allowin     = pre_mem_ready_go && mem_ready_go && (wb_allowin || !mem_valid);
    assign mem_to_wb_valid = mem_valid;

    // ========== DCache 数据接受 ==========
    // load 等待数据时即拉高 accept，数据到达拍锁入 load_data_r
    assign dcache_cpu_accept = mem_valid && is_mem_inst && !mem_we && !load_data_latched;

    // 访存级有效标志更新
    always @(posedge clk) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            mem_valid <= 1'b0;
        end
        else if (mem_allowin) begin
            mem_valid <= pre_mem_to_mem_valid;
        end
        else if (mem_ready_go && wb_allowin) begin
            mem_valid <= 1'b0;
        end
    end
    // 访存级数据传递
    always @(posedge clk) begin
        if (mem_allowin) begin
            pre_mem_to_mem_bus_r <= pre_mem_to_mem_bus;
        end
    end

    // ========== load 数据锁存控制（打断 cache→MEM→ID 长组合路径） ==========
    wire latch_data;
    assign latch_data = mem_valid && is_mem_inst && !mem_we && !load_data_latched && dcache_cpu_data_ok;

    always @(posedge clk) begin
        if (latch_data) begin
            load_data_r <= dcache_cpu_rdata;
        end
    end

    always @(posedge clk) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            load_data_latched <= 1'b0;
        end
        else if (mem_allowin) begin
            load_data_latched <= 1'b0;
        end
        else if (latch_data) begin
            load_data_latched <= 1'b1;
        end
    end

    // ========== csr写文件写回控制 ==========
    assign mem_csr_we = csr_we && mem_valid && !mem_exc_valid;

    // ========== 存储器读数据处理（字节/半字/字，支持符号扩展） ==========
    // 数据源：已锁存则用寄存器（打断长组合路径），否则直通 cache 输出
    wire [31:0] mem_rdata;
    assign mem_rdata = load_data_latched ? load_data_r : dcache_cpu_rdata;

    assign offset = alu_result[1:0];

    // 移位对齐（将目标数据移到最低位）
    assign shift_data = mem_rdata >> (offset * 8);

    // 根据访存大小提取并扩展
    assign data_result = mem_size[2] ? mem_rdata :                                             // 字
                         mem_size[1] ? {{16{mem_sign_ext & shift_data[15]}}, shift_data[15:0]} :  // 半字
                         mem_size[0] ? {{24{mem_sign_ext & shift_data[7]}}, shift_data[7:0]} :    // 字节
                         32'b0;

    // 最终结果：来自存储器或ALU或者CSR
    assign final_result = res_from_mem   ? data_result   :
                          res_from_csr   ? csr_rvalue    :
                          res_from_timer ? timer_finalval :
                          alu_result;

    // ========== 前递输出 ==========
    assign mem_to_id_dest    = dest & {5{mem_valid}} & {5{gr_we}};
    assign mem_to_id_result  = final_result;
    assign mem_to_id_data_ok = res_from_mem ? load_data_latched : 1'b1;

    // ========== 检测异常与ertn ==========
    assign mem_exc_valid  = (|mem_exc || mem_rf_valid) && mem_valid;
    assign mem_ertn_flush = ertn_flush && mem_valid;  // mem的ertn要发挥作用必须得有效

endmodule
