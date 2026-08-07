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
xcodebuild \
    -project FastSCP.xcodeproj \
    -scheme FastSCP \
    -configuration Debug \
    -destination 'platform=macOS' \
    build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    -quiet

echo "==> 4/4 Release 构建并安装到 /Applications"
exec "$ROOT/scripts/install.sh"
