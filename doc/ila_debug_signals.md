# ILA Debug Signals

> ILA IP: `ila_0` | 采样时钟: `cpu_clk` (80MHz) | 总探头: 63 | 总宽度: ~630 bit

## Probe 索引

### 异常 / WB 级

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 0 | `debug_exc_not_rf` | 1 | `mycpu_top.v` → `wb_stage` | 异常提交标志（触发用） |
| 1 | `debug_ecode` | 6 | `mycpu_top.v` → `csr` | 异常类型码 |
| 2 | `debug_exc_back_pc` | 32 | `mycpu_top.v` → `csr` | ERA（异常返回地址≈异常指令PC） |
| 3 | `debug_wb_inst` | 32 | `mycpu_top.v` → `wb_stage` | WB 阶段指令编码 |
| 4 | `debug_wb_pc` | 32 | `mycpu_top.v` → `wb_stage` | WB 阶段 PC |
| 5 | `debug_wb_rf_wen` | 4 | `mycpu_top.v` → `wb_stage` | 寄存器写使能 |
| 6 | `debug_wb_rf_wnum` | 5 | `mycpu_top.v` → `wb_stage` | 写回寄存器号 |
| 7 | `debug_wb_rf_wdata` | 32 | `mycpu_top.v` → `wb_stage` | 写回数据 |

### IF 级

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 8 | `debug_pre_if_pc` | 32 | `if_stage.v` | pre-IF 级 PC（取指入口） |
| 9 | `debug_if_pc` | 32 | `if_stage.v` | IF 级 PC |
| 10 | `debug_if_inst` | 32 | `if_stage.v` | IF 级取到的原始指令 |
| 11 | `debug_s0_cancel` | 1 | `mycpu_top.v` → `mmu` | ICache mmu_cancel（TLB 异常取消取指） |
| 12 | `debug_icache_addr_ok` | 1 | `mycpu_top.v` → `icache` | ICache 地址握手 |
| 13 | `debug_inst_dirty` | 3 | `if_stage.v` | 流水线气泡计数 |

### ICache

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 14 | `debug_icache_state` | 4 | `icache.v` | 主状态机：1=IDLE, 2=LOOKUP, 4=WAITRD, 8=REFILL |
| 15 | `debug_icache_rd_req` | 1 | `icache.v` | AXI 读请求 |
| 16 | `debug_icache_mmu_tag` | 20 | `icache.v` | MMU 物理 tag |
| 17 | `debug_icache_cpu_index` | 8 | `icache.v` | 当前请求的 cache 行索引 |
| 18 | `debug_icache_refill_cached` | 1 | `icache.v` | 重填行是否 cacheable |
| 19 | `debug_icache_refill_index` | 8 | `icache.v` | 正在重填的行索引 |
| 20 | `debug_icache_req_index` | 8 | `icache.v` | 当前 miss 请求的行索引 |

### Bridge（ICache 读通道）

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 21 | `debug_bridge_arvalid` | 1 | `cache_axi_bridge.v` | AXI 读地址有效 |
| 22 | `debug_bridge_arready` | 1 | `mycpu_top.v` → AXI | AXI 读地址握手 |
| 23 | `debug_bridge_icache_return_data` | 32 | `cache_axi_bridge.v` | AXI 返回数据 → ICache |
| 24 | `debug_bridge_ic_rd_buf_valid` | 1 | `cache_axi_bridge.v` | ICache 读 buffer 有效 |
| 25 | `debug_bridge_ic_rd_buf_addr` | 32 | `cache_axi_bridge.v` | ICache 读 buffer 地址 |

### AXI 读数据通道

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 26 | `debug_axi_rdata` | 32 | `mycpu_top.v` → AXI | AXI rdata（返回给 CPU 的数据） |
| 27 | `debug_axi_rvalid` | 1 | `mycpu_top.v` → AXI | AXI rvalid |
| 28 | `debug_axi_rlast` | 1 | `mycpu_top.v` → AXI | AXI rlast |

