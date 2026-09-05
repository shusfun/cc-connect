#!/bin/bash
set -euo pipefail
command -v docker >/dev/null || { echo '需要 Docker Engine 与 Compose v2。' >&2; exit 1; }
docker compose version >/dev/null
prefix=/opt/remodex-relay
[[ -f "$prefix/compose.yaml" ]] || { echo '未找到受管理的 Remodex 安装。' >&2; exit 1; }
case "${1:-status}" in
  status|backups|check|backup) docker exec remodex-updater node packages/updater/cli.js "${1:-status}" ;;
  update) [[ -n "${2:-}" ]] || { echo '用法：remodex.sh update 正式版本号；先执行 check。' >&2; exit 1; }; docker exec remodex-updater node packages/updater/cli.js install "$2" ;;
  restore) [[ -n "${2:-}" ]] || exit 1; read -r -p '恢复会退出所有浏览器并撤销旧设备授权。输入 RESTORE 确认：' answer; [[ "$answer" == RESTORE ]] || exit 1; docker exec remodex-updater node packages/updater/cli.js restore "$2" ;;
  logs) docker logs --tail 200 remodex-relay ;;
  upgrade-executor)
    read -r -p '仅更新独立执行器，业务版本不变。输入 UPGRADE 确认：' answer; [[ "$answer" == UPGRADE ]] || exit 1
    state=$(docker exec remodex-updater node packages/updater/cli.js status)
    printf '%s' "$state" | docker exec -i remodex-updater node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{if(JSON.parse(s).busy||["recovery_failed","rolling_back"].includes(JSON.parse(s).phase))process.exit(1);});'
    old_image=$(docker inspect -f '{{.Config.Image}}' remodex-updater)
    [[ "$old_image" =~ ^ghcr.io/shusfun/cc-connect-updater@sha256:[a-f0-9]{64}$ ]] || exit 1
    manifest=$(docker run --rm --read-only --cap-drop ALL --tmpfs /tmp:rw,nosuid,size=128m --entrypoint node "$old_image" packages/updater/verify-install.js)
    next_image=$(printf '%s' "$manifest" | docker exec -i remodex-updater node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).images.updater[process.arch==="arm64"?"arm64":"amd64"]));')
    [[ "$next_image" =~ ^ghcr.io/shusfun/cc-connect-updater@sha256:[a-f0-9]{64}$ ]] || exit 1
    docker pull "$next_image"
    docker stop remodex-updater >/dev/null
    # 停止后再查事务，避免自动检查或管理员请求在第一次检查后进入更新。
    if ! docker run --rm --read-only --cap-drop ALL -v remodex_remodex-update-state:/state:ro --entrypoint node "$old_image" -e 'const fs=require("node:fs");const s=JSON.parse(fs.readFileSync("/state/transaction.json"));if(fs.existsSync("/state/maintenance")||!["idle","checking","failed","complete","rolled_back"].includes(s.phase))process.exit(1);'; then docker start remodex-updater >/dev/null; echo '发现未完成事务，保留原执行器处理。' >&2; exit 1; fi
    cp "$prefix/.env" "$prefix/.env.before-updater"
    sed "s|^REMODEX_UPDATER_IMAGE=.*|REMODEX_UPDATER_IMAGE=$next_image|" "$prefix/.env.before-updater" > "$prefix/.env"
    if ! docker compose --project-name remodex --project-directory "$prefix" -f "$prefix/compose.yaml" up -d --no-deps updater; then
      cp "$prefix/.env.before-updater" "$prefix/.env"; docker compose --project-name remodex --project-directory "$prefix" -f "$prefix/compose.yaml" up -d --no-deps updater; exit 1
    fi
    echo '执行器已更换，请执行 status 核对；业务容器未重启。' ;;
  rollback) read -r -p '仅恢复中断且尚未提交的事务。输入 ROLLBACK 确认：' answer; [[ "$answer" == ROLLBACK ]] || exit 1; docker exec remodex-updater node packages/updater/cli.js rollback ;;
  reset-password)
    read -r -p '本地管理员账号：' admin_login
    read -r -s -p '新密码（至少 6 位，包含大小写）：' admin_password; printf '\n'
    read -r -s -p '再次输入：' confirmation; printf '\n'
    [[ "$admin_password" == "$confirmation" ]] || { echo '两次输入不同。' >&2; exit 1; }
    printf '%s\n%s' "$admin_login" "$admin_password" | docker exec -i remodex-relay node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const i=s.indexOf("\n");const p=require("node:child_process").spawn(process.execPath,["relay/reset-password.js"],{stdio:["pipe","inherit","inherit"]});p.stdin.end(JSON.stringify({login:s.slice(0,i),password:s.slice(i+1)}));s="";p.on("exit",c=>process.exitCode=c??1);});'
    unset admin_password confirmation ;;
  *) echo '用法：remodex.sh {status|logs|check|update VERSION|backup|backups|restore ID|rollback|upgrade-executor|reset-password}' >&2; exit 2 ;;
esac
