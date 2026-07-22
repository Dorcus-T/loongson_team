# ============================================================================
# Full project timing analysis: synthesis + optional implementation
# synthesis only:  post-synth timing (estimated wire delays)
# implementation:  post-route timing (real wire delays, most accurate)
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

# ========== 2. Sync source files ==========
puts "=== 2. Sync source files ==="

# 2a. Replace stale imported copies with fresh IP/myCPU/ sources
# The project may have old copies in imports/myCPU/ that are out of date.
set existing [get_files -quiet -of_objects [get_filesets sources_1]]
set replaced 0
set added 0

foreach f [lsort [glob -nocomplain "$CPU_DIR/*.v"]] {
    set tail [file tail $f]
    set found 0
    set stale_path ""

    foreach e $existing {
        if {[file tail $e] eq $tail} {
            set found 1
            # Check if the project file is a stale copy (under imports/)
            if {[string match "*imports*" $e]} {
                set stale_path $e
            }
            break
        }
    }

    if {$stale_path ne ""} {
        # Replace stale import with fresh source
        puts "  replace $tail (was stale import)"
        remove_files -fileset sources_1 $stale_path -quiet
        import_files -fileset sources_1 $f
        incr replaced
    } elseif {!$found} {
        # New file not yet in project
        puts "  add $tail"
        import_files -fileset sources_1 $f
        incr added
    }
}
puts "  $replaced replaced, $added added"

# ========== 3. Synthesis ==========
puts "=== 3. Synthesis ==="
set run_status [get_property STATUS [get_runs synth_1]]
puts "  status: $run_status"

if {$run_status ne "synth_design Complete!"} {
    puts "  re-running synthesis..."
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
open_run synth_1

# ----- Post-synth reports -----
puts "--- 3a. Post-synth reports ---"
report_timing_summary -file "$outdir/timing_summary_synth.rpt"
report_timing -max_paths 50 -nworst 50 -delay_type max \
  -sort_by slack -input_pins -nets \
  -file "$outdir/critical_paths_synth.rpt"
report_high_fanout_nets -max_nets 20 -file "$outdir/high_fanout_synth.rpt"
report_utilization -file "$outdir/utilization_synth.rpt"

# ========== 4. Implementation ==========
puts "=== 4. Implementation ==="

# 4a. opt_design (逻辑优化)
puts "--- 4a. opt_design ---"
opt_design

# 4b. place_design (布局)
puts "--- 4b. place_design ---"
place_design

report_timing_summary -file "$outdir/timing_summary_placed.rpt"

# 4c. route_design (布线 — 真实延迟)
puts "--- 4c. route_design ---"
route_design

# ----- Post-route reports (most accurate) -----
puts "--- 4d. Post-route reports ---"
report_timing_summary -file "$outdir/timing_summary_routed.rpt"
report_timing -max_paths 50 -nworst 50 -delay_type max \
  -sort_by slack -input_pins -nets \
  -file "$outdir/critical_paths_routed.rpt"
report_high_fanout_nets -max_nets 20 -file "$outdir/high_fanout_routed.rpt"
report_utilization -file "$outdir/utilization_routed.rpt"
report_clock_interaction -file "$outdir/clock_interaction.rpt"
report_methodology -file "$outdir/methodology.rpt"

write_checkpoint -force "$outdir/post_route.dcp"

puts ""
puts "============================================================"
puts "  Done -> $outdir/"
puts "============================================================"
foreach f [lsort [glob -nocomplain "$outdir/*"]] {
    puts "  [file tail $f]  [format {%8d} [file size $f]]"
}
