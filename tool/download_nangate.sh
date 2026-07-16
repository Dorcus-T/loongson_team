#!/bin/bash
# ============================================================================
# 下载 Nangate45 开源标准单元库（45nm 工艺）
#
# Nangate45 来源于 Nangate Open Cell Library，是学术界和开源 EDA
# 社区广泛使用的标准单元库，有相对真实的延迟和面积参数。
#
# 库来源: https://github.com/parallella/oh
# 包含: NangateOpenCellLibrary_typical.lib (~600 cells)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBS_DIR="$SCRIPT_DIR/libs"

mkdir -p "$LIBS_DIR"

echo "[1/2] 下载 Nangate45 库 ..."

# 使用 parallella/oh 仓库中的 NangateOpenCellLibrary
# 该仓库 AGPL 授权，仅用于学术研究
if [ ! -f "$LIBS_DIR/NangateOpenCellLibrary_typical.lib" ]; then
    # 尝试多个镜像源
    URLS=(
        "https://raw.githubusercontent.com/parallella/oh/master/lib/NangateOpenCellLibrary_typical.lib"
        "https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
    )
    for url in "${URLS[@]}"; do
        echo "  尝试: $url"
        if curl -fSL --connect-timeout 10 "$url" -o "$LIBS_DIR/NangateOpenCellLibrary_typical.lib" 2>/dev/null; then
            echo "  下载成功！"
            break
        fi
    done
    if [ ! -f "$LIBS_DIR/NangateOpenCellLibrary_typical.lib" ]; then
        echo "[ERROR] 无法下载 Nangate45 库。"
        echo "  请手动下载并放到: $LIBS_DIR/"
        echo "  来源: git clone https://github.com/parallella/oh.git"
        echo "  路径: oh/lib/NangateOpenCellLibrary_typical.lib"
        exit 1
    fi
else
    echo "  Nangate45 库已存在，跳过下载。"
fi

echo "[2/2] 验证库文件 ..."
LIB_SIZE=$(wc -c < "$LIBS_DIR/NangateOpenCellLibrary_typical.lib")
echo "  库大小: $LIB_SIZE bytes"
grep -c 'cell (' "$LIBS_DIR/NangateOpenCellLibrary_typical.lib" || true
echo "  库路径: $LIBS_DIR/NangateOpenCellLibrary_typical.lib"

echo ""
echo "============================================================"
echo "  Nangate45 库下载完成！"
echo "  现在可以运行: bash run_timing.sh nangate"
echo "============================================================"
