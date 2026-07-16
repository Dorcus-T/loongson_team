# ============================================================================
# Vivado 时序分析脚本
# 产物: runs/vivado_YYYYMMDD_HHMMSS/
# ============================================================================

set TOP      core_top
set PART     xc7a100tcsg324-1
set PERIOD   10.0 ;# 100MHz

# 产物目录: runs/vivado_<timestamp>/
set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir "runs/vivado_${ts}"
file mkdir $outdir
puts "Output: $outdir"

# ========== 1. 读源文件 ==========
puts "=== 1. Read Verilog ==="
set src_dir [file normalize "[file dirname [info script]]/.."]
puts "Source dir: $src_dir"
set file_cnt 0
foreach f [lsort [glob -nocomplain "$src_dir/*.v"]] {
    puts "  [file tail $f]"
    read_verilog -sv $f
    incr file_cnt
}
puts "  $file_cnt files loaded"

# ========== 2. 综合 ==========
puts "=== 2. Synthesis ==="
synth_design -top $TOP -part $PART -flatten_hierarchy rebuilt

# ========== 3. 约束 ==========
puts "=== 3. Constraints ==="
create_clock -period $PERIOD -name aclk [get_ports aclk]
set_clock_uncertainty -setup 0.3 [get_clocks aclk]

set inputs [filter [all_inputs] {NAME !~ *aclk* && NAME !~ *aresetn*}]
set_input_delay -clock aclk -max 1.0 $inputs
set_input_delay -clock aclk -min 0.2 $inputs

set_output_delay -clock aclk -max 1.0 [all_outputs]
set_output_delay -clock aclk -min 0.2 [all_outputs]

if {[catch {get_ports {break_point infor_flag reg_num}} debug_ports] == 0} {
    if {[llength $debug_ports] > 0} { set_false_path -from $debug_ports }
}

# ========== 4. 时序报告 ==========
puts "=== 4. Report ==="

report_timing_summary   -file "$outdir/timing_summary.rpt"
report_timing           -max_paths 50 -nworst 50 -delay_type max -sort_by slack -input_pins -nets -file "$outdir/critical_paths.rpt"
report_high_fanout_nets -max_nets 30 -file "$outdir/high_fanout.rpt"
report_utilization      -file "$outdir/utilization.rpt"
if {[catch {report_clock_networks -file "$outdir/clock.rpt"}]} { puts "  (clock_networks skip)" }

# ========== 5. 写 DCP (可选，保留综合结果) ==========
write_checkpoint -force "$outdir/post_synth.dcp"

# ========== 6. 摘要 ==========
puts ""
puts "============================================================"
puts "  Done -> $outdir/"
puts "============================================================"
foreach f [lsort [glob -nocomplain "$outdir/*"]] {
    puts "  [file tail $f]  [file size $f]"
}
