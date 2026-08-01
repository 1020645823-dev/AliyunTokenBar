#!/usr/bin/env bash
# build-package.sh — 构建 AliyunTokenBar,封装成签名 .app,再打成 .dmg
#
# 用法:
#   ./packaging/build-package.sh              # 默认 1.0.0,本地测试 appcast
#   VERSION=1.0.1 ./packaging/build-package.sh
#   APPCAST_URL=https://yoursite/appcast.xml ./packaging/build-package.sh
#
# 产出: dist/AliyunTokenBar-{VERSION}-mac.dmg  和  dist/AliyunTokenBar.app
#
# 前置:本目录或 ../Frameworks/ 下有 Sparkle.framework(见 README)
set -euo pipefail

# ---------- 配置 ----------
cd "$(dirname "$0")/.."   # 切到项目根
ROOT="$(pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP_NAME="AliyunTokenBar"
BUNDLE_ID="com.zww.aliyuntokenbar"
APPCAST_URL="${APPCAST_URL:-https://1020645823-dev.github.io/AliyunTokenBar/appcast.xml}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# ---------- 0. 前置检查 ----------
echo "==> [0/7] 前置检查"
command -v swift   >/dev/null || { echo "缺少 swift"; exit 1; }
command -v codesign>/dev/null || { echo "缺少 codesign"; exit 1; }
command -v hdiutil >/dev/null || { echo "缺少 hdiutil"; exit 1; }

# Sparkle.framework 位置:优先 packaging/Frameworks/,其次项目根 Frameworks/
SPARKLE_FW=""
for cand in "$ROOT/packaging/Frameworks/Sparkle.framework" "$ROOT/Frameworks/Sparkle.framework"; do
  if [ -d "$cand" ]; then SPARKLE_FW="$cand"; break; fi
done
if [ -z "$SPARKLE_FW" ]; then
  echo "❌ 未找到 Sparkle.framework。请先放到 packaging/Frameworks/Sparkle.framework"
  echo "   下载: https://github.com/sparkle-project/Sparkle/releases (Sparkle-x.x.x.tar.xz 解压后取 Sparkle.framework)"
  exit 1
fi
echo "    Sparkle.framework: $SPARKLE_FW"

# Sparkle 工具:generate_keys(生成 EdDSA 密钥,存 Keychain)、sign_update(签名更新包)
# 这两个工具随 Sparkle-x.x.x.tar.xz 分发(bin/ 目录),framework 包里没有。
# 若用户只放了 framework,可手动把工具放到 packaging/bin/。
GENERATE_KEYS=""
SIGN_UPDATE=""
for cand in "$ROOT/packaging/bin/generate_keys" "/usr/local/bin/generate_keys"; do
  if [ -x "$cand" ]; then GENERATE_KEYS="$cand"; break; fi
done
for cand in "$ROOT/packaging/bin/sign_update" "/usr/local/bin/sign_update"; do
  if [ -x "$cand" ]; then SIGN_UPDATE="$cand"; break; fi
done

# ---------- 1. 构建 release ----------
echo "==> [1/7] swift build -c release"
swift build -c release
BIN="$ROOT/.build/release/$APP_NAME"
[ -f "$BIN" ] || { echo "❌ 构建产物缺失: $BIN"; exit 1; }

# ---------- 2. 组装 .app bundle ----------
echo "==> [2/7] 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# Info.plist:用 PlistBuddy 写入版本号/appcast url(避免 sed 遇 URL 里的 / 出错)
PLIST="$APP/Contents/Info.plist"
cp "$ROOT/packaging/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $APPCAST_URL" "$PLIST"

