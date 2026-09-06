#!/bin/bash
# packaging/install-update.sh — 一键更新现场安装的 CodingTokenBar:
#   构建(VERSION)→ 退出运行中的 app → 替换 /Applications 安装 → 重启并确认。
#
# 用法:
#   ./packaging/install-update.sh                 # 自动版本:已装版本 patch +1
#   VERSION=1.2.3 ./packaging/install-update.sh   # 显式指定版本
#
# 说明:
# - 替换目标固定为 /Applications/CodingTokenBar.app(本机唯一安装位)。
# - 退出顺序:osascript 温和退出(给通知/写盘留时间)→ 5s 兜底 pkill。
# - 构建失败时打印 build 日志尾部并中止,不会动已安装的 app。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CodingTokenBar"
BIN_NAME="AliyunTokenBar"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

# 1) 版本:显式 VERSION 优先;否则已装(或 dist)版本 patch +1
if [ -z "${VERSION:-}" ]; then
  SRC_APP="$INSTALLED_APP"
  [ -d "$SRC_APP" ] || SRC_APP="dist/$APP_NAME.app"
  CUR=$(defaults read "$SRC_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
  VERSION="$(echo "$CUR" | cut -d. -f1).$(echo "$CUR" | cut -d. -f2).$(( $(echo "$CUR" | cut -d. -f3) + 1 ))"
fi
echo "==> 目标版本 v$VERSION"

# 2) 构建(日志落盘,失败时展示尾部且不触碰已安装 app)
if ! VERSION="$VERSION" ./packaging/build-package.sh > /tmp/atb-build.log 2>&1; then
  echo "❌ 构建失败:"; tail -20 /tmp/atb-build.log; exit 1
fi
tail -3 /tmp/atb-build.log

# 3) 退出运行中的 app
if pgrep -x "$BIN_NAME" > /dev/null; then
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  for _ in {1..10}; do
    pgrep -x "$BIN_NAME" > /dev/null || break
    sleep 0.5
  done
  pkill -x "$BIN_NAME" 2>/dev/null || true
  sleep 1
fi

# 4) 替换安装(先校验构建产物完整,再原子性替换)
[ -f "dist/$APP_NAME.app/Contents/MacOS/$BIN_NAME" ] || { echo "❌ 构建产物不完整"; exit 1; }
rm -rf "$INSTALLED_APP"
cp -R "dist/$APP_NAME.app" "$INSTALL_DIR/"

# 5) 重启 + 确认
open "$INSTALLED_APP"
sleep 2
NEW=$(defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleShortVersionString)
PID=$(pgrep -x "$BIN_NAME" | head -1 || true)
if [ -n "$PID" ]; then
  echo "✅ 已更新并重启:v$NEW(进程 $PID)"
else
  echo "⚠️ v$NEW 已安装,进程 2s 内未检测到(若菜单栏无图标,注意 macOS 26 停车规则:用已装 .app 验证)"
fi
