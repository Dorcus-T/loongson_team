`include "mycpu.h"
module csr_regfile (
    input  clk,
    input  reset,
    
    // ========== 与if阶段交互 ==========
    output [31:0] exc_entry,          // 异常入口地址（供PC跳转）
    output [31:0] exc_back_pc,        // 异常返回地址

    // ========== 与id阶段交互 ==========
    input  [13:0] csr_id_num,         // id阶段读csr号码
    output [31:0] csr_rvalue,         // 读出数据，送给id阶段
    output        has_int,            // 有待处理的中断（ID用此信号决定是否打标签）

    // ========== 与wb阶段交互 ==========
    input [`WB_TO_CSR_BUS_WD -1:0] wb_to_csr_bus,

    // ========== 来自顶层文件 ==========
    input  [31:0] coreid_in,

    // ========== 中断输入（异步） ==========
    input  [7:0]  hw_inter_num,         // 硬件中断号（2-9）
    input         ipi_inter             // 核间中断（中断号12）
    
);
    // ========== CSR值输出（供流水线使用）==========
    wire [31:0] csr_crmd_rvalue;
    wire [31:0] csr_prmd_rvalue;
    wire [31:0] csr_ecfg_rvalue;
    wire [31:0] csr_estat_rvalue;
    wire [31:0] csr_era_rvalue;
    wire [31:0] csr_badv_rvalue;
    wire [31:0] csr_eentry_rvalue;
    wire [31:0] csr_save0_rvalue;
    wire [31:0] csr_save1_rvalue;
    wire [31:0] csr_save2_rvalue;
    wire [31:0] csr_save3_rvalue;
    wire [31:0] csr_tid_rvalue;
    wire [31:0] csr_tcfg_rvalue;
    wire [31:0] csr_tval_rvalue;
    wire [31:0] csr_ticlr_rvalue;
    // ========== 内部生成定时器中断 ==========
    wire timer_inter;

    // ========== 定义来自wb的信号 ==========
    wire [13:0] csr_num;            // CSR号码
    wire        csr_we;             // CSR写使能
    wire [31:0] csr_wmask;          // CSR写掩码
    wire [31:0] csr_wvalue;         // CSR写数据
    wire        wb_ertn_flush;      // 异常返回冲刷信号
    wire        wb_exc_valid;       // 异常有效标志
    wire [5:0]  wb_exc_ecode;       // 异常码
    wire [8:0]  wb_exc_esubcode;    // 异常子码  
    wire [31:0] wb_exc_badv;        // 异常地址（BADV）
    wire [31:0] wb_exc_pc;          // 异常PC（ERA）
    
    // ========== 解析来自wb的总线==========
    assign {
        csr_num,            // [159:146] 14位 CSR号码
        csr_we,             // [145]     1位 CSR写使能
        csr_wmask,          // [144:113] 32位 CSR写掩码
        csr_wvalue,         // [112:81]  32位 CSR写数据
        wb_ertn_flush,      // [80]      1位 异常返回冲刷信号
        wb_exc_valid,       // [79]      1位 异常有效标志
        wb_exc_ecode,       // [78:73]   6位 异常码
        wb_exc_esubcode,    // [72:64]   9位 异常子码
        wb_exc_badv,        // [63:32]   32位 异常地址（BADV）
        wb_exc_pc           // [31:0]    32位 异常PC（ERA）
    } = wb_to_csr_bus;
    // ========== CRMD寄存器域定义 ==========
    // 位[1:0]   csr_crmd_plv - 特权级 (0=内核态, 3=用户态)
    // 位[2]     csr_crmd_ie  - 中断使能 (1=开启)
    // 位[3]     csr_crmd_da  - 地址对齐检查 (1=开启)
    // 位[4]     csr_crmd_pg  - 页表使能 (1=开启MMU)
    // 位[6:5]   csr_crmd_datf - 数据访存失效 (1=开启)
    // 位[8:7]   csr_crmd_datm - 数据访存修改 (1=开启)
    // 位[31:9]  保留 - 读返回0
    reg  [1:0]  csr_crmd_plv;     // [1:0] 特权级
    reg         csr_crmd_ie;      // [2] 中断使能
    wire         csr_crmd_da;     // [3] 地址对齐检查
    wire         csr_crmd_pg;     // [4] 页表使能
    wire  [1:0]  csr_crmd_datf;   // [6:5] 数据访存失效
    wire  [1:0]  csr_crmd_datm;   // [8:7] 数据访存修改
    
    // ========== PRMD寄存器域定义 ==========
    // 位[1:0]   csr_prmd_pplv - 前任特权级
    // 位[2]     csr_prmd_pie  - 前任中断使能
    // 位[31:3]  保留
    reg  [1:0]  csr_prmd_pplv;    // [1:0] 前任特权级
    reg         csr_prmd_pie;     // [2] 前任中断使能
    
    // ========== ECFG寄存器域定义 ==========
    // 位[12:0]   csr_ecfg_lie - 局部中断使能,位10保留
    // 位[31:13] 保留
    reg  [12:0]  csr_ecfg_lie;    // [12:0] 局部中断使能  

    // ========== ESTAT寄存器域定义 ==========
    // 位[1:0]   csr_estat_is  s_9_2   - 硬件中断状态位 (8位)
    // 位[10]    保留
    // 位[11]    csr_estat_is_11    - 定时器中断状态位 (1位)
    // 位[12]    csr_estat_is_12    - 核间中断状态位 (1位)
    // 位[15:13] 保留
    // 位[21:16] csr_estat_ecode    - 异常码 (6位)
    // 位[30:22] csr_estat_esubcode - 异常子码 (9位)
    // 位[31]    保留
    reg  [12:0] csr_estat_is;       // [12:0] 中断状态位
    reg  [5:0]  csr_estat_ecode;    // [21:16] 异常码
    reg  [8:0]  csr_estat_esubcode; // [30:22] 异常子码
    
    // ========== ERA寄存器 ==========
    // 位[31:0] csr_era_pc - 异常返回地址
    reg  [31:0] csr_era_pc;      // 异常返回地址
    
    // ========== BADV寄存器 ==========
    // 位[31:0] csr_badv_vaddr - 错误虚拟地址
    reg  [31:0] csr_badv_vaddr;    // 错误地址
    wire        wb_exc_addr_err;   // WB阶段发生地址有关错误

    // ========== EENTRY寄存器域定义 ==========
    // 位[5:0]   保留
    // 位[31:6]  csr_eentry_va - 异常入口地址
    reg  [25:0] csr_eentry_va;       // 异常入口地址完整值
    
    // ========== SAVE0-3寄存器 ==========
    // 位[31:0] 通用保存寄存器
    reg  [31:0] csr_save0_data;    // 保存寄存器0
    reg  [31:0] csr_save1_data;    // 保存寄存器1
    reg  [31:0] csr_save2_data;    // 保存寄存器2
    reg  [31:0] csr_save3_data;    // 保存寄存器3
    
    // ========== TID寄存器 ==========
    // 位[31:0] csr_tid - 定时器ID
    reg  [31:0] csr_tid_tid;       // 定时器ID
    
    // ========== TCFG寄存器域定义 ==========
    // 位[0]     csr_tcfg_en       - 定时器使能 (1=开启)
    // 位[1]     csr_tcfg_periodic - 周期模式 (1=周期, 0=单次)
    // 位[31:2]  csr_tcfg_initval  - 计数初始值
    reg         csr_tcfg_en;       // [0] 定时器使能
    reg         csr_tcfg_periodic; // [1] 周期模式
    reg  [29:0] csr_tcfg_initval;  // [31:2] 定时器初始值
    
    // ========== TVAL寄存器域定义 ==========
    reg  [31:0] csr_tval_timeval;  // 定时器当前值
    wire [31:0] tcfg_next_value;   // 定时器下次加载值        
    
    // ========== TICLR寄存器域定义 ========== 
    wire         csr_ticlr_clr;    //定时中断清除信号


    // ========== 组合逻辑：CRMD寄存器组装 ==========
    assign csr_crmd_rvalue = {23'b0, csr_crmd_datm, csr_crmd_datf, csr_crmd_pg, 
                         csr_crmd_da, csr_crmd_ie, csr_crmd_plv};
    
    // ========== 组合逻辑：PRMD寄存器组装 ==========
    assign csr_prmd_rvalue = {29'b0, csr_prmd_pie, csr_prmd_pplv};
    
    // ========== 组合逻辑：ECFG寄存器组装 ==========
    assign csr_ecfg_rvalue = {19'b0, csr_ecfg_lie};
    
    // ========== 组合逻辑：ESTAT寄存器组装 ==========
    assign csr_estat_rvalue = {1'b0, csr_estat_esubcode, csr_estat_ecode, 
                          3'b0, csr_estat_is};
    // ========== 组合逻辑：ERA寄存器组装 ==========
    assign csr_era_rvalue = csr_era_pc;

    // ========== 组合逻辑：BADV寄存器组装 ==========
    assign csr_badv_rvalue = csr_badv_vaddr;

    // ========== 组合逻辑：EENTRY寄存器组装 ==========;
    assign csr_eentry_rvalue = {csr_eentry_va, 6'b0};  // 64KB对齐
    
    // ========== 组合逻辑：SAVE0-3寄存器组装 ==========
    assign csr_save0_rvalue = csr_save0_data;
    assign csr_save1_rvalue = csr_save1_data;
    assign csr_save2_rvalue = csr_save2_data;
    assign csr_save3_rvalue = csr_save3_data;

    // ========== 组合逻辑：TID寄存器组装 ==========
    assign csr_tid_rvalue = csr_tid_tid;

    // ========== 组合逻辑：TCFG寄存器组装 ==========
    assign csr_tcfg_rvalue = {csr_tcfg_initval, csr_tcfg_periodic, csr_tcfg_en};
    
    // ========== 组合逻辑：TVAL寄存器组装 ==========
    assign csr_tval_rvalue = csr_tval_timeval;

    // ========== 组合逻辑：TICLR寄存器组装 ==========
    assign csr_ticlr_rvalue = {30'b0, csr_ticlr_clr};  
    
    // ========== CSR读操作 ==========
    assign csr_rvalue = ({32{csr_id_num == `CSR_CRMD}}   & csr_crmd_rvalue)   |
                        ({32{csr_id_num == `CSR_PRMD}}   & csr_prmd_rvalue)   |
                        ({32{csr_id_num == `CSR_ECFG}}   & csr_ecfg_rvalue)   |
                        ({32{csr_id_num == `CSR_ESTAT}}  & csr_estat_rvalue)  |
                        ({32{csr_id_num == `CSR_ERA}}    & csr_era_rvalue)    |
                        ({32{csr_id_num == `CSR_BADV}}   & csr_badv_rvalue)   |
                        ({32{csr_id_num == `CSR_EENTRY}} & csr_eentry_rvalue) |
                        ({32{csr_id_num == `CSR_SAVE0}}  & csr_save0_rvalue)  |
                        ({32{csr_id_num == `CSR_SAVE1}}  & csr_save1_rvalue)  |
                        ({32{csr_id_num == `CSR_SAVE2}}  & csr_save2_rvalue)  |
                        ({32{csr_id_num == `CSR_SAVE3}}  & csr_save3_rvalue)  |
                        ({32{csr_id_num == `CSR_TID}}    & csr_tid_rvalue)    |
                        ({32{csr_id_num == `CSR_TCFG}}   & csr_tcfg_rvalue)   |
                        ({32{csr_id_num == `CSR_TVAL}}   & csr_tval_rvalue)   |
                        ({32{csr_id_num == `CSR_TICLR}}  & csr_ticlr_rvalue);


    // ========== CSR写操作（按域实现，每个域一个always块）========== 
    // ========== CRMD写操作 ==========
    //写PLV、IE
    always @(posedge clk) begin
        if (reset) begin
            csr_crmd_plv <= 2'b0;
            csr_crmd_ie <= 1'b0;
        end    
        else if (wb_exc_valid) begin
            csr_crmd_plv <= 2'b0;
            csr_crmd_ie  <= 1'b0;
        end
        else if (wb_ertn_flush) begin
            csr_crmd_plv <= csr_prmd_pplv;
            csr_crmd_ie  <= csr_prmd_pie;
        end    
        else if (csr_we && csr_num==`CSR_CRMD) begin
            csr_crmd_plv <= csr_wmask[`CSR_CRMD_PLV]&csr_wvalue[`CSR_CRMD_PLV]
                         | ~csr_wmask[`CSR_CRMD_PLV]&csr_crmd_plv;
            csr_crmd_ie <= csr_wmask[`CSR_CRMD_IE]&csr_wvalue[`CSR_CRMD_IE]
                        | ~csr_wmask[`CSR_CRMD_IE]&csr_crmd_ie;
        end
    end
    //写DA、PG、DATF、DATM
    assign csr_crmd_da   = 1'b1;
    assign csr_crmd_pg   = 1'b0;
    assign csr_crmd_datf = 2'b00;
    assign csr_crmd_datm = 2'b00;
    
    // ========== PRMD写操作 ==========
    //写PPLV、PIE
    always @(posedge clk) begin
        if (reset) begin
            csr_prmd_pplv <= 2'b0;
            csr_prmd_pie <= 1'b0;
        end 
        else if (wb_exc_valid) begin
            csr_prmd_pplv <= csr_crmd_plv;
            csr_prmd_pie  <= csr_crmd_ie;
        end
        else if (csr_we && csr_num==`CSR_PRMD) begin
            csr_prmd_pplv <= csr_wmask[`CSR_PRMD_PPLV]&csr_wvalue[`CSR_PRMD_PPLV]
                         | ~csr_wmask[`CSR_PRMD_PPLV]&csr_prmd_pplv;
            csr_prmd_pie <= csr_wmask[`CSR_PRMD_PIE]&csr_wvalue[`CSR_PRMD_PIE]
                         | ~csr_wmask[`CSR_PRMD_PIE]&csr_prmd_pie;
        end
    end
    // ========== ECFG写操作 ==========
    //写LIE
    always @(posedge clk) begin
        if (reset) begin
            csr_ecfg_lie <= 13'b0;
        end
        else if (csr_we && csr_num == `CSR_ECFG) begin
            csr_ecfg_lie[10] <= 1'b0;
            csr_ecfg_lie[9:0] <= (csr_wmask[9:0] & csr_wvalue[9:0]) 
                               | (~csr_wmask[9:0] & csr_ecfg_lie[9:0]);
            csr_ecfg_lie[12:11] <= (csr_wmask[12:11] & csr_wvalue[12:11]) 
                                 | (~csr_wmask[12:11] & csr_ecfg_lie[12:11]);
        end
    end
    // ========== ESTAT写操作 ==========
    //写IS
    always @(posedge clk) begin
        if (reset) begin
            csr_estat_is[1:0] <= 2'b0;
        end
        else if (csr_we && csr_num==`CSR_ESTAT) begin
            csr_estat_is[1:0] <= csr_wmask[`CSR_ESTAT_IS10]&csr_wvalue[`CSR_ESTAT_IS10]
                               | ~csr_wmask[`CSR_ESTAT_IS10]&csr_estat_is[1:0];    
        end
        csr_estat_is[9:2] <= hw_inter_num[7:0];
        csr_estat_is[10] <= 1'b0;
        if (timer_inter)
            csr_estat_is[11] <= 1'b1;
        else if (csr_we && csr_num==`CSR_TICLR && csr_wmask[`CSR_TICLR_CLR]
                 && csr_wvalue[`CSR_TICLR_CLR])
            csr_estat_is[11] <= 1'b0;

        csr_estat_is[12] <= ipi_inter; 
    end
    assign timer_inter = (csr_tval_timeval == 32'b0);

   //写Ecode、EsubCode
   always @(posedge clk) begin
        if (reset) begin
            csr_estat_ecode     <= 6'b0;
            csr_estat_esubcode <= 9'b0;
        end
        else if (wb_exc_valid) begin
            csr_estat_ecode     <= wb_exc_ecode;
            csr_estat_esubcode <= wb_exc_esubcode;
        end
        
    end
    // ========== ERA写操作 ==========
    //写PC
    always @(posedge clk) begin
        if (reset) begin
            csr_era_pc <= 32'b0;
        end 
        else if (wb_exc_valid) begin
            csr_era_pc <= wb_exc_pc;
        end
        else if (csr_we && csr_num==`CSR_ERA)
            csr_era_pc <= csr_wmask[`CSR_ERA_PC]&csr_wvalue[`CSR_ERA_PC]
                        |~csr_wmask[`CSR_ERA_PC]&csr_era_pc;
    end
    // ========== BADV写操作 ==========
    //写VADDR
    assign wb_exc_addr_err = wb_exc_ecode==`ECODE_ADE || wb_exc_ecode==`ECODE_ALE;

    always @(posedge clk) begin
        if (reset) begin
            csr_badv_vaddr <= 32'b0;
        end 
        else if (wb_exc_valid && wb_exc_addr_err) begin
            csr_badv_vaddr <= (wb_exc_ecode==`ECODE_ADE &&
                               wb_exc_esubcode==`ESUBCODE_ADEF) ? wb_exc_pc : wb_exc_badv;
        end
    end

    // ========== EENTRY写操作 ==========
    //写VA
    always @(posedge clk) begin
        if (reset) begin
            csr_eentry_va <= 26'b0;
        end 
        else if (csr_we && csr_num==`CSR_EENTRY) begin
            csr_eentry_va <= csr_wmask[`CSR_EENTRY_VA]&csr_wvalue[`CSR_EENTRY_VA]
                           |~csr_wmask[`CSR_EENTRY_VA]&csr_eentry_va;
        end
    end
    
    // ========== SAVE0~3写操作 ==========
    always @(posedge clk) begin
        if (reset) begin
            csr_save0_data <= 32'b0;
            csr_save1_data <= 32'b0;
            csr_save2_data <= 32'b0;
            csr_save3_data <= 32'b0;
        end 
        else if (csr_we && csr_num==`CSR_SAVE0) 
            csr_save0_data <= csr_wmask[`CSR_SAVE_DATA]&csr_wvalue[`CSR_SAVE_DATA]
                            |~csr_wmask[`CSR_SAVE_DATA]&csr_save0_data;
        else if (csr_we && csr_num==`CSR_SAVE1) 
            csr_save1_data <= csr_wmask[`CSR_SAVE_DATA]&csr_wvalue[`CSR_SAVE_DATA]
                            |~csr_wmask[`CSR_SAVE_DATA]&csr_save1_data;
        else if (csr_we && csr_num==`CSR_SAVE2) 
            csr_save2_data <= csr_wmask[`CSR_SAVE_DATA]&csr_wvalue[`CSR_SAVE_DATA]
                            |~csr_wmask[`CSR_SAVE_DATA]&csr_save2_data;
        else if (csr_we && csr_num==`CSR_SAVE3) 
            csr_save3_data <= csr_wmask[`CSR_SAVE_DATA]&csr_wvalue[`CSR_SAVE_DATA]
                            |~csr_wmask[`CSR_SAVE_DATA]&csr_save3_data;
    end
    
    // ========== TID写操作 ==========
    //写TID
    always @(posedge clk) begin
        if (reset) begin
            csr_tid_tid <= coreid_in;
        end else if (csr_we && csr_num ==`CSR_TID) begin
            csr_tid_tid <= csr_wmask[`CSR_TID_TID]&csr_wvalue[`CSR_TID_TID]
                         |~csr_wmask[`CSR_TID_TID]&csr_tid_tid;
        end
    end
    
    // ========== TCFG写操作 ==========
    //写EN、Periodic、InitVal
    always @(posedge clk) begin
        if (reset) begin
            csr_tcfg_en <= 1'b0;
            csr_tcfg_periodic <= 1'b0;
            csr_tcfg_initval <= 30'b0;
        end
        else if (csr_we && csr_num ==`CSR_TCFG) begin 
            csr_tcfg_en <= csr_wmask[`CSR_TCFG_EN]&csr_wvalue[`CSR_TCFG_EN]
                         |~csr_wmask[`CSR_TCFG_EN]&csr_tcfg_en;
            csr_tcfg_periodic <= csr_wmask[`CSR_TCFG_PERIODIC]&csr_wvalue[`CSR_TCFG_PERIODIC]
                               |~csr_wmask[`CSR_TCFG_PERIODIC]&csr_tcfg_periodic;
            csr_tcfg_initval <= csr_wmask[`CSR_TCFG_INITVAL]&csr_wvalue[`CSR_TCFG_INITVAL]
                              |~csr_wmask[`CSR_TCFG_INITVAL]&csr_tcfg_initval;
        end
    end

    // ========== TVAL写操作 ==========
    assign tcfg_next_value = csr_wmask[31:0]&csr_wvalue[31:0]
                           |~csr_wmask[31:0]&{csr_tcfg_initval,csr_tcfg_periodic,csr_tcfg_en};
                    
    always @(posedge clk) begin
        if (reset) begin
            csr_tval_timeval <= 32'hffffffff;
        end else if (csr_we && csr_num == `CSR_TCFG && tcfg_next_value[`CSR_TCFG_EN])
            csr_tval_timeval <= {tcfg_next_value[`CSR_TCFG_INITVAL], 2'b0};
            else if (csr_tcfg_en && csr_tval_timeval!=32'hffffffff) begin
                if (csr_tval_timeval[31:0]==32'b0 && csr_tcfg_periodic)
                    csr_tval_timeval <= {csr_tcfg_initval, 2'b0};
                else
                    csr_tval_timeval <= csr_tval_timeval - 1'b1;
            end
    end                    
   
    // ========== TICLR写操作 ==========
    //写CLR
    assign csr_ticlr_clr = 1'b0;
    
    // ========== 中断状态输出给ID阶段 ==========
    // 计算使能的中断（受csr_crmd_ie和csr_ecfg_lie控制，且不在异常处理中）
    assign has_int = ((csr_estat_is[12:0] & csr_ecfg_lie[12:0]) != 13'b0) && (csr_crmd_ie == 1'b1);

    // ========== 输出地址计算 ==========
    // 异常入口地址（直接模式）
    assign exc_entry = {csr_eentry_va, 6'b0};
    assign exc_back_pc = csr_era_pc;
    
endmodule