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

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 只允许删除「以 FastSCP.app 结尾」「不含 .. 路径穿越」且「位于 DerivedData 或
# ~/Applications 之下」的路径。这三道闸门是刻意收紧的：脚本里出现 rm -rf 就必须
# 能一眼看出它删不到别处。
purge_app_copy() {
    local path="$1"
    case "$path" in
        */FastSCP.app) ;;
        *) echo "    ! 跳过（非 FastSCP.app）：$path"; return ;;
    esac
    # 下面的范围闸门是纯字面匹配，而 case 的 * 会匹配 /，所以
    # "$HOME/Applications/../../VICTIM/FastSCP.app" 能同时骗过前后两道。
    # 含 .. 的路径一律拒收 —— 宁可漏删，不可误删。
    case "$path" in
        *..*) echo "    ! 跳过（含 .. 路径穿越）：$path"; return 0 ;;
    esac
    case "$path" in
        "$HOME"/Library/Developer/Xcode/DerivedData/*|"$HOME"/Applications/*) ;;
        *) echo "    ! 跳过（不在允许范围内）：$path"; return ;;
    esac
    # 注意 return 0：脚本开头是 set -e，不存在的路径若原样返回 [ -d ] 的 1，
    # 整个 install.sh 会在这里中止（副本已清干净时正是这种情况）。
    [ -d "$path" ] || return 0
    echo "    - $path"
    "$LSREGISTER" -u "$path" 2>/dev/null || true
    rm -rf "$path"
}

echo "==> 清理磁盘上的竞争副本（DerivedData 构建产物 / ~/Applications 旧副本）"
# 先断源头：磁盘上的 .app 不删，lsregister -u 之后会被重新索引加回来。
while IFS= read -r p; do
    purge_app_copy "$p"
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name "FastSCP.app" -type d 2>/dev/null)
purge_app_copy "$HOME/Applications/FastSCP.app"

echo "==> 注销所有已存在的 FastSCP 扩展注册"
# || true：pipefail 下 grep 无匹配返回 1，会让 set -e 在这里中止整个安装 ——
# 而「一条注册都没有」正是上面清理副本之后的常态，那时脚本还没 ditto 到
# /Applications 就死了。没有注册可清理不是错误。
pluginkit -mADvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep "Path = " \
    | sed 's/.*Path = //' | while read -r p; do
    echo "    - $p"
    pluginkit -r "$p" 2>/dev/null || true
done || true

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
# 先主动注销再删目录：只删不注销的话，LaunchServices 要过几十秒才会淘汰
# 指向已删路径的记录，而下面的核对紧接着就跑 —— 每次都显示 2-3 行，看着像失败。
"$LSREGISTER" -u "$APP_SRC" 2>/dev/null || true
rm -rf "$BUILD_DIR"

echo "==> 启动"
open -a "$APP_DEST"
sleep 3

echo "==> 当前扩展注册（应只有一条，指向 /Applications）"
pluginkit -mADvvv 2>/dev/null | grep -A1 "$EXT_ID" | grep -E "$EXT_ID|Path = " || echo "    (未注册)"

echo "==> LaunchServices 中的 FastSCP.app 路径（应只有 /Applications 一条）"
# || true：pipefail 下 grep 无匹配会返回 1，而这是脚本最后一条命令，
# 会变成 install.sh 的退出码 —— 装好了却报失败。
"$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ "]*FastSCP\.app' | sort -u | sed 's/^/    /' || true
