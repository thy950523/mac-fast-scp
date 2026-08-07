#!/bin/bash
# 构建 Release 并安装到 /Applications，同时清理重复的扩展注册。
#
# 手动 cp/ditto 安装会踩两个坑，这个脚本一并处理：
#   1. 嵌套的 FastSCPCore.framework 签名会失效（Team ID 不匹配 → dyld 启动崩溃），
#      必须自底向上重新 ad-hoc 签名。
#   2. 每个构建路径都会在 PluginKit 里留一条注册，导致
#      「设置 > 登录项与扩展 > 扩展」里出现多行同名 FastSCP。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/fastscp-install-build"
APP_DEST="/Applications/FastSCP.app"
EXT_ID="com.zhuzhong.FastSCP.FinderSync"

echo "==> 构建 Release"
rm -rf "$BUILD_DIR"
xcodebuild -project "$ROOT/FastSCP.xcodeproj" -scheme FastSCP \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" build >/dev/null
APP_SRC="$BUILD_DIR/Build/Products/Release/FastSCP.app"

echo "==> 注销所有已存在的 FastSCP 扩展注册"
pluginkit -mDvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep "Path = " \
    | sed 's/.*Path = //' | while read -r p; do
    echo "    - $p"
    pluginkit -r "$p" 2>/dev/null || true
done

echo "==> 退出正在运行的 FastSCP"
pkill -f "FastSCP.app/Contents/MacOS/FastSCP" 2>/dev/null || true
sleep 1

echo "==> 安装到 $APP_DEST"
rm -rf "$APP_DEST"
ditto "$APP_SRC" "$APP_DEST"

# 自底向上重签：先内层 framework，再 appex，最后外层 App。
# 顺序反了会让外层签名立刻失效。
echo "==> 重新签名（ad-hoc，自底向上）"
codesign --force --sign - "$APP_DEST/Contents/Frameworks/FastSCPCore.framework"
codesign --force --sign - "$APP_DEST/Contents/PlugIns/FastSCPFinderSync.appex/Contents/Frameworks/FastSCPCore.framework"
codesign --force --sign - \
    --entitlements "$ROOT/Sources/FastSCPFinderSync/FastSCPFinderSync.entitlements" \
    "$APP_DEST/Contents/PlugIns/FastSCPFinderSync.appex"
codesign --force --sign - \
    --entitlements "$ROOT/Sources/FastSCP/FastSCP.entitlements" "$APP_DEST"
codesign -v --deep --strict "$APP_DEST"

echo "==> 注册 App 与扩展"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DEST"
pluginkit -a "$APP_DEST/Contents/PlugIns/FastSCPFinderSync.appex"

# 构建产物本身也带一份 appex，留着会被再次扫描成重复项。
rm -rf "$BUILD_DIR"

echo "==> 启动"
open -a "$APP_DEST"
sleep 3

echo "==> 当前扩展注册（应只有一条，指向 /Applications）"
pluginkit -mAvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep -E "$EXT_ID|Path = " || echo "    (未注册)"
