#!/bin/bash
# ============================================================================
# Yosys + OpenSTA 时序分析一键脚本
# 产物: runs/sta_YYYYMMDD_HHMMSS/
# ============================================================================
set -e
cd "$(dirname "$0")"

TS=$(date +%Y%m%d_%H%M%S)
OUT="runs/sta_${TS}"
mkdir -p "$OUT"

echo "============================================================"
echo "  Yosys + OpenSTA Timing Analysis"
echo "  Output: $OUT"
echo "============================================================"

# ========== 1. Yosys: 打平网表 + Nangate45 映射 ==========
echo ""
echo "=== [1/2] Yosys synthesis ==="
yosys -p "
read_verilog -sv ../*.v;
hierarchy -check -top core_top;
read_liberty -lib -ignore_miss_dir -setattr blackbox libs/NangateOpenCellLibrary_typical.lib;
synth -top core_top;
dfflibmap -liberty libs/NangateOpenCellLibrary_typical.lib;
abc -liberty libs/NangateOpenCellLibrary_typical.lib -D 10000;
flatten;
splitnets -ports;
opt_clean;
write_verilog -noattr -nohex -nodec $OUT/synth_flat.v;
tee -q -o $OUT/area.txt stat -liberty libs/NangateOpenCellLibrary_typical.lib -width
" 2>&1 | tail -10

echo "  -> $OUT/synth_flat.v"

# ========== 2. OpenSTA: 静态时序分析 ==========
echo ""
echo "=== [2/2] OpenSTA timing ==="
sta -no_splash -exit -cmd "
read_liberty libs/NangateOpenCellLibrary_typical.lib;
read_verilog $OUT/synth_flat.v;
link_design core_top;
read_sdc mycore.sdc;
report_checks -path_delay max -format full_clock_expanded -fields {capacitance slew input_pins nets} -group_count 50 -digits 3 > $OUT/timing_setup.rpt;
report_checks -path_delay min -format full_clock_expanded -fields {capacitance slew input_pins nets} -group_count 10 -digits 3 > $OUT/timing_hold.rpt;
report_wns > $OUT/wns.txt;
report_tns > $OUT/tns.txt;
" 2>&1 | tail -5

# ========== 3. 摘要 ==========
echo ""
echo "============================================================"
echo "  Done -> $OUT/"
echo "============================================================"
ls -lh "$OUT/" | tail -20
echo ""
echo "  WNS: $(cat $OUT/wns.txt 2>/dev/null)"
echo "  TNS: $(cat $OUT/tns.txt 2>/dev/null)"
