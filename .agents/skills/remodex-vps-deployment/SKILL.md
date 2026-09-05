---
name: remodex-vps-deployment
description: 部署、核验或回滚本仓库的生产 Remodex 密文 Relay 时使用；固定连接 cc.syggu.cn 对应 VPS，并限制操作只影响 Relay 与已声明的旧 CC-Connect 服务。普通本地开发、iOS/Mac 构建或其他服务器不使用。
---

# Remodex VPS 部署

VPS 通过 Docker Compose 提供 Setup、GitHub 登录、账号审核、设备授权和密文 WebSocket 转发。SQLite 仅保存管理数据；VPS 不运行 Codex/模型，不保存聊天、代码或工作区，不提供 Push/APNs。

## 固定身份

- SSH 目标：`root@106.55.5.233`
- 私钥：`/Users/wangshangbin/Downloads/pem/2h4g5mGzShus.pem`
- known_hosts：`/Users/wangshangbin/.ssh/known_hosts`
- 已核验私钥公钥指纹：`SHA256:NBecM7czcydF3DhUASCtLIpB5OfZrl3C962ykmzvuT0`
- SSH 必须显式使用 `IdentitiesOnly=yes`、`StrictHostKeyChecking=yes`、`UserKnownHostsFile=/Users/wangshangbin/.ssh/known_hosts`。

后续部署直接使用以上私钥路径，不再询问。不得显示、复制或提交私钥内容；指纹不等于服务器 host key，host key 仍由固定 known_hosts 严格校验。

## 操作边界

部署前读取仓库当前 `relay/Dockerfile`、`relay/compose.yaml`、根锁文件和 [事务切换手册](references/cutover.md)。实时核验容器、systemd、监听端口、健康响应和反向代理上游，但不得修改 1Panel、OpenResty、PostgreSQL、Redis、其他站点、容器或系统服务。

只允许管理：

- 新 `remodex-relay`、`remodex-updater`、事务所属的 `remodex-relay-rollback`、命名明确的临时候选容器及其独立部署目录、数据卷；
- 旧 `cc-connect-deploy-host.service`；
- 旧 CC-Connect 容器；
- `/opt/cc-connect-docker` 与 `/var/lib/cc-connect-docker`，且只能在完整验收后删除。

保持 `cc.syggu.cn` TLS/OpenResty 配置及其 `127.0.0.1:9820` 上游不变。业务 Relay 必须非 root、只读根文件系统、`cap_drop: ALL`、带日志轮转，且只绑定 `127.0.0.1:9820`；不得挂 Docker Socket。独立更新执行器没有公网端口，但拥有 Docker 管理权限，不可声称容器隔离消除了宿主风险。SQLite、更新事务与备份使用独立卷；主密钥、Setup 与执行器凭据只读挂载，不打印凭据。不得使用首次安装脚本覆盖已有部署目录。

旧单容器迁移须先验证双容器方案、签名正式发布清单、容器归属标签、更新执行器协议、备份与回滚，再取得生产切换授权。源码变更、打包成功或检查新版本都不构成部署授权。读 [管理与更新运维](../../../Docs/CONTROL-OPERATIONS.md) 了解当前限制；Linux Docker 实机未验证的方案不得宣称生产验收通过。

## 测试部署授权

默认仍要求完整端到端验收。只有用户明确同意先测试切换、稍后用 iPhone 验收时，才可先完成隔离容器启动、健康、Setup 防抢占、未授权接入拒绝及外部 TLS/代理检查后切换。必须记录缺失的 OAuth／真机／E2E 验收，保留旧目录、制品和精确服务状态，不宣称正式验收通过，不删除回滚点。用户于 2026-09-05 在确认这一边界后要求“直接重建”；此授权仅适用于本次测试切换，不构成以后跳过验收的默认许可。

## 完成条件

切换按一个可回滚事务处理。旧目录和服务是回滚点，在以下信号全部成立前不得删除：

1. 容器健康检查和 VPS 本机 `/health` 返回精确 `{"ok":true}`；
2. `wss://cc.syggu.cn` 已授权 WebSocket 握手成功，未授权请求被拒绝；测试部署尚未 Setup 时，401 只证明入口鉴权可达，不能代替已授权握手；
3. Mac App 与 iPhone 完成 E2E 配对和至少一次加密 RPC；
4. 抓包或 Relay 结构化日志确认只出现密文负载和连接元数据；
5. 无 Push/APNs 路由，且同会话/跨会话隔离验收通过。

任一信号失败时停止新容器并恢复旧容器与 `cc-connect-deploy-host.service`；报告真实失败，不修改反向代理或同机无关资源来绕过。只有用户在当前任务明确要求生产切换时才执行写操作。
