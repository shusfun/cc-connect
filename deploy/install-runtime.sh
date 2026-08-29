#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "用法: ./install-runtime.sh --server https://cc.example.com --tag v0.1.0 [--code <首次配对码>] [--name <设备名>]" >&2
}

server=""
code=""
tag=""
name="$(scutil --get ComputerName 2>/dev/null || hostname)"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --server) server="${2:-}"; shift 2 ;;
    --code) code="${2:-}"; shift 2 ;;
    --tag) tag="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
if [ -z "$server" ] || [ -z "$tag" ]; then usage; exit 2; fi
[[ "$server" =~ ^https://[^/]+$ ]] || { echo "--server 必须是无路径的 HTTPS 地址" >&2; exit 1; }
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || { echo "无效 tag" >&2; exit 1; }
state="$HOME/Library/Application Support/cc-connect-runtime"
identity="$state/identity.json"
for command in curl jq shasum tar launchctl; do
  command -v "$command" >/dev/null 2>&1 || { echo "缺少必需命令: $command" >&2; exit 1; }
done
if [ -f "$identity" ]; then
  existing_server="$(jq -er '.server_url' "$identity")"
  test "$existing_server" = "$server" || { echo "Runtime 已配对到其他服务器: $existing_server" >&2; exit 1; }
else
  [ -n "$code" ] || { echo "首次安装必须提供 --code" >&2; exit 2; }
fi
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  arm64) arch=arm64 ;;
  *) echo "不支持的 macOS 架构" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
release_url="https://github.com/shusfun/cc-connect/releases/download/$tag"
curl --fail --location --proto '=https' --tlsv1.2 -o "$tmp/manifest.json" "$release_url/manifest.json"
test "$(jq -er '.repository' "$tmp/manifest.json")" = "shusfun/cc-connect"
test "$(jq -er '.workflow' "$tmp/manifest.json")" = ".github/workflows/release.yml"
test "$(jq -er '.tag' "$tmp/manifest.json")" = "$tag"
artifact="$(jq -er --arg arch "$arch" '.artifacts[] | select(.component == "runtime" and .os == "darwin" and .arch == $arch) | .name' "$tmp/manifest.json")"
expected="$(jq -er --arg name "$artifact" '.artifacts[] | select(.name == $name) | .sha256' "$tmp/manifest.json")"
curl --fail --location --proto '=https' --tlsv1.2 -o "$tmp/$artifact" "$release_url/$artifact"
actual="$(shasum -a 256 "$tmp/$artifact" | awk '{print $1}')"
test "$actual" = "$expected" || { echo "Runtime 制品摘要不匹配" >&2; exit 1; }

slot="$state/releases/$tag"
mkdir -p "$slot" "$state/logs"
chmod 700 "$state" "$state/releases" "$slot" "$state/logs"
tar -xzf "$tmp/$artifact" -C "$slot"
chmod 755 "$slot/cc-connect-runtime"
install -m 600 "$tmp/manifest.json" "$slot/manifest.json"
echo "Runtime Release 未验证: unverified=true（已校验仓库、workflow、tag 和 SHA-256）" >&2
ln -sfn "$slot" "$state/current"
if [ ! -f "$identity" ]; then
  "$state/current/cc-connect-runtime" pair --server "$server" --code "$code" --name "$name"
fi

plist="$HOME/Library/LaunchAgents/dev.cc-connect.runtime.plist"
if launchctl print "gui/$(id -u)/dev.cc-connect.runtime" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/dev.cc-connect.runtime"
fi
rm -f "$plist"
echo "Runtime 已安装并配对，正在当前 Codex App 终端中启动。启动后可关闭该终端；Codex App 运行期间 supervisor 会持续保持 Runtime 在线。"
exec "$state/current/cc-connect-runtime"
