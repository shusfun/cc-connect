# Remodex 项目约束

本仓库是私有移动开发终端，不是托管 Codex 服务。

## 架构边界

- Codex、Git、工作区与任务只在用户的 macOS／Windows 开发设备运行；iPhone 允许本地 Whisper 转写。
- VPS 只支持 Docker Compose，提供账号审核、设备授权、管理后台与 E2E 密文转发；SQLite 只保存管理数据，不保存聊天、代码或模型，不提供 Push/APNs。
- macOS／Windows 原生 App 是各自 Bridge 生命周期唯一所有者。不得恢复全局 npm/remodex CLI、Bridge 系统服务或登录 shell 依赖。
- iPhone 只消费私有同步协议与本地派生缓存；能力不兼容时明确要求更新，不增加旧协议 fallback。
- 不把 Mac 本地路径、密钥、Token、Cookie、聊天正文、会话标识或原始客户端 IP 暴露给 Relay 日志。

## 当前契约

- Node `26.6.0`、pnpm `11.18.0`，根 workspace 单一锁文件。
- GRDB.swift `7.11.1`、WhisperKit `1.1.0`、iOS 26。
- 首个支持的 Codex CLI 为 `0.147.0`。
- 同步 RPC：`sync/hello`、`sync/catalog`、`sync/thread/read`、`sync/thread/reset`、`sync/ack`。
- 缓存按 Relay 实例／账号／开发设备隔离，HMAC 索引、AES-GCM 正文、ThisDeviceOnly Keychain 密钥、1 GB LRU。
- 账号须审核；设备须激活；手机须逐设备配对。一台开发设备只信任一台手机，手机一次只操作一台设备。
- main 是唯一日常开发与发布分支；不强推、不自动删除历史分支。
- 网页管理端使用 React、React Router、Tailwind CSS v4；静态构建随业务镜像发布。
- 业务 Relay 不得挂 Docker Socket。独立更新执行器仅接收固定 Remodex 操作；正式 Release 签名与镜像 digest 是更新身份，检查不等于安装授权。
- 更新提交前允许恢复冻结时备份；提交恢复业务写入后不得自动回退旧数据库。普通历史恢复撤销旧会话和设备访问凭据。

## 实施边界

- 不读取、删除或提交 `.cc-connect/`。
- macOS 不启动 Docker。
- VPS 写操作只通过 `.agents/skills/remodex-vps-deployment`，并且只在本地、WSS、Mac/iPhone E2E 和密文边界前置验收完成后进行。
- 保留用户未提交改动，不回退或格式化无关文件。
- 修改协议、缓存或生命周期时同步更新生产者、消费者、测试和当前文档。
