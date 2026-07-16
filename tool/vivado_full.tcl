# ============================================================================
# Full project timing analysis
# ============================================================================

set PROJECT "Z:/home/dorcus_t/chiplab/fpga/nscscc-team/run_vivado/project/loongson.xpr"
set CPU_DIR "Z:/home/dorcus_t/chiplab/IP/myCPU"

set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir "runs/full_${ts}"
file mkdir $outdir
puts "Output: $outdir"

# ========== 1. Open project ==========
puts "=== 1. Open project ==="
open_project $PROJECT

# ========== 2. Ensure all myCPU/*.v are in the project ==========
puts "=== 2. Sync source files ==="
set existing [get_files -quiet -of_objects [get_filesets sources_1]]
foreach f [lsort [glob -nocomplain "$CPU_DIR/*.v"]] {
    set tail [file tail $f]
    set found 0
    foreach e $existing {
        if {[file tail $e] eq $tail} { set found 1; break }
    }
    if {!$found} {
        puts "  adding $tail"
        import_files -fileset sources_1 $f
    }
}

# ========== 3. Synthesis ==========
puts "=== 3. Synthesis ==="
set run_status [get_property STATUS [get_runs synth_1]]
puts "  status: $run_status"

if {$run_status ne "synth_design Complete!"} {
    puts "  resetting and re-running..."
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
open_run synth_1

# ========== 4. Timing reports ==========
puts "=== 4. Timing reports ==="

report_timing_summary -file "$outdir/timing_summary.rpt"

report_timing -max_paths 100 -nworst 100 -delay_type max \
  -sort_by slack -input_pins -nets \
  -file "$outdir/critical_paths.rpt"

report_high_fanout_nets -max_nets 30 -file "$outdir/high_fanout.rpt"
report_utilization -file "$outdir/utilization.rpt"
report_clock_interaction -file "$outdir/clock_interaction.rpt"

# Post-route if available
if {[get_property STATUS [get_runs impl_1]] eq "route_design Complete!"} {
    puts "=== 4b. Post-route timing ==="
    open_run impl_1
    report_timing_summary -file "$outdir/timing_summary_post_route.rpt"
    report_timing -max_paths 50 -nworst 50 -delay_type max \
      -sort_by slack -input_pins -nets \
      -file "$outdir/critical_paths_post_route.rpt"
}

report_methodology -file "$outdir/methodology.rpt"

puts ""
puts "============================================================"
puts "  Done -> $outdir/"
puts "============================================================"
foreach f [lsort [glob -nocomplain "$outdir/*"]] {
    puts "  [file tail $f]  [file size $f]"
}
