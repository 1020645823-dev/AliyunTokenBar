#!/usr/bin/env bash
# build-package.sh — 构建 CodingTokenBar,封装成签名 .app,再打成 .dmg
#
# 用法:
#   ./packaging/build-package.sh              # 默认 1.0.0
#   VERSION=1.0.8 ./packaging/build-package.sh
#
# 产出: dist/CodingTokenBar-{VERSION}-mac.dmg  和  dist/CodingTokenBar.app
#
# 注:已移除 Sparkle 自动更新,无需 appcast/EdDSA/framework。
set -euo pipefail

# ---------- 配置 ----------
cd "$(dirname "$0")/.."   # 切到项目根
ROOT="$(pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
# BIN_NAME = SwiftPM 可执行 target 名(二进制名,用户不可见)
# APP_NAME = .app 包名/系统显示名(与 Info.plist 的 CFBundleName/CFBundleDisplayName 一致)
BIN_NAME="AliyunTokenBar"
APP_NAME="CodingTokenBar"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# ---------- 0. 前置检查 ----------
echo "==> [0/5] 前置检查"
command -v swift   >/dev/null || { echo "缺少 swift"; exit 1; }
command -v codesign>/dev/null || { echo "缺少 codesign"; exit 1; }
command -v hdiutil >/dev/null || { echo "缺少 hdiutil"; exit 1; }

# ---------- 1. 构建 release ----------
echo "==> [1/5] swift build -c release"
swift build -c release
BIN="$ROOT/.build/release/$BIN_NAME"
[ -f "$BIN" ] || { echo "❌ 构建产物缺失: $BIN"; exit 1; }

# ---------- 2. 组装 .app bundle ----------
echo "==> [2/5] 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# 可执行文件名与 Info.plist 的 CFBundleExecutable 保持一致(BIN_NAME)
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

# Info.plist:用 PlistBuddy 写入版本号
PLIST="$APP/Contents/Info.plist"
cp "$ROOT/packaging/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

# App 图标(Info.plist 的 CFBundleIconFile 指向 AppIcon)
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ---------- 3. ad-hoc 签名 ----------
echo "==> [3/5] ad-hoc 签名"
# 无 Sparkle framework,无需 disable-library-validation;基础 ad-hoc 签名即可
codesign --force --options runtime --sign - "$APP"
echo "    签名完成。验证:"
codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/    /' || echo "    (verify 警告对 ad-hoc 正常)"

# ---------- 4. 打 dmg ----------
echo "==> [4/5] 打 dmg"
DMG="$DIST/$APP_NAME-$VERSION-mac.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "$DMG" 2>&1 | sed 's/^/    /'
rm -rf "$STAGE"
echo "    dmg: $DMG"

# ---------- 5. 完成 ----------
echo ""
echo "✅ 完成"
echo "   App:  $APP"
echo "   DMG:  $DMG"
echo "   测试: open $APP"
