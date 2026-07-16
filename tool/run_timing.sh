#!/bin/bash
# ============================================================================
# CPU 时序分析一键脚本
#
# 用法:
#   bash run_timing.sh              — 通用门库快速扫描（100MHz，~3min）
#   bash run_timing.sh dual         — 双频率对比（100+400MHz，~10min）
#   bash run_timing.sh nangate      — Nangate45 真实延迟（~15min，推荐）
#   bash run_timing.sh clean        — 清理输出
#
# 输出: reports/ outputs/
# 详细: 见 README.md 和 ../doc/时序分析报告.md
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
mkdir -p reports outputs

MODE="${1:-quick}"

case "$MODE" in
    clean)
        echo "清理时序分析输出..."
        rm -rf reports/ outputs/
        echo "完成。"
        exit 0
        ;;
    dual)
        echo "=== 双频率扫描 (100MHz + 400MHz) ==="
        yosys analyze.ys 2>&1 | tail -20
        ;;
    nangate)
        echo "=== Nangate45 45nm 分析 ==="
        if [ ! -f libs/NangateOpenCellLibrary_typical.lib ]; then
            echo "Nangate45 库未找到，正在下载..."
            bash download_nangate.sh
        fi
        yosys nangate_analyze.ys 2>&1 | tail -20
        ;;
    quick|*)
        echo "=== 快速扫描 (100MHz) ==="
        yosys quick_timing.ys 2>&1 | tail -20
        ;;
esac

echo ""
echo "报告位置: reports/"
echo "详细分析: ../doc/时序分析报告.md"