### DCache

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 29 | `debug_dcache_state` | 7 | `dcache.v` | 主状态机：1=IDLE, 2=LOOKUP, 4=REREAD, 8=WAITWR, 16=WAIT_WR_DONE, 32=WAITRD, 64=REFILL |
| 30 | `debug_dcache_rd_req` | 1 | `dcache.v` | AXI 读请求 |
| 31 | `debug_dcache_mmu_tag` | 20 | `dcache.v` | MMU 物理 tag |
| 32 | `debug_dcache_cpu_index` | 8 | `dcache.v` | 当前请求的 cache 行索引 |
| 33 | `debug_dcache_refill_cached` | 1 | `dcache.v` | 重填行是否 cacheable |
| 34 | `debug_dcache_refill_index` | 8 | `dcache.v` | 正在重填的行索引 |
| 35 | `debug_dcache_req_index` | 8 | `dcache.v` | 当前 miss 请求的行索引 |
| 36 | `debug_pre_mem_pc` | 32 | `pre_mem_stage.v` | PRE_MEM 级 PC |
| 37 | `debug_alu_result` | 32 | `pre_mem_stage.v` | ALU 计算结果（访存地址） |
| 38 | `debug_dcache_mmu_cache` | 1 | `dcache.v` | MMU cacheable 属性 |
| 39 | `debug_dcache_req_op` | 1 | `dcache.v` | 请求操作类型（0=load, 1=store） |
| 40 | `debug_dcache_req_offset` | 4 | `dcache.v` | 请求块内偏移 |
| 41 | `debug_dcache_refill_tag` | 20 | `dcache.v` | 重填物理 tag |
| 42 | `debug_dcache_refill_offset` | 4 | `dcache.v` | 重填块内偏移 |
| 43 | `debug_dcache_wr_req` | 1 | `dcache.v` | 写请求 |
| 44 | `debug_dcache_wr_type` | 3 | `dcache.v` | 写类型（AXI size） |
| 45 | `debug_dcache_wr_addr` | 32 | `dcache.v` | 写地址 |
| 46 | `debug_dcache_wr_wstrb` | 4 | `dcache.v` | 写字节掩码 |
| 47 | `debug_dcache_wr_data` | 128 | `dcache.v` | write-back 数据（128位 = 4 bank） |
| 48 | `debug_dcache_wr_rdy` | 1 | `mycpu_top.v` → bridge | bridge 写就绪 |
| 49 | `debug_dcache_wr_done` | 1 | `mycpu_top.v` → bridge | bridge 写完成 |

### Bridge（DCache 写通道）

| probe | 信号 | 位宽 | 来源 | 说明 |
|-------|------|------|------|------|
| 50 | `debug_bridge_dc_wr_buf_valid` | 1 | `cache_axi_bridge.v` | DCache 写 buffer 有效 |
| 51 | `debug_bridge_aw_done` | 1 | `cache_axi_bridge.v` | AW 通道完成（组合） |
| 52 | `debug_bridge_awready` | 1 | `mycpu_top.v` → AXI | AXI awready |
| 53 | `debug_bridge_wready` | 1 | `mycpu_top.v` → AXI | AXI wready |
| 54 | `debug_bridge_bvalid` | 1 | `mycpu_top.v` → AXI | AXI bvalid |
| 55 | `debug_bridge_awvalid` | 1 | `cache_axi_bridge.v` | AXI awvalid |
| 56 | `debug_bridge_wvalid` | 1 | `cache_axi_bridge.v` | AXI wvalid |
| 57 | `debug_bridge_bready_out` | 1 | `cache_axi_bridge.v` | AXI bready |
| 58 | `debug_bridge_wr_pend_cnt` | 3 | `cache_axi_bridge.v` | 写 pending 计数器 |
| 59 | `debug_bridge_wr_pend_full` | 1 | `cache_axi_bridge.v` | 写 pending 满 |
| 60 | `debug_bridge_dcache_wr_rdy` | 1 | `cache_axi_bridge.v` | DCache 写就绪（bridge 侧） |
| 61 | `debug_bridge_wr_aw_done_r` | 1 | `cache_axi_bridge.v` | AW 通道已握手（寄存） |
| 62 | `debug_bridge_wr_w_done_r` | 1 | `cache_axi_bridge.v` | W 通道已完成（寄存） |

