#!/bin/sh
set -eu
PREFIX=${REMODEX_INSTALL_DIR:-/opt/remodex-relay}
[ -f "$PREFIX/compose.yaml" ] || { echo "未找到 Remodex Docker 部署。" >&2; exit 1; }
case "${1:-status}" in
  status) docker compose -f "$PREFIX/compose.yaml" ps; docker compose -f "$PREFIX/compose.yaml" exec -T relay node -e "fetch('http://127.0.0.1:9820/health').then(async r=>{if(!r.ok||await r.text()!=='{\"ok\":true}')process.exit(1)}).catch(()=>process.exit(1))"; echo "健康检查通过" ;;
  logs) docker compose -f "$PREFIX/compose.yaml" logs --tail="${2:-200}" relay ;;
  restart) docker compose -f "$PREFIX/compose.yaml" up -d ;;
  stop) docker compose -f "$PREFIX/compose.yaml" stop ;;
  update) docker compose -f "$PREFIX/compose.yaml" up -d --build ;;
  *) echo "用法：$0 {status|logs|restart|stop|update}" >&2; exit 2 ;;
esac
