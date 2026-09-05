# 2026-09-05 SSH 测试部署记录

用户明确授权上传当前代码重建、隔离验证后切换，手机 E2E 随后由用户测试。本次未提交、推送或发布 GitHub，不是正式发布验收。

## 输入与运行身份

- 基线：`9d5c09cb1f22addd15ffb3317f22745869603b75` 加当前未提交后台、Mac 和更新器改造。服务器归档仅含 Docker 构建所需白名单文件，没有 `.cc-connect/`、本机依赖或 PEM。
- 源码归档 SHA-256：`62ad36d0c70401b3471ddad620a04a807eb53f2d58ed4d1f39f7b4c354bca185`。
- 服务器目录：`/opt/remodex-relay/releases/test-20260905-03`。
- Relay 本地镜像 ID：`sha256:ece9e4867973ce0d68ef581d301afee8778554907078a13ab1728802cb5c73f1`。
- 更新器本地镜像 ID：`sha256:ff6af8d8ad681d017387065fd6bdbc584408c7ee77aa6253f148c4ab17646278`。
- 两个镜像均为 Linux amd64 测试构建，版本仍是 `0.5.0-alpha.1`，不是 GHCR 签名正式镜像。Node 26.6.0、pnpm 11.18.0 未改变。
- 当前容器：`remodex-relay`（`ede2f8fdf819`）、`remodex-updater`（`d0864c926de0`），Compose 项目 `remodex`。
- 数据卷：`remodex-control-data-test-20260905-03`；更新卷和本地通道卷为 `remodex_remodex-update-state`、`remodex_remodex-update-control`。

## 已验证

- Linux Docker 内 React 构建、51 项 Relay 测试、7 项更新器测试通过，没有跳过或失败。
- 当前管理员数据库的一致性副本经 schema 1 → 2 迁移后，账号、设备、手机、配对、凭据和配置内容摘要保持一致；生产切换后再次验证一致，SQLite 完整性正常。
- 隔离验证了 AES-GCM 备份、事务恢复、恢复到 schema 1 后旧镜像打开数据库。实际数据库有 1 个账号，尚无设备/手机，因此撤销非空凭据的证据来自已有更新器测试，不能声称真实设备撤销已验收。
- 本地和公网健康精确返回 `{"ok":true}`；新 React 登录页及 JS 资源可达；未登录管理请求 401、错误 Setup 凭据 403、未授权 WebSocket 401、无 Push 注册入口。
- 更新器本地通道拒绝无凭据请求；真实加密备份成功；GitHub 正式版检查成功，`candidate:null`、`error:null`。
- Relay UID/GID 10001、只读根、cap_drop ALL、日志轮转、没有 Docker Socket，仍仅绑定 `127.0.0.1:9820`。更新器无公网端口，但持有 Docker 高权限。
- 切换使用维护标记阻止新授权与管理写入；提交后解除维护。两个新容器无异常重启。
- OpenResty 两份配置摘要未变，1Panel、PHP、Redis、PostgreSQL 等容器未重启。

## 回滚保留与边界

旧数据卷 `remodex_remodex-control-data` 未改写。旧容器停止后保存完整配置，并创建独立回滚容器 `remodex-relay-rollback-test-20260905-03`；原容器 `dcce90c8f771` 已移除，避免 Compose 在更新时收编并删除回滚副本。旧镜像、旧配置和加密快照全部保留。

- 旧配置与容器重建信息：服务器发布目录下 `rollback/`（受限权限）。
- 切换时加密快照及摘要：`cutover/`；更新器另有一份 schema 2 加密备份。
- 旧 CC-Connect 容器、服务定义及两个历史目录未删除，服务仍停止/禁用。
- 首次切换在辅助容器读取受限目录时失败；旧服务已恢复。原因是辅助步骤误用业务 UID，修正为仅辅助读取使用 root 后切换完成；业务容器权限未提高。
- `cutover.sh rollback` 仅处理尚未提交事务。当前已有 `switch.committed`，脚本会拒绝覆盖恢复后的业务写入。后续回退必须重新获得操作授权，冻结写入、备份当前状态并明确数据取舍，不能直接启动旧数据库覆盖新状态。

## 未验证与后续限制

GitHub 实际登录、Mac 激活/iPhone 配对、已授权 WSS 和真实 E2E RPC、全链路密文边界仍由用户测试。没有新的签名正式 Release，真实跨正式版本安装及中断恢复尚未验收；检查成功不等于自动安装闭环已验收。测试镜像回滚支持不可变本地镜像 ID，正式更新仍必须通过固定仓库发布签名与镜像摘要校验。

基础设施 source 审计的两项 `FROM runtime` 报告是已确认的阶段别名误报；真实基础镜像固定摘要，未降低或跳过实际构建测试。
