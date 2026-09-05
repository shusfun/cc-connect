#!/bin/bash
set -euo pipefail
# 发布时固定引导镜像，不在服务器拉源码或编译。
bootstrap_image='@REMODEX_BOOTSTRAP_IMAGE@'
[[ "$(uname -s)" == Linux ]] || { echo '服务器仅支持 Linux Docker Compose。' >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || { echo '请使用 root 或 sudo 运行。' >&2; exit 1; }
command -v docker >/dev/null || { echo '请先安装 Docker Engine，本脚本不自动安装 Docker。' >&2; exit 1; }
docker compose version >/dev/null || { echo '需要 Docker Compose v2。' >&2; exit 1; }
command -v curl >/dev/null
[[ "$bootstrap_image" =~ ^ghcr.io/shusfun/cc-connect-updater@sha256:[a-f0-9]{64}$ ]] || { echo '请下载正式 Release 中已绑定镜像摘要的 install.sh，源码脚本不能直接安装。' >&2; exit 1; }
prefix=/opt/remodex-relay
[[ ! -e "$prefix" ]] || { echo '安装目录已存在，禁止覆盖；请使用管理脚本升级。' >&2; exit 1; }
command -v ss >/dev/null || { echo '缺少 ss，无法检查端口。' >&2; exit 1; }
[[ -z "$(ss -ltnH 'sport = :9820')" ]] || { echo '9820 端口已占用。' >&2; exit 1; }
read -r -p '已配置 HTTPS 代理的公网域名（例如 cc.syggu.cn）：' domain
[[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo '域名格式不正确。' >&2; exit 1; }
echo '更新容器拥有 Docker 管理权限；业务容器没有此权限。不修改反向代理和其他服务。'
read -r -p '确认安装到 /opt/remodex-relay，绑定 127.0.0.1:9820？输入 INSTALL：' answer
[[ "$answer" == INSTALL ]] || exit 1
temporary=$(mktemp -d /tmp/remodex-install.XXXXXX)
trap 'rm -f "$temporary/manifest.json" "$temporary/compose.yaml" "$temporary/remodex.sh"; rmdir "$temporary"' EXIT
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,size=128m --entrypoint node "$bootstrap_image" packages/updater/verify-install.js > "$temporary/manifest.json"
extract() { docker run --rm -i --read-only --cap-drop ALL --entrypoint node "$bootstrap_image" -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{let v=JSON.parse(s);for(const key of process.argv[1].split("/"))v=v[key];if(typeof v!=="string")process.exit(1);process.stdout.write(v);});' "$1" < "$temporary/manifest.json"; }
tag=$(extract tag)
case "$(uname -m)" in x86_64) architecture=amd64;; aarch64|arm64) architecture=arm64;; *) echo '仅支持 amd64/arm64。' >&2; exit 1;; esac
relay_image=$(extract "images/relay/$architecture"); updater_image=$(extract "images/updater/$architecture")
for asset in compose.yaml remodex.sh; do
  curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/shusfun/cc-connect/releases/download/$tag/$asset" -o "$temporary/$asset"
  expected=$(extract "assets/$asset")
  [[ "$(sha256sum "$temporary/$asset" | cut -d ' ' -f1)" == "$expected" ]] || { echo '发布制品摘要不匹配。' >&2; exit 1; }
done
umask 077
mkdir -p "$prefix/secrets"
for key in master-key setup-token updater-token; do head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$prefix/secrets/$key"; chown 10001:10001 "$prefix/secrets/$key"; chmod 400 "$prefix/secrets/$key"; done
cp "$temporary/compose.yaml" "$prefix/compose.yaml"; cp "$temporary/remodex.sh" "$prefix/remodex.sh"; chmod 700 "$prefix/remodex.sh"
printf 'REMODEX_IMAGE=%s\nREMODEX_UPDATER_IMAGE=%s\n' "$relay_image" "$updater_image" > "$prefix/.env"
docker compose --project-name remodex --project-directory "$prefix" -f "$prefix/compose.yaml" pull
docker compose --project-name remodex --project-directory "$prefix" -f "$prefix/compose.yaml" up -d
echo "容器已启动，请访问 https://$domain/setup；客户端 E2E 尚待验证。"
echo '单次凭据保存在 /opt/remodex-relay/secrets/setup-token，仅在自己的 Setup 页面输入。'
