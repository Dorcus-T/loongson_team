# ============================================================================
# 完整工程时序分析
# 用法: vivado -mode batch -source vivado_full.tcl
# ============================================================================

set PROJECT "Z:/home/dorcus_t/chiplab/fpga/nscscc-team/run_vivado/project/loongson.xpr"

set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir "runs/full_${ts}"
file mkdir $outdir
puts "Output: $outdir"

# ========== 1. 打开工程 ==========
puts "=== 1. Open project ==="
open_project $PROJECT

# ========== 2. 确认综合已完成 (复用已有结果) ==========
puts "=== 2. Synthesis status ==="
set run_status [get_property STATUS [get_runs synth_1]]
puts "  synth_1: $run_status"
if {$run_status ne "synth_design Complete!"} {
    puts "  Re-running synthesis..."
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
open_run synth_1

# ========== 3. 时序报告 ==========
puts "=== 3. Timing reports ==="

report_timing_summary -file "$outdir/timing_summary.rpt"

report_timing -max_paths 100 -nworst 100 -delay_type max \
  -sort_by slack -input_pins -nets \
  -file "$outdir/critical_paths.rpt"

report_high_fanout_nets -max_nets 30 -file "$outdir/high_fanout.rpt"

report_utilization -file "$outdir/utilization.rpt"

report_clock_interaction -file "$outdir/clock_interaction.rpt"

# 如果有布局布线结果，也跑一份
if {[get_property STATUS [get_runs impl_1]] eq "route_design Complete!"} {
    puts "=== 3b. Post-route timing ==="
    open_run impl_1
    report_timing_summary -file "$outdir/timing_summary_post_route.rpt"
    report_timing -max_paths 50 -nworst 50 -delay_type max \
      -sort_by slack -input_pins -nets \
      -file "$outdir/critical_paths_post_route.rpt"
}

# ========== 4. 方法学检查 ==========
report_methodology -file "$outdir/methodology.rpt"

puts ""
puts "============================================================"
puts "  Done -> $outdir/"
puts "============================================================"
foreach f [lsort [glob -nocomplain "$outdir/*"]] {
    puts "  [file tail $f]  [file size $f]"
}
