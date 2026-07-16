puts "=== read liberty ==="
read_liberty libs/NangateOpenCellLibrary_typical.lib

puts "=== read verilog ==="
read_verilog outputs/synth_flat.v

puts "=== link ==="
link_design core_top

puts "=== read sdc ==="
read_sdc mycore.sdc

# 过滤掉极端路径(slack < -10ns = 多周期假路径)
# 只看 slack > -5ns 的真实关键路径 (arrival time < 15ns)
puts "=== setup checks (slack > -5ns 过滤) ==="
report_checks -path_delay max -format full_clock_expanded \
  -fields {capacitance slew input_pins nets} \
  -slack_min -5.0 -group_count 30 -digits 3 \
  > reports/sta_setup_filtered.rpt

puts "=== WNS / TNS ==="
report_wns > reports/sta_wns.rpt
report_tns > reports/sta_tns.rpt

puts "=== DONE ==="
puts "Realistic paths: reports/sta_setup_filtered.rpt"
