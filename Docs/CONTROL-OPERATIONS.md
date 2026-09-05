# 管理与更新运维

## 当前实现与权限

业务服务依旧绑定 `127.0.0.1:9820`。React 静态页面与管理 API 随 Relay 镜像交付。网页通过 CSRF 保护的会话访问管理接口，设备和手机通过独立签名接口接入。

`remodex-updater` 是独立执行器，通过受凭据保护的 Unix Socket 接受固定操作。它挂载 Docker Socket、Remodex 数据卷和 `/opt/remodex-relay` 部署目录，具有高权限。不能将其暴露到公网；业务容器没有 Docker Socket，也不能提交 shell、容器名、镜像地址或 Compose 内容。只允许固定仓库正式版，镜像 digest 与签名清单绑定。

新前端需要先运行 `pnpm --filter @remodex/control run build`。未构建时页面明确返回 `control_build_required`，不回退旧表单。所有依赖固定在根 pnpm catalog/锁文件中。

依赖状态校验采用 `verifyDepsBeforeRun: error`，不允许执行脚本时隐式重装 production 依赖；项目固定 `enableGlobalVirtualStore: false`，避免 CI 与本机全局设置导致同一锁文件被判为不同安装状态。不修改用户全局 pnpm 设置。

## 账号与恢复

管理员密码最低 6 位，必须包含大写和小写英文字母。原有密码仍可验证；改密码原子更新哈希并注销全部浏览器会话，不撤销设备。普通 GitHub 用户不提供密码入口。

系统配置先暂存加密候选值，实际 GitHub 登录确认仍是原管理员身份后才提交 revision；失败保留原配置。更换域名时验证阶段使用原站点回调，新站点生效后需同步调整 GitHub OAuth 回调；反向代理不自动修改。

忘记管理员密码可在获授权的服务器运行 `bash /opt/remodex-relay/remodex.sh reset-password`，密码只通过隐藏输入和标准输入传递。

## 更新与备份

自动检查周期为 6 小时，不自动安装，不接受 alpha/beta。只有源版本与正式 tag 相符，所有平台构建通过，才生成签名发布单元。没有正式版时不能用现有 alpha 代替。

```text
管理员确认 → 验证签名/镜像/空间 → 拉取镜像 → 维护并停止业务
  → 一致性备份 → 替换并迁移 → 健康/API/未授权 WS 检查
  → 保存部署 digest → 提交 → 恢复业务写入 → 等待实际客户端 E2E
```

提交前失败恢复旧镜像及冻结时备份。提交后的清理失败不回退数据库。执行器重启根据独立事务记录恢复；恢复失败保持维护，不无限重试。不要手工删除维护标记来掩盖失败。

备份用 SQLite backup API，AES-GCM 加密，默认保留最近 10 份，当前回滚点受保护。历史备份恢复只允许相同实例/schema/版本，撤销恢复出的会话、设备凭据、配对和一次性邀请，避免权限复活。跨版本历史恢复不自动执行，应先在隔离环境准备对应版本。

主密钥必须由管理员独立保管。仅有加密备份而丢失主密钥无法恢复；网页不提供主密钥导出。

管理脚本提供 `status`、`logs`、`check`、`update VERSION`、`backup`、`backups`、`restore ID`、`rollback`、`reset-password`。`rollback` 仅重试尚未提交且恢复失败的事务，不能覆盖已经恢复业务写入的数据库。

## 首次部署与既有服务器

正式 Release 中的 `install.sh` 带有固定引导镜像 digest。引导容器不挂宿主卷或 Docker Socket，验证 Release 签名及 Compose/脚本摘要后才安装。源码脚本保留占位符并拒绝直接执行。

现有 `/opt/remodex-relay` 一律拒绝被首次安装脚本覆盖。旧单容器测试部署迁移必须保留原目录、数据库和镜像，补齐执行器凭据、归属标签、卷和挂载，先隔离验证再取得生产授权。保持旧 CC-Connect 回滚点，不能将应用更新授权扩大为其他服务清理。

## 验证边界

本地可运行 React 构建、Bridge/Relay/更新器测试、Swift 类型检查与 Debug 构建。Docker 在本机 macOS 禁止启动，Linux 双容器运行、实际签名 Release 下载、生产 OAuth 配置验证、Mac/iPhone E2E 以及 Windows/iPhone 真机仍需各自环境证据。

基础设施审计脚本目前将 `FROM runtime` 这一已在同 Dockerfile 定义的阶段别名误判为浮动镜像。真实基础镜像使用固定 Node 26.6.0 digest；不修改全局审计器或创建例外掩盖误报。
