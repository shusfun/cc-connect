#!/bin/sh
set -eu
PREFIX=${REMODEX_INSTALL_DIR:-/opt/remodex-relay}
RELEASE=${REMODEX_RELEASE:-main}
REPO=${REMODEX_REPO:-https://github.com/shusfun/cc-connect.git}
die() { echo "Remodex 安装失败：$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "只支持 Docker 部署，请先安装 Docker Engine。"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2。"
[ "$(id -u)" -eq 0 ] || die "请使用 root 执行，或通过 sudo 运行。"
case "$PREFIX" in /opt/remodex-relay|/opt/remodex-relay/*) ;; *) die "安装目录必须位于 /opt/remodex-relay。" ;; esac
mkdir -p "$PREFIX/secrets"; umask 077
[ -f "$PREFIX/secrets/master-key" ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$PREFIX/secrets/master-key"
if [ ! -f "$PREFIX/secrets/setup-token" ]; then head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$PREFIX/secrets/setup-token"; echo "Setup 单次凭据：$(cat "$PREFIX/secrets/setup-token")"; fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
command -v git >/dev/null 2>&1 || die "安装需要 git 拉取发布制品。"
git clone --depth 1 --branch "$RELEASE" "$REPO" "$tmp/repo"
cp "$tmp/repo/relay/compose.yaml" "$PREFIX/compose.yaml"; cp "$tmp/repo/relay/Dockerfile" "$PREFIX/Dockerfile"
cp "$tmp/repo/package.json" "$PREFIX/package.json"; cp "$tmp/repo/pnpm-lock.yaml" "$PREFIX/pnpm-lock.yaml"; cp "$tmp/repo/pnpm-workspace.yaml" "$PREFIX/pnpm-workspace.yaml"
cp -R "$tmp/repo/relay" "$PREFIX/relay"
docker compose -f "$PREFIX/compose.yaml" up -d --build
echo "Remodex Relay 已启动，请打开域名完成 /setup。安装目录：$PREFIX"
