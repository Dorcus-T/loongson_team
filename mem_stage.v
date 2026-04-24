`include "mycpu.h"

module mem_stage(
    input  clk,
    input  reset,
    // allowin
    input  wb_allowin,                  // WB阶段允许接收
    output mem_allowin,                 // MEM阶段允许接收
    // 来自ex阶段
    input  ex_to_mem_valid,             // EX到MEM有效
    input [`EX_TO_MEM_BUS_WD -1:0] ex_to_mem_bus,  // 来自EX的总线
    // 输出给wb阶段
    output mem_to_wb_valid,              // MEM到WB有效
    output [`MEM_TO_WB_BUS_WD -1:0] mem_to_wb_bus, // MEM到WB总线
    // 来自数据存储器
    input [31:0] cpu_data_rdata,         // 数据SRAM读数据 
    input        cpu_data_data_ok,       // 数据SRAM数据ok
    // 前递控制
    output [ 4:0] mem_to_id_dest,        // MEM阶段写回寄存器号
    output [31:0] mem_to_id_result,      // MEM阶段计算结果
    // 异常冲刷
    input  wb_exc_valid,                 // WB阶段异常冲刷流水线
    input  wb_ertn_flush,                // WB阶段有ertn指令则冲刷流水线
    output mem_exc_valid,                // 防止有异常时ex阶段发出访存请求
    output mem_ertn_flush,               // 防止ertn位于mem时,ex发出访存请求
    // csr与ertn冒险
    output mem_csr_we,                   // mem阶段确定要写csr
    output [13:0] mem_csr_num            // mem阶段写csr的号码
);

    reg  mem_valid;                                // MEM阶段有效标志
    wire mem_ready_go;                             // MEM阶段就绪（总是1）
    reg [`EX_TO_MEM_BUS_WD -1:0] ex_to_mem_bus_r;  // 锁存的执行级数据
    
    // ========== 异常信号 ==========
    wire [5:0] mem_exc;

    // ========== 控制信号解析 ==========
    wire res_from_mem;                    // 结果是否来自存储器
    wire gr_we;                           // 寄存器写使能
    wire [4:0] dest;                      // 目标寄存器号
    wire [31:0] alu_result;               // ALU计算结果（地址）
    wire [31:0] mem_pc;                   // 指令PC
    wire [31:0] final_result;             // 最终结果（来自ALU或存储器）
    wire ertn_flush;                      // 异常返回冲刷信号
    wire [2:0] mem_size;                  // 访存大小
    wire mem_sign_ext;                    // 符号扩展标志
    // 访存数据控制信号
    wire [1:0] offset;                   // 偏移量，地址低两位         
    wire [31:0] shift_data;              // 偏移后的数据
    wire [31:0] data_result;             // 最终读的数据
    // csr交互信号 
    wire res_from_csr;                   // 结果来自csr寄存器堆
    wire [31:0] csr_rvalue;              // csr读数据
    wire csr_we;                         // csr写使能
    wire [31:0] csr_wmask;               // csr写掩码
    wire [31:0] csr_wvalue;              // csr写数据
    // 计数器数值筛选 
    wire res_from_timer;                 // 结果来自计数器
    wire [31:0] timer_finalval;          // 筛选后的计数器读取数据
    //实现类sram总线
    wire is_mem_inst;                    // 是访存指令

    // ========== 类sram实现所需信号 ==========
    reg         new_in;                  // 表明mem中的指令是新进入的
    reg  [31:0] mem_data_r;              // 寄存mem阶段的数据
    reg         mem_data_r_valid;        // 寄存数据是否有效
    reg  [31:0] ex_data_r;               // 新读出的数据，若无新数据进入mem就把它存起来
    reg         ex_data_r_valid;         // 存的新数据有效

    // ========== 解析来自EX阶段的总线 ==========
    assign {
        is_mem_inst,         // 227 是访存指令
        timer_finalval,      // 226:195筛选后的计数器数据
        res_from_timer,      // 194    结果来自计数器
        res_from_csr,        // 193    结果来自csr寄存器堆
        mem_csr_num,         // 192:179 csr号码
        csr_rvalue,          // 178:147 csr读数据
        csr_we,              // 146     csr写使能
        csr_wmask,           // 145:114 csr写掩码
        csr_wvalue,          // 113:82 csr写数据
        ertn_flush,          // 81    异常返回冲刷信号
        mem_exc,             // 80:75 异常类型
        res_from_mem,        // 74    结果来源
        mem_sign_ext,        // 73    符号扩展标志
        mem_size,            // 72:70 访存大小
        gr_we,               // 69    寄存器写使能
        dest,                // 68:64 目标寄存器号
        alu_result,          // 63:32 ALU结果
        mem_pc               // 31:0  PC
    } = ex_to_mem_bus_r;
    
    // ========== 输出到WB阶段的总线 ==========
    assign mem_to_wb_bus = {
        mem_csr_num,         // 187:174 csr号码
        csr_we,              // 173     csr写使能
        csr_wmask,           // 172:141 csr写掩码
        csr_wvalue,          // 140:109 csr写数据
        ertn_flush,          // 108   异常返回冲刷信号
        mem_exc,             // 107:102 异常类型 
        alu_result,          // 101:70 传递异常访存地址
        gr_we,               // 69    寄存器写使能
        dest,                // 68:64 目标寄存器号
        final_result,        // 63:32 最终结果
        mem_pc               // 31:0  PC  
    };
    
    // ========== 流水线控制 ==========
    assign mem_ready_go = is_mem_inst ? cpu_data_data_ok : 1'b1;         
    assign mem_allowin = !mem_valid || mem_ready_go && wb_allowin;
    assign mem_to_wb_valid = mem_valid && mem_ready_go;
    
    // 访存级有效标志更新
    always @(posedge clk ) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            mem_valid <= 1'b0;
        end
        else if (mem_allowin) begin
            mem_valid <= ex_to_mem_valid;
        end
    end
    // 访存级数据传递
    always @(posedge clk) begin
        if (ex_to_mem_valid && mem_allowin) begin
            ex_to_mem_bus_r <= ex_to_mem_bus;
        end
    end

    // ========== 流水线控制 ==========
    always @(posedge clk ) begin
        if (reset) begin
            new_in <= 1'b0;
        end
        else if (mem_allowin && ex_to_mem_valid) begin
            new_in <= 1'b1;
        end
    end
    //表明mem是否有新指令的逻辑实现
    
    always @(posedge clk ) begin
        if (reset || (wb_allowin && mem_to_wb_valid)) begin
            mem_data_r_valid <= 1'b0;
            mem_data_r <= 32'b0;
        end
        else if ((mem_data_r_valid || (cpu_data_data_ok || ex_data_r_valid)) && !wb_allowin) begin
            mem_data_r_valid <= 1'b1;
            mem_data_r <= data_result;
        end
    end
    //如果if有数据但是id不让进，下一次上跳if_inst又会响应preif发出的指令读出新的数据，所以就需要把这次的数据存起来
    //当指令进入id的时候就把指令和有效信号清空,如果有跳转就要清空让preif成功覆盖

    always @(posedge clk ) begin
        if (reset || new_in) begin
            ex_data_r_valid <= 1'b0;
            ex_data_r <= 32'b0;
        end
        else if (cpu_data_data_ok && !new_in) begin
            ex_data_r_valid <= 1'b1;
            ex_data_r <= cpu_data_rdata;
        end
    end    
    // ========== csr写文件写回控制 ==========
    assign mem_csr_we = csr_we && mem_valid && !mem_exc_valid;

    // ========== 存储器读数据处理（字节/半字/字，支持符号扩展）==========
    assign offset = alu_result[1:0]; 

    // 移位对齐（将目标数据移到最低位）
    assign shift_data = (ex_data_r_valid ? ex_data_r : cpu_data_rdata) >> (offset * 8);

    // 根据访存大小提取并扩展
    assign data_result = mem_size[2] ? (ex_data_r_valid ? ex_data_r : cpu_data_rdata) :          // 字
                         mem_size[1] ? {{16{mem_sign_ext & shift_data[15]}}, shift_data[15:0]} : // 半字
                         mem_size[0] ? {{24{mem_sign_ext & shift_data[7]}}, shift_data[7:0]} :   // 字节
                         32'b0;
    
    // 最终结果：来自存储器或ALU或者CSR
    assign final_result = res_from_mem ? (mem_data_r_valid ? mem_data_r : data_result) :
                          res_from_csr ? csr_rvalue  :
                          res_from_timer ? timer_finalval :
                          alu_result;
    
    // ========== 前递输出 ==========
    assign mem_to_id_dest = dest & {5{mem_valid}} & {5{gr_we}} & {5{mem_ready_go}};
    assign mem_to_id_result = final_result;

    // ========== 检测异常与ertn ==========
    assign mem_exc_valid = |mem_exc && mem_valid;
    assign mem_ertn_flush = ertn_flush && mem_valid; //mem的ertn要发挥作用必须得有效

    
endmodule