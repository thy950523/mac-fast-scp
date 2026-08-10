#!/bin/bash
# 一键执行：重新生成 Xcode 工程 → 跑核心测试 → 构建 → 安装到 /Applications。
#
# 日常开发用这个脚本验证「实时进度」改动；纯核心逻辑改动可只跑到测试那一步。
# 安装步骤（重签名、清理重复扩展注册）复用 install.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 1/4 重新生成 Xcode 工程（xcodegen）"
xcodegen generate

echo "==> 2/4 运行 FastSCPCore 单元测试"
xcodebuild test \
    -project FastSCP.xcodeproj \
    -scheme FastSCPCore \
    -destination 'platform=macOS' \
    -quiet

echo "==> 3/4 构建 FastSCP.app（Debug）"
# 用临时 derivedDataPath 并随后删除：留在共享 DerivedData 里的 .app 会被
# LaunchServices 记一条，导致「设置 > 扩展」里多出一行同名 FastSCP。
DEBUG_BUILD_DIR="${TMPDIR:-/tmp}/fastscp-debug-build"
DEBUG_APP="$DEBUG_BUILD_DIR/Build/Products/Debug/FastSCP.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# xcodebuild 失败时 set -e 会跳过清理，用 trap 兜住两条路径。
# 删目录前先注销：只删不注销的话，LaunchServices 要过几十秒才淘汰这条记录，
# 而 install.sh 末尾的核对紧接着就跑，会把它显示出来、看着像没清干净。
cleanup_debug_build() {
    if [ -d "$DEBUG_APP" ]; then
        "$LSREGISTER" -u "$DEBUG_APP" 2>/dev/null || true
    fi
    rm -rf "$DEBUG_BUILD_DIR"
}
trap cleanup_debug_build EXIT
rm -rf "$DEBUG_BUILD_DIR"
xcodebuild \
    -project FastSCP.xcodeproj \
    -scheme FastSCP \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DEBUG_BUILD_DIR" \
    build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    -quiet
cleanup_debug_build

echo "==> 4/4 Release 构建并安装到 /Applications"
exec "$ROOT/scripts/install.sh"
