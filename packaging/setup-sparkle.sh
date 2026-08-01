#!/usr/bin/env bash
# setup-sparkle.sh — 把下载好的 Sparkle-x.x.x.tar.xz 处理成项目所需的文件
#
# 前置:Sparkle-x.x.x.tar.xz 已下载(放 /tmp/sparkle-bin/ 或参数指定路径)
# 产出:
#   Vendor/Sparkle/Sparkle.xcframework.zip   (供 import Sparkle)
#   packaging/Frameworks/Sparkle.framework    (嵌入 .app)
#   packaging/bin/generate_keys, sign_update  (签名工具)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

TAR="${1:-/tmp/sparkle-bin/Sparkle.tar.xz}"
[ -f "$TAR" ] || { echo "❌ 找不到 $TAR"; echo "   用法: $0 <Sparkle-x.x.x.tar.xz 路径>"; exit 1; }

WORK="$(mktemp -d)"
echo "==> 解压到 $WORK"
tar -xJf "$TAR" -C "$WORK"

# 1. Sparkle.framework → packaging/Frameworks/
echo "==> 拷贝 Sparkle.framework"
mkdir -p "$ROOT/packaging/Frameworks"
rm -rf "$ROOT/packaging/Frameworks/Sparkle.framework"
cp -R "$WORK/Sparkle.framework" "$ROOT/packaging/Frameworks/Sparkle.framework"

# 2. 签名工具 → packaging/bin/
echo "==> 拷贝 generate_keys / sign_update"
mkdir -p "$ROOT/packaging/bin"
# 工具位置:tar 根目录 或 bin/ 子目录(不同版本布局不同)
for tool in generate_keys sign_update; do
  for cand in "$WORK/$tool" "$WORK/bin/$tool"; do
    if [ -f "$cand" ]; then
      cp "$cand" "$ROOT/packaging/bin/$tool"
      chmod +x "$ROOT/packaging/bin/$tool"
      break
    fi
  done
done

# 3. 从 framework 提取 Sparkle.xcframework → Vendor/Sparkle/ (打 zip)
# Sparkle.framework 内部不含 xcframework;xcframework 来自 SPM 分发包。
# 这里用 framework 里的版本拼:Sparkle.framework 本身就是 macOS 的产物,
# SPM binaryTarget 必须用 .xcframework。我们改用另一种方式:
# 直接用 Sparkle-for-Swift-Package-Manager.zip 里的 xcframework(若已下载)。
XCF_ZIP="/tmp/sparkle-bin/Sparkle.xcframework.zip"
XCF_DIR="/tmp/sparkle-bin/Sparkle.xcframework"
if [ -f "$XCF_ZIP" ]; then
  echo "==> 发现现成 xcframework.zip,直接拷贝到 Vendor/Sparkle/"
  cp "$XCF_ZIP" "$ROOT/Vendor/Sparkle/Sparkle.xcframework.zip"
elif [ -d "$XCF_DIR" ]; then
  echo "==> 打包 xcframework → Vendor/Sparkle/Sparkle.xcframework.zip"
  cd "$XCF_DIR/.."
  zip -r "$ROOT/Vendor/Sparkle/Sparkle.xcframework.zip" Sparkle.xcframework
  cd "$ROOT"
else
  echo "⚠️  未找到 Sparkle.xcframework。"
  echo "   framework 已就位(.app 嵌入可用),但 import Sparkle 链接还需要 xcframework。"
  echo "   请另行下载 Sparkle-for-Swift-Package-Manager.zip,解压取 Sparkle.xcframework,"
  echo "   打 zip 放到 Vendor/Sparkle/Sparkle.xcframework.zip"
fi

rm -rf "$WORK"
echo ""
echo "✅ 完成。产物:"
ls -la "$ROOT/packaging/Frameworks/Sparkle.framework" 2>/dev/null | head -1
ls -la "$ROOT/packaging/bin/" 2>/dev/null
ls -la "$ROOT/Vendor/Sparkle/"*.zip 2>/dev/null
echo ""
echo "下一步:取消 Package.swift / App.swift / Menu.swift 里 Sparkle 相关注释,"
echo "       把 Sources/AliyunTokenBar/SparkleUpdater.swift.disabled 改回 .swift,"
echo "       然后 swift build 验证 import Sparkle。"
