#!/usr/bin/env bash
# dev-prepare.sh — 开发环境准备:把 Sparkle.framework 拷到 swift run 的 rpath 查找路径
# swift run 产出的裸可执行文件按 @loader_path/../Frameworks 找 Sparkle.framework,
# 开发时需先跑这个脚本(每次 swift package reset / clean 后重跑)。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

BIN_DIR="$(swift build --show-bin-path 2>/dev/null)"
FW_DIR="$BIN_DIR/../Frameworks"
mkdir -p "$FW_DIR"
cp -R "$ROOT/Vendor/Sparkle/Sparkle.framework" "$FW_DIR/"
echo "✅ Sparkle.framework → $FW_DIR (swift run 现在能找到 Sparkle)"
echo "   用 DYLD 无效(SIP),必须靠 rpath 物理拷贝。"
