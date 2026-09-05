#!/bin/bash
# 仅构建本机 Debug App；不启动服务、不安装应用、不更改登录或系统设置。
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
command -v swiftc >/dev/null || { echo '需要 Apple Command Line Tools 中的 swiftc。' >&2; exit 1; }
test "$(node --version)" = "v$(tr -d '\r\n' < .node-version)" || { echo 'Node 版本与 .node-version 不一致。' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) node_arch=x64 ;;
  arm64) node_arch=arm64 ;;
  *) echo '不支持的 Mac 架构。' >&2; exit 1 ;;
esac
output_root="$(mktemp -d "${TMPDIR:-/tmp/}remodex-macos-dev.XXXXXX")"
app="$output_root/Remodex.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
pnpm --filter remodex deploy --legacy --prod "$output_root/bridge-bundle"
node CodexMobile/scripts/validate-bridge-bundle.cjs "$output_root/bridge-bundle"
swiftc -swift-version 5 -D DEBUG -Onone -g -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  CodexMobile/RemodexMenuBar/*.swift -o "$app/Contents/MacOS/Remodex"
cp CodexMobile/BuildSupport/RemodexMenuBar-Info.plist "$app/Contents/Info.plist"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion zh_CN' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Remodex' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cn.syggu.remodex.mac' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Remodex' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$plist"
version="$(node -p 'require("./package.json").version')"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version%%-*}" "$plist"
/usr/libexec/PlistBuddy -c "Add :RemodexSourceSHA string $(git rev-parse HEAD)-local" "$plist"
/usr/libexec/PlistBuddy -c "Add :RemodexReleaseVersion string $version-dev" "$plist"
SRCROOT="$repo_root/CodexMobile" TARGET_BUILD_DIR="$output_root" \
  UNLOCALIZED_RESOURCES_FOLDER_PATH="Remodex.app/Contents/Resources" \
  PROJECT_TEMP_DIR="$output_root/runtime-cache" REMODEX_NODE_ARCH="$node_arch" \
  REMODEX_BRIDGE_BUNDLE="$output_root/bridge-bundle" \
  /bin/sh CodexMobile/scripts/prepare-macos-runtime.sh
"$app/Contents/Resources/RemodexRuntime/node/bin/node" -e \
  'require(process.argv[1]+"/Contents/Resources/RemodexRuntime/bridge/src")' "$app"
codesign --force --sign - "$app/Contents/Resources/RemodexRuntime/node/bin/node"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '\nDebug App 已构建：%s\n退出旧 Remodex 后执行：open "%s"\n临时产物位于：%s（不自动删除）\n' "$app" "$app" "$output_root"