# 复制 entitlements 进 Resources(签名时引用)
cp "$ROOT/packaging/AliyunTokenBar.entitlements" "$APP/Contents/Resources/"
# 复制 App 图标(Info.plist 的 CFBundleIconFile 指向 AppIcon)
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ---------- 3. 嵌入 Sparkle.framework ----------
echo "==> [3/7] 嵌入 Sparkle.framework"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# ---------- 4. EdDSA 密钥对(更新签名,存 Keychain) ----------
echo "==> [4/7] EdDSA 密钥"
# Sparkle 2.x:generate_keys 把私钥存进 macOS Keychain(条目名 "Private key for signing Sparkle updates"),
# 公钥打印到 stdout。sign_update 从 Keychain 读私钥签名。-s 传私钥已废弃(安全)。
ED_PUB_KEY=""
if [ -n "$GENERATE_KEYS" ]; then
  # 首次生成(若 Keychain 已有则 -p 只读公钥)。generate_keys -p 打印现有公钥,不重复生成。
  if [ -n "$SIGN_UPDATE" ]; then
    # 先尝试读已有公钥;读不到则生成
    ED_PUB_KEY=$("$GENERATE_KEYS" -p 2>/dev/null | tr -d '[:space:]' || true)
    if [ -z "$ED_PUB_KEY" ]; then
      echo "    生成新 EdDSA 密钥对(私钥存入 Keychain,仅一次)"
      ED_PUB_KEY=$("$GENERATE_KEYS" 2>/dev/null | grep -oE '[A-Za-z0-9+/=]{40,}' | head -1 || true)
    fi
  fi
fi
if [ -z "$ED_PUB_KEY" ]; then
  echo "    ⚠️  缺 generate_keys 工具或读取失败。SUPublicEDKey 将留占位符,更新验证会失败。"
  echo "       请把 Sparkle 的 bin/generate_keys、bin/sign_update 放到 packaging/bin/,重跑。"
  ED_PUB_KEY="PLACEHOLDER_RUN_GENERATE_KEYS_FIRST"
fi
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $ED_PUB_KEY" "$PLIST"

# ---------- 5. ad-hoc 签名 ----------
echo "==> [5/7] ad-hoc 签名"
# 先签 framework(深度),再签主可执行文件
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" 2>&1 | sed 's/^/    /' || true
codesign --force --options runtime \
  --entitlements "$ROOT/packaging/AliyunTokenBar.entitlements" \
  --sign - "$APP"
echo "    签名完成。验证:"
codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/    /' || echo "    (verify 警告对 ad-hoc 正常)"

# ---------- 6. 打 dmg(分发用) + zip(Sparkle 更新包) ----------
echo "==> [6/7] 打 dmg + zip"
DMG="$DIST/$APP_NAME-$VERSION-mac.dmg"
ZIP="$DIST/$APP_NAME-$VERSION-sparkle-update.zip"
rm -f "$DMG" "$ZIP"
# dmg:临时目录做漂亮布局(App + Applications 软链)
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "$DMG" 2>&1 | sed 's/^/    /'
rm -rf "$STAGE"
echo "    dmg: $DMG"
# zip:Sparkle 更新包(直接打 .app,Sparkle 解压后替换)。社区推荐 zip 而非 dmg,
# 因为 zip 解压即装,dmg 要挂载+拷贝环节多易错(ad-hoc 签名下尤其)。
cd "$DIST"
# ditto 保留签名/权限/软链(zip 会丢;ditto 是 Apple 推荐的 bundle 打包工具)
ditto -c -k --keepParent "$APP_NAME.app" "$(basename "$ZIP")"
cd "$ROOT"
echo "    zip: $ZIP"

# ---------- 7. 生成 appcast 片段(用 zip 作为 enclosure) ----------
echo "==> [7/7] appcast 片段"
# sign_update 从 Keychain 读私钥,对 zip 签名(Sparkle 更新包用 zip)
ED_SIG=""
if [ -n "$SIGN_UPDATE" ]; then
  ED_SIG=$("$SIGN_UPDATE" "$ZIP" 2>/dev/null | grep -oE '[A-Za-z0-9+/=]{40,}' | head -1 || true)
fi
if [ -n "$ED_SIG" ]; then
  cat > "$DIST/appcast-fragment-$VERSION.xml" <<EOF
<item>
    <title>$VERSION</title>
    <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
    <sparkle:version>$BUILD</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    <enclosure url="$APPCAST_URL/../releases/download/v$VERSION/$APP_NAME-$VERSION-sparkle-update.zip"
               length="$(stat -f%z "$ZIP")"
               type="application/octet-stream"
               sparkle:edSignature="$ED_SIG"/>
</item>
EOF
  echo "    appcast 片段(指向 zip): $DIST/appcast-fragment-$VERSION.xml"
  echo "    把它合并进线上 appcast.xml 的 <channel> 即可触发更新"
else
  echo "    (跳过:缺 sign_update 工具或签名失败,无法生成更新签名)"
fi

echo ""
echo "✅ 完成"
echo "   App:  $APP"
echo "   DMG(分发):  $DMG"
echo "   ZIP(更新):  $ZIP"
echo "   测试: open $APP"
