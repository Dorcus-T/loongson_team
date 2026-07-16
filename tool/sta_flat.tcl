puts "=== read liberty ==="
read_liberty libs/NangateOpenCellLibrary_typical.lib

puts "=== read verilog ==="
read_verilog outputs/synth_flat.v

puts "=== link ==="
link_design core_top

puts "=== read sdc ==="
read_sdc mycore.sdc

puts "=== setup checks (最差 30 条) ==="
report_checks -path_delay max -format full_clock_expanded \
  -fields {capacitance slew input_pins nets} \
  -group_count 30 -digits 3 \
  > reports/sta_setup.rpt

puts "=== hold checks (最差 10 条) ==="
report_checks -path_delay min -format full_clock_expanded \
  -fields {capacitance slew input_pins nets} \
  -group_count 10 -digits 3 \
  > reports/sta_hold.rpt

puts "=== WNS / TNS ==="
report_wns > reports/sta_wns.rpt
report_tns > reports/sta_tns.rpt

puts "=== DONE ==="
puts "Setup: reports/sta_setup.rpt"
puts "Hold:  reports/sta_hold.rpt"
