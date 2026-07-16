# ============================================================================
# SDC 时序约束 — OpenSTA 2.x 兼容版
# ============================================================================

create_clock -name aclk -period 10.0 [get_ports aclk]
set_clock_uncertainty -setup 0.3 [get_clocks aclk]
set_clock_uncertainty -hold 0.05 [get_clocks aclk]

# 输入延迟（所有输入，时钟/复位 STA 会自行处理）
set_input_delay -clock aclk -max 1.0 [all_inputs]
set_input_delay -clock aclk -min 0.2 [all_inputs]

# 输出延迟
set_output_delay -clock aclk -max 1.0 [all_outputs]
set_output_delay -clock aclk -min 0.2 [all_outputs]

set_load 0.05 [all_outputs]
