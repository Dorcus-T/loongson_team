`include "mycpu.h"

module exe_stage(
    input clk,
    input reset,
    // allowin
    input mem_allowin,                   // MEM阶段允许接收
    output ex_allowin,                   // EX阶段允许接收
    // 来自id阶段
    input id_to_ex_valid,                // ID到EX有效
    input [`ID_TO_EX_BUS_WD -1:0] id_to_ex_bus,  // 来自ID的控制信号和操作数
    // 输出给mem阶段
    output ex_to_mem_valid,              // EX到MEM有效
    output [`EX_TO_MEM_BUS_WD -1:0] ex_to_mem_bus, // EX到MEM总线
    // 输出给数据存储器
    output data_sram_en,                 // 数据SRAM使能
    output [3:0] data_sram_we,           // 数据SRAM写使能（字节掩码）
    output [31:0] data_sram_addr,        // 数据SRAM地址
    output [31:0] data_sram_wdata,       // 数据SRAM写数据
    // 前递控制
    output [ 4:0] ex_to_id_dest,         // EX阶段写回寄存器号
    output [31:0] ex_to_id_result,       // EX阶段计算结果
    output        ex_to_id_load_op,      // EX阶段是否是加载指令
    // 异常冲刷
    input         wb_exc_valid,          // WB阶段存在异常，冲刷流水线
    input         wb_ertn_flush,         // WB阶段有ertn指令则冲刷流水线
    input         mem_exc_valid,         // MEM阶段存在异常，防止访存
    input         mem_ertn_flush,        // 防止ertn位于mem时,ex发出访存请求
    // csr与ertn冒险
    output ex_csr_we,                   // ex阶段确定要写csr
    output [13:0] ex_csr_num,           // ex阶段写csr的号码
    output ex_ertn_flush,               // ex阶段为ertn指令
    // 读取计数器
    input [63:0] timer_value            // 计数器数值
);

    reg ex_valid;                                // EX阶段有效标志
    wire ex_ready_go;                            // EX阶段就绪标志（除法指令需等待）
    reg [`ID_TO_EX_BUS_WD -1:0] id_to_ex_bus_r;  // 锁存的译码级数据
    
    // ========== 异常信号 ==========
    wire ale;
    wire [5:0] ex_exc;
    wire ex_exc_valid;  // EX阶段异常检测


    // ========== 控制信号解析 ==========
    wire [18:0] alu_op;                 // ALU操作码
    wire ex_load_op;                    // 加载指令标志
    wire src1_is_pc;                    // 源操作数1是否来自PC
    wire src2_is_imm;                   // 源操作数2是否立即数
    wire res_from_mem;                  // 结果是否来自存储器
    wire timer_high;                    // 使用计数器高32位
    wire gr_we;                         // 通用寄存器写使能
    wire mem_we;                        // 存储器写使能
    wire [4:0] dest;                    // 目标寄存器号
    wire [31:0] rj_value;               // 源操作数1（来自寄存器）
    wire [31:0] rkd_value;              // 源操作数2（来自寄存器或立即数）
    wire [31:0] imm;                    // 立即数
    wire [31:0] ex_pc;                  // 当前指令PC
    wire ertn_flush;                    // 异常返回冲刷信号
    wire div_ready;                     // 除法器就绪信号
    wire [2:0] mem_size;                // 访存大小：0=字节，1=半字，2=字
    wire mem_sign_ext;                  // 符号扩展标志
    wire is_div_inst;                   // 判断是否为除法指令，控制流水线前进
    // ALU操作数
    wire [31:0] alu_src1;
    wire [31:0] alu_src2;
    wire [31:0] alu_result;
    // 数据存储器控制信号
    wire [1:0] offset;                   // 地址偏移（低2位）
    wire [3:0] final_we;                 // 最终写使能
    // csr交互信号 
    wire res_from_csr;                   // 结果来自csr寄存器堆
    wire [31:0] csr_rvalue;              // csr读数据
    wire csr_we;                         // csr写使能
    wire [31:0] csr_wmask;               // csr写掩码
    wire [31:0] csr_wvalue;              // csr写数据
    // 计数器数值筛选 
    wire res_from_timer;                 // 结果来自计数器
    wire [31:0] timer_finalval;          //筛选后的计数器读取数据

    // ========== 解析来自ID阶段的总线 ==========
    assign {
        timer_high,     // 281     使用计数器高32位
        res_from_timer, // 280     结果来自计数器
        res_from_csr,   // 279:    结果来自csr寄存器堆
        ex_csr_num,     // 278:265 csr号码
        csr_rvalue,     // 264:233 csr读数据
        csr_we,         // 232     csr写使能
        csr_wmask,      // 231:200 csr写掩码
        csr_wvalue,     // 199:168 csr写数据
        ertn_flush,     // 167    异常返回冲刷信号
        ex_exc[4:0],    // 166:162 异常类型
        res_from_mem,   // 161   结果来源（存储器/ALU）
        ex_pc,          // 160:129 指令PC
        rkd_value,      // 128:97 源操作数2（寄存器或立即数）
        rj_value,       // 96:65 源操作数1（寄存器值）   
        imm,            // 64:33 立即数
        dest,           // 32:28 目标寄存器号
        mem_sign_ext,   // 27    符号扩展标志
        mem_size,       // 26:24 访存大小
        mem_we,         // 23    存储器写使能
        gr_we,          // 22    寄存器写使能
        src2_is_imm,    // 21    操作数2来源（立即数/寄存器） 
        src1_is_pc,     // 20    操作数1来源（PC/寄存器）
        ex_load_op,     // 19    加载指令标志
        alu_op          // 18:0  ALU操作码
    } = id_to_ex_bus_r;

    // ========== 输出到MEM阶段的总线 ==========
    assign ex_to_mem_bus = {
        timer_finalval,  // 226:195筛选后的计数器数据
        res_from_timer,  // 194    结果来自计数器
        res_from_csr,    // 193    结果来自csr寄存器堆
        ex_csr_num,      // 192:179 csr号码
        csr_rvalue,      // 178:147 csr读数据
        csr_we,          // 146     csr写使能
        csr_wmask,       // 145:114 csr写掩码
        csr_wvalue,      // 113:82 csr写数据
        ertn_flush,      // 81    异常返回冲刷信号
        ex_exc,          // 80:75 异常类型
        res_from_mem,    // 74    结果来源
        mem_sign_ext,    // 73    符号扩展标志
        mem_size,        // 72:70 访存大小       
        gr_we,           // 69    寄存器写使能
        dest,            // 68:64 目标寄存器号
        alu_result,      // 63:32 ALU计算结果
        ex_pc            // 31:0  PC 
    };
    
    // ========== 流水线控制 ========== 
    assign is_div_inst = |alu_op[18:15];                    // 判断是否是除法/取模指令（ALU操作码15-18位非零）
    assign ex_ready_go =  (is_div_inst ? div_ready || (!ex_valid || ex_exc[4:0] || mem_ertn_flush || mem_exc_valid || wb_ertn_flush || wb_exc_valid) : 1'b1);     
    // 如果是除法指令，要么正确握手并且算完了发出ready信号，要么由于后面有异常和ertn导致除法指令不发出除法请求就直接走
    // ex阶段的异常中除了ale异常都不应该发出除法请求，不能添加ale，因为ale异常依赖alu结果，alu结果依赖除法结果，除法结果又依赖异常判断形成闭环，虽然二者互斥但是不能有闭环                                                                                        
    assign ex_allowin = !ex_valid || ex_ready_go && mem_allowin;
    assign ex_to_mem_valid = ex_valid && ex_ready_go;
    
    // 执行级有效标志更新
    always @(posedge clk ) begin
        if (reset || wb_exc_valid || wb_ertn_flush) begin
            ex_valid <= 1'b0;
        end
        else if (ex_allowin) begin
            ex_valid <= id_to_ex_valid;
        end
    end
    // 执行级数据传递
    always @(posedge clk) begin
        if (id_to_ex_valid && ex_allowin) begin
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end
    // ========== csr写文件写回控制 ==========
    assign ex_csr_we = csr_we && ex_valid && !ex_exc_valid; //用于csr_stall判断
   
   // ========== 计数器筛选数据生成 ==========
   assign timer_finalval = timer_high ? timer_value[63:32] : timer_value[31:0];
                                        
    // ========== ALU操作数选择 ==========
    assign alu_src1 = src1_is_pc ? ex_pc : rj_value;    // 操作数1：PC或寄存器
    assign alu_src2 = src2_is_imm ? imm : rkd_value;    // 操作数2：立即数或寄存器
    
    // ALU实例化
    alu u_alu(
        .alu_op(alu_op),
        .alu_src1(alu_src1),
        .alu_src2(alu_src2),
        .alu_result(alu_result),
        .clk(clk),
        .reset(reset),
        .div_ready(div_ready),
        .ex_valid(ex_valid),
        .ex_exc(ex_exc[4:0]),
        .mem_exc_valid(mem_exc_valid),
        .mem_ertn_flush(mem_ertn_flush),
        .wb_ertn_flush(wb_ertn_flush),
        .wb_exc_valid(wb_exc_valid)
    );
    
    // ========== 数据存储器写控制 ==========
    assign offset = alu_result[1:0];

    // 字节写使能：1左移到对应字节位置
    assign final_we = mem_size[0] ? (4'b0001 << offset) :                    // 字节访问
                      mem_size[1] ? (offset[1] ? 4'b1100 : 4'b0011) :        // 半字访问
                      4'b1111;                                               // 字访问

    // 写数据：将数据复制到所有字节/半字位置
    assign data_sram_wdata = mem_size[0] ? {4{rkd_value[7:0]}} :             // 字节：4份
                             mem_size[1] ? {2{rkd_value[15:0]}} :            // 半字：2份
                             rkd_value;                                      // 字：原值                             
                          
    // 数据存储器接口
    assign data_sram_en = ex_valid && !mem_exc_valid && !ex_exc_valid && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid; 
     // 只有有效指令并且mem和ex和wb阶段无异常、不是ertn才可使用存储器
    assign data_sram_we = mem_we && ex_valid && !mem_exc_valid && !ex_exc_valid && !mem_ertn_flush && !wb_ertn_flush && !wb_exc_valid ? final_we : 4'h0;  
    assign data_sram_addr = alu_result;                   // 地址
   
    // ========== 前递输出 ==========
    assign ex_to_id_dest = dest & {5{ex_valid}} & {5{gr_we}};
    assign ex_to_id_result = res_from_csr ? csr_rvalue :
                             alu_result;                  // 计算结果
    assign ex_to_id_load_op = ex_load_op & ex_valid;      // 加载指令标志

    // ========== 检测异常与ertn ==========
    assign ale = (ex_valid && (ex_load_op || mem_we)) &&         // 有效的访存指令,load_op本用来表示为ld指令用于处理ld-use数据冒险，这里复用该信号
                 ((mem_size[1] && (alu_result[0] != 1'b0)) ||    // 半字访问，地址bit0≠0
                  (mem_size[2] && (alu_result[1:0] != 2'b00)));  // 字访问，地址bit1:0≠00
    assign ex_exc[5] = ale;
    assign ex_exc_valid = |ex_exc && ex_valid;
    assign ex_ertn_flush =ertn_flush && ex_valid;                // ex阶段的ertn要在指令有效的时候才能发挥作用
endmodule