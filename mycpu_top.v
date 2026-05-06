`include "mycpu.h"

module mycpu_top(
    // ========== 系统时钟和复位 ==========
    input aclk,                           // 系统时钟
    input aresetn,                        // 低电平有效复位信号
    // ========== AXI3 Master 读地址通道 ==========
    output [3 :0]  arid,
    output [31:0]  araddr,
    output [7 :0]  arlen,
    output [2 :0]  arsize,
    output [1 :0]  arburst,
    output [1 :0]  arlock,
    output [3 :0]  arcache,
    output [2 :0]  arprot,
    output         arvalid,
    input          arready,
    // ========== AXI3 Master 读数据通道 ==========
    input  [3 :0]  rid,
    input  [31:0]  rdata,
    input  [1 :0]  rresp,
    input          rlast,
    input          rvalid,
    output         rready,
    // ========== AXI3 Master 写地址通道 ==========
    output [3 :0]  awid,
    output [31:0]  awaddr,
    output [7 :0]  awlen,
    output [2 :0]  awsize,
    output [1 :0]  awburst,
    output [1 :0]  awlock,
    output [3 :0]  awcache,
    output [2 :0]  awprot,
    output         awvalid,
    input          awready,
    // ========== AXI3 Master 写数据通道 ==========
    output [3 :0]  wid,
    output [31:0]  wdata,
    output [3 :0]  wstrb,
    output         wlast,
    output         wvalid,
    input          wready,
    // ========== AXI3 Master 写响应通道 ==========
    input  [3 :0]  bid,
    input  [1 :0]  bresp,
    input          bvalid,
    output         bready,   
    // ========== 调试接口（波形追踪） ==========
    output [31:0] debug_wb_pc,           // WB阶段PC值
    output [3:0] debug_wb_rf_we,         // 寄存器写使能（调试用）
    output [4:0] debug_wb_rf_wnum,       // 写回的寄存器号
    output [31:0] debug_wb_rf_wdata      // 写回的数据
);

    // ========== 复位信号处理（将低有效转换为高有效）==========
    reg reset;
    wire clk = aclk;
    always @(posedge clk) reset <= ~aresetn;

    // ========== 流水线控制信号（各级之间的握手信号） ==========
    wire id_allowin;                     // ID阶段允许接收（来自ID）
    wire ex_allowin;                     // EX阶段允许接收（来自EX）
    wire mem_allowin;                    // MEM阶段允许接收（来自MEM）
    wire wb_allowin;                     // WB阶段允许接收（来自WB）

    // 各级流水线有效标志
    wire if_to_id_valid;                 // IF -> ID 有效
    wire id_to_ex_valid;                 // ID -> EX 有效
    wire ex_to_mem_valid;                // EX -> MEM 有效
    wire mem_to_wb_valid;                // MEM -> WB 有效

    // ========== 流水线总线（各级之间的数据传递） ==========
    wire [`IF_TO_ID_BUS_WD -1:0]  if_to_id_bus;   // IF -> ID 总线
    wire [`ID_TO_EX_BUS_WD -1:0]  id_to_ex_bus;   // ID -> EX 总线
    wire [`EX_TO_MEM_BUS_WD -1:0] ex_to_mem_bus;  // EX -> MEM 总线
    wire [`MEM_TO_WB_BUS_WD -1:0] mem_to_wb_bus;  // MEM -> WB 总线
    wire [`WB_TO_RF_BUS_WD -1:0]  wb_to_rf_bus;   // WB -> 寄存器文件
    wire [`WB_TO_CSR_BUS_WD -1:0] wb_to_csr_bus;  // WB -> CSR总线
    wire [`BR_BUS_WD -1:0] br_bus;                // 分支总线

    // ========== 数据前递信号（解决RAW数据冒险） ==========
    // 前递控制：各级的目的寄存器号
    wire [4:0] ex_to_id_dest;            // EX阶段写回的寄存器号
    wire [4:0] mem_to_id_dest;           // MEM阶段写回的寄存器号
    wire [4:0] wb_to_id_dest;            // WB阶段写回的寄存器号

    // 前递数据：各级的计算结果
    wire [31:0] ex_to_id_result;         // EX阶段计算结果
    wire [31:0] mem_to_id_result;        // MEM阶段计算结果
    wire [31:0] wb_to_id_result;         // WB阶段计算结果
    wire        ex_to_id_load_op;        // EX阶段是否为加载指令（用于load-use检测）
    wire        mem_to_id_data_ok;       // MEM前递给id的数据是否准备好

    // ========== 异常信号与ertn ==========
    wire ex_exc_valid;       // EX阶段异常有效
    wire wb_exc_valid;       // WB阶段异常有效
    wire wb_ertn_flush;      // WB阶段有ertn指令
    wire mem_exc_valid;      // MEM阶段异常有效
    wire mem_ertn_flush;     // MEM阶段有ertn指令
    wire ex_ertn_flush;

    // ========== 重取指信号 ==========
    wire exc_not_rf;         // wb发if，csr除中断外被rf覆盖异常信号
    wire rf_valid;           // rf信号
    wire [31:0] wb_pc_back;  // 发if重取指pc
    
    // ========== csr有关信号 ========== 
    wire [31:0] exc_entry;          // 异常入口地址，CSR输出给IF阶段，用于异常发生时PC跳转
    wire [31:0] exc_back_pc;        // 异常返回地址，CSR输出给IF阶段，用于ERTN指令恢复PC
    wire [31:0] csr_rvalue;         // CSR读数据，CSR输出给ID阶段，用于csrrd指令读取CSR值
    wire [13:0] csr_id_num;         // CSR读号码，ID阶段输出给CSR，用于指定要读取的CSR寄存器
    wire        has_int;            // 中断有效标志，CSR输出给ID阶段，表示有待处理的中断
    wire [31:0] coreid_in;          // 核心ID输入，来自顶层，用于初始化TID寄存器
    wire        hw_inter;           // 硬件中断有效标志，来自顶层，表示有外部硬件中断
    wire [7:0]  hw_inter_num;       // 硬件中断号，来自顶层，对应ESTAT寄存器的bit2-9
    wire        ipi_inter;          // 核间中断，来自顶层，对应ESTAT寄存器的bit12
    wire [13:0] ex_csr_num;         // ex阶段写csr寄存器号
    wire        ex_csr_we;          // ex阶段写csr使能
    wire [13:0] mem_csr_num;        // meme阶段写csr寄存器号
    wire        mem_csr_we;         // mem阶段写csr使能
    wire [13:0] wb_csr_num;         // wb阶段写csr寄存器号
    wire        wb_csr_we;          // wb阶段写csr使能
    // 特殊csr相关信号
    wire [1:0]  plv_out;            // 特权等级输出
    wire [5:0]  ecode_out;          // 异常码输出
    wire [1:0]  da_pg_out;          // 虚实转换方式输出
    wire [63:0] dmw_out;            // dmw输出
    wire [`TLBCSR_BUS_WD -1:0] tlbcsr_bus; // tlb相关csr输出 

    // ========== 与MMU交互信号 ==========
    wire [31:0] if_to_mmu_vaddr;    // if发mmu虚地址
    wire [31:0] ex_to_mmu_vaddr;    // ex发mmu虚地址
    wire [35:0] vtlb_enop;          // 发mmu tlbsrch，invtlb使能即操作数
    wire [1:0]  ld_and_str;         // 发mmu load和store信号
    wire [2:0]  tlbrwf_valid;       // tlbrd tlbwr tlbfill使能
    wire [31:0] paddr_to_if;        // 发if实地址
    wire [2:0]  if_tlb_exc;         // 发if tlb相关异常
    wire [1:0]  if_mat;             // if 访存方式，//占位
    wire [31:0] paddr_to_ex;        // 发ex实地址
    wire [5:0]  srch_value;         // 发ex tlbsrch查询结果
    wire [4:0]  ex_tlb_exc;         // 发ex tlb相关异常
    wire [1:0]  ex_mat;             // ex 访存方式
    wire [`TLBRD_BUS_WD - 1:0] tlbrd_value; // 发csr tlbrd使能和数据

    // ========== 计数器数值 ==========
    wire [63:0] timer_value;        // 计数器输出

    // ========== SRAM侧内部连线（CPU与桥模块之间） ==========
    // --- 取指 SRAM 信号 ---
    wire        inst_sram_req;
    wire        inst_sram_wr;
    wire [1:0]  inst_sram_size;
    wire [3:0]  inst_sram_wstrb;
    wire [31:0] inst_sram_addr;
    wire [31:0] inst_sram_wdata;
    wire        inst_sram_addr_ok;
    wire        inst_sram_data_ok;
    wire [31:0] inst_sram_rdata;
    // --- 数据 SRAM 信号 ---
    wire        data_sram_req;
    wire        data_sram_wr;
    wire [1:0]  data_sram_size;
    wire [3:0]  data_sram_wstrb;
    wire [31:0] data_sram_addr;
    wire [31:0] data_sram_wdata;
    wire        data_sram_addr_ok;
    wire        data_sram_data_ok;
    wire [31:0] data_sram_rdata;
    // ============================================================
    // 第一阶段：取指阶段 (IF - Instruction Fetch)
    // ============================================================
    if_stage if_stage(
    .clk(clk),
    .reset(reset),
    .id_allowin(id_allowin),
    .br_bus(br_bus),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_bus(if_to_id_bus),
    .inst_sram_req(inst_sram_req),
    .inst_sram_wr(inst_sram_wr),
    .inst_sram_size(inst_sram_size),
    .inst_sram_wstrb(inst_sram_wstrb),
    .inst_sram_addr(inst_sram_addr),
    .inst_sram_wdata(inst_sram_wdata),
    .inst_sram_addr_ok(inst_sram_addr_ok),
    .inst_sram_data_ok(inst_sram_data_ok),
    .inst_sram_rdata(inst_sram_rdata),
    .if_to_mmu_vaddr(if_to_mmu_vaddr),
    .padd(paddr_to_if),
    .if_tlb_exc(if_tlb_exc),
    .exc_no_rf(exc_not_rf),
    .wb_ertn_flush(wb_ertn_flush),
    .exc_entry(exc_entry),
    .exc_back_pc(exc_back_pc),
    .rf_valid(rf_valid),
    .rf_pc(wb_pc_back)
    );
    
    // ============================================================
    // 第二阶段：译码阶段 (ID - Instruction Decode)
    // ============================================================
    id_stage id_stage(
    .clk(clk),
    .reset(reset),
    .ex_allowin(ex_allowin),
    .id_allowin(id_allowin),
    .if_to_id_valid(if_to_id_valid),
    .if_to_id_bus(if_to_id_bus),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_bus(id_to_ex_bus),
    .br_bus(br_bus),
    .wb_to_rf_bus(wb_to_rf_bus),
    .ex_to_id_dest(ex_to_id_dest),
    .mem_to_id_dest(mem_to_id_dest),
    .wb_to_id_dest(wb_to_id_dest),
    .ex_to_id_load_op(ex_to_id_load_op),
    .ex_to_id_result(ex_to_id_result),
    .mem_to_id_result(mem_to_id_result),
    .wb_to_id_result(wb_to_id_result),
    .mem_to_id_data_ok(mem_to_id_data_ok),
    .mem_exc_valid(mem_exc_valid),
    .ex_csr_we(ex_csr_we),
    .ex_csr_num(ex_csr_num),
    .ex_ertn_flush(ex_ertn_flush),
    .mem_csr_we(mem_csr_we),
    .mem_csr_num(mem_csr_num),
    .mem_ertn_flush(mem_ertn_flush),
    .ex_exc_valid(ex_exc_valid),
    .wb_csr_we(wb_csr_we),
    .wb_csr_num(wb_csr_num),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .csr_rvalue(csr_rvalue),
    .csr_id_num(csr_id_num),
    .has_int(has_int),
    .csr_da_pg(da_pg_out)
    );
    
    // ============================================================
    // 第三阶段：执行阶段 (EX - Execute)
    // ============================================================
    exe_stage exe_stage(
    .clk(clk),
    .reset(reset),
    .mem_allowin(mem_allowin),
    .ex_allowin(ex_allowin),
    .id_to_ex_valid(id_to_ex_valid),
    .id_to_ex_bus(id_to_ex_bus),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_bus(ex_to_mem_bus),
    .ex_to_mmu_vaddr(ex_to_mmu_vaddr),
    .data_sram_req(data_sram_req),
    .data_sram_wr(data_sram_wr),
    .data_sram_size(data_sram_size),
    .data_sram_wstrb(data_sram_wstrb),
    .vtlb_enop(vtlb_enop),
    .ld_and_str(ld_and_str),
    .padd(paddr_to_ex),
    .srch_value(srch_value),
    .mem_tlb_exc(ex_tlb_exc),
    .data_sram_en(data_sram_en),
    .data_sram_we(data_sram_we),
    .data_sram_addr(data_sram_addr),
    .data_sram_wdata(data_sram_wdata),
    .data_sram_addr_ok(data_sram_addr_ok),
    .ex_to_id_dest(ex_to_id_dest),
    .ex_to_id_result(ex_to_id_result),
    .ex_to_id_load_op(ex_to_id_load_op),
    .ex_exc_valid(ex_exc_valid),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .mem_exc_valid(mem_exc_valid),
    .mem_ertn_flush(mem_ertn_flush),
    .ex_csr_we(ex_csr_we),
    .ex_csr_num(ex_csr_num),
    .ex_ertn_flush(ex_ertn_flush),
    .timer_value(timer_value)
    );
    
    // ============================================================
    // 第四阶段：访存阶段 (MEM - Memory Access)
    // ============================================================
     mem_stage mem_stage(
    .clk(clk),
    .reset(reset),
    .wb_allowin(wb_allowin),
    .mem_allowin(mem_allowin),
    .ex_to_mem_valid(ex_to_mem_valid),
    .ex_to_mem_bus(ex_to_mem_bus),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_bus(mem_to_wb_bus),
    .data_sram_rdata(data_sram_rdata),
    .data_sram_data_ok(data_sram_data_ok),
    .mem_to_id_dest(mem_to_id_dest),
    .mem_to_id_result(mem_to_id_result),
    .mem_to_id_data_ok(mem_to_id_data_ok),
    .wb_exc_valid(wb_exc_valid),
    .wb_ertn_flush(wb_ertn_flush),
    .mem_exc_valid(mem_exc_valid),
    .mem_ertn_flush(mem_ertn_flush),
    .mem_csr_we(mem_csr_we),
    .mem_csr_num(mem_csr_num)
    );   
    // ============================================================
    // 第五阶段：写回阶段 (WB - Write Back)
    // ============================================================
    wb_stage wb_stage(
    .clk(clk),
    .reset(reset),
    .wb_allowin(wb_allowin),
    .mem_to_wb_valid(mem_to_wb_valid),
    .mem_to_wb_bus(mem_to_wb_bus),
    .wb_to_rf_bus(wb_to_rf_bus),
    .debug_wb_pc(debug_wb_pc),
    .debug_wb_rf_we(debug_wb_rf_we),
    .debug_wb_rf_wnum(debug_wb_rf_wnum),
    .debug_wb_rf_wdata(debug_wb_rf_wdata),
    .wb_to_id_dest(wb_to_id_dest),
    .wb_to_id_result(wb_to_id_result),
    .wb_ertn_flush(wb_ertn_flush),
    .wb_exc_valid(wb_exc_valid),
    .wb_csr_we(wb_csr_we),
    .wb_csr_num(wb_csr_num),
    .wb_to_csr_bus(wb_to_csr_bus),
    .exc_no_rf(exc_not_rf),
    .rf_valid(rf_valid),
    .wb_pc_back(wb_pc_back),
    .tlbrwf_valid(tlbrwf_valid)
    );
    // ============================================================ 
    // csr寄存器堆
    // ============================================================
    csr_regfile csr_regfile(
        .clk(clk),
        .reset(reset),
        .exc_entry(exc_entry),
        .exc_back_pc(exc_back_pc),
        .csr_id_num(csr_id_num),
        .csr_rvalue(csr_rvalue),
        .has_int(has_int),
        .wb_to_csr_bus(wb_to_csr_bus),
        .coreid_in(32'd0),
    // 中断输入暂时全部接0
        .hw_inter_num(8'b0),
        .ipi_inter(1'b0),
        .plv_out(plv_out),
        .ecode_out(ecode_out),
        .da_pg_out(da_pg_out),
        .dmw_out(dmw_out),
        .tlbrd_bus(tlbrd_value),
        .tlbcsr_bus(tlbcsr_bus)
    );
    // ============================================================
    // MMU
    // ============================================================
    mmu u_mmu (
        .clk           (clk),
        .reset         (reset),
    
        // if interact
        .vaddr_from_if (if_to_mmu_vaddr),
        .paddr_to_if   (paddr_to_if),
        .if_tlb_exc    (if_tlb_exc),
        .if_mat        (if_mat),
    
        // ex interact
        .vaddr_from_ex (ex_to_mmu_vaddr),
        .vtlb_enop     (vtlb_enop),
        .ld_and_str    (ld_and_str),
        .paddr_to_ex   (paddr_to_ex),
        .srch_value    (srch_value),
        .ex_tlb_exc    (ex_tlb_exc),
        .ex_mat        (ex_mat),
    
        // wb interact
        .tlbrwf_en     (tlbrwf_valid),
    
        // csr interact
        .plv_in        (plv_out),
        .ecode_in      (ecode_out),
        .dapg_in       (da_pg_out),
        .dmw           (dmw_out),
        .tlbcsr        (tlbcsr_bus),
        .tlbrd_value   (tlbrd_value)
    );

    // ============================================================ 
    // 计数器 
    // ============================================================
    timer_64bit timer_64bit(
        .clk(clk),
        .reset(reset),
        .timer_value(timer_value)
    );

    // ============================================================
    // SRAM-to-AXI 桥模块
    // ============================================================
    sram_to_axi_bridge sram_to_axi_bridge(
        .clk                (clk),
        .reset              (reset),
        // 取指 SRAM 侧
        .inst_sram_req      (inst_sram_req),
        .inst_sram_wr       (inst_sram_wr),
        .inst_sram_size     (inst_sram_size),
        .inst_sram_wstrb    (inst_sram_wstrb),
        .inst_sram_addr     (inst_sram_addr),
        .inst_sram_wdata    (inst_sram_wdata),
        .inst_sram_addr_ok  (inst_sram_addr_ok),
        .inst_sram_data_ok  (inst_sram_data_ok),
        .inst_sram_rdata    (inst_sram_rdata),
        // 访存 SRAM 侧
        .data_sram_req      (data_sram_req),
        .data_sram_wr       (data_sram_wr),
        .data_sram_size     (data_sram_size),
        .data_sram_wstrb    (data_sram_wstrb),
        .data_sram_addr     (data_sram_addr),
        .data_sram_wdata    (data_sram_wdata),
        .data_sram_addr_ok  (data_sram_addr_ok),
        .data_sram_data_ok  (data_sram_data_ok),
        .data_sram_rdata    (data_sram_rdata),
        // AXI 读地址通道
        .arid           (arid),
        .araddr         (araddr),
        .arlen          (arlen),
        .arsize         (arsize),
        .arburst        (arburst),
        .arlock         (arlock),
        .arcache        (arcache),
        .arprot         (arprot),
        .arvalid        (arvalid),
        .arready        (arready),
        // AXI 读数据通道
        .rid            (rid),
        .rdata          (rdata),
        .rresp          (rresp),
        .rlast          (rlast),
        .rvalid         (rvalid),
        .rready         (rready),
        // AXI 写地址通道
        .awid           (awid),
        .awaddr         (awaddr),
        .awlen          (awlen),
        .awsize         (awsize),
        .awburst        (awburst),
        .awlock         (awlock),
        .awcache        (awcache),
        .awprot         (awprot),
        .awvalid        (awvalid),
        .awready        (awready),
        // AXI 写数据通道
        .wid            (wid),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .wlast          (wlast),
        .wvalid         (wvalid),
        .wready         (wready),
        // AXI 写响应通道
        .bid            (bid),
        .bresp          (bresp),
        .bvalid         (bvalid),
        .bready         (bready)
    );
endmodule