---

## ILA 配置要点

| 项目 | 值 |
|------|-----|
| 采样时钟 | `cpu_clk` (80MHz) |
| Number of Probes | 63 |
| Sample Data Depth | 1024（建议） |
| Trigger Position | 1000（尽量靠后，多看触发前历史） |
| 采样周期 | 12.5 ns |
| 窗口时间 | 12.8 μs (1024 × 12.5ns) |

## 状态机编码

### ICache (`debug_icache_state`) — 4-bit one-hot

| 值 | 状态 |
|----|------|
| 1 | IDLE |
| 2 | LOOKUP |
| 4 | WAITRD |
| 8 | REFILL |

### DCache (`debug_dcache_state`) — 7-bit one-hot

| 值 | 状态 |
|----|------|
| 1 | IDLE |
| 2 | LOOKUP |
| 4 | REREAD |
| 8 | WAITWR |
| 16 | WAIT_WR_DONE |
| 32 | WAITRD |
| 64 | REFILL |

## 涉及修改的源文件

| 文件 | 修改内容 |
|------|----------|
| `IP/myCPU/if_stage.v` | `debug_pre_if_pc`, `debug_if_pc`, `debug_if_inst`, `debug_inst_dirty` 端口；`inst_dirty` 机制重构（`req_valid` 状态机 + `s0_cancel` 输入） |
| `IP/myCPU/icache.v` | `debug_main_state`, `debug_rd_req`, `debug_mmu_tag`, `debug_cpu_index`, `debug_refill_cached`, `debug_refill_index`, `debug_req_index` 端口 |
| `IP/myCPU/dcache.v` | `debug_main_state`(7-bit), `debug_rd_req`, `debug_mmu_tag`, `debug_cpu_index`, `debug_refill_cached`, `debug_refill_index`, `debug_req_index`, `debug_mmu_cache`, `debug_req_op`, `debug_req_offset`, `debug_refill_tag`, `debug_refill_offset`, `debug_dc_wr_req`, `debug_dc_wr_type`, `debug_dc_wr_addr`, `debug_dc_wr_wstrb`, `debug_dc_wr_data` 端口 |
| `IP/myCPU/pre_mem_stage.v` | `debug_pre_mem_pc`, `debug_alu_result` 端口 |
| `IP/myCPU/cache_axi_bridge.v` | `debug_arvalid`, `debug_icache_return_data`, `debug_ic_rd_buf_valid`, `debug_ic_rd_buf_addr`, `debug_dc_wr_buf_valid`, `debug_awvalid`, `debug_aw_done`, `debug_wvalid`, `debug_bready`, `debug_wr_pend_cnt`, `debug_wr_pend_full`, `debug_dcache_wr_rdy`, `debug_wr_aw_done_r`, `debug_wr_w_done_r` 端口 |
| `IP/myCPU/mycpu_top.v` | 全部 debug 输出端口透传 + `assign` 连接 |
| `chip/soc_demo/nscscc-team/soc_top.v` | `ila_0` 例化（63 probe），全部 debug wire 声明和 `core_top` 连接 |

## 常用触发配置

| 场景 | 触发条件 |
|------|----------|
| 捕获异常 | `probe0 (exc_not_rf) == 1` |
| 捕获 DCache 卡死 | `probe29 (dcache_state) == 0x10`（WAIT_WR_DONE） |
| 手动触发 | VIO 引出 + `probe_manual == 1`，卡住时拨 VIO |
