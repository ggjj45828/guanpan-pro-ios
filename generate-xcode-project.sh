#!/bin/sh
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。请在已安装 Xcode 的 Mac 上安装 XcodeGen 后重试。" >&2
  exit 1
fi

cd "$(dirname "$0")"
xcodegen generate
echo "已生成 GuanpanProNative.xcodeproj。请用 Xcode 打开并完成签名设置。"
