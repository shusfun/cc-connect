# Remodex 项目约束

本仓库是私有移动开发终端，不是托管 Codex 服务。

## 架构边界

- Codex、Git、工作区、任务与模型只在 Mac 运行。
- VPS Relay 只做会合、短码/可信会话解析和 E2E 密文转发；不得加入数据库、聊天存储、模型、后台或 Push/APNs。
- Mac 原生 App 是 Bridge 生命周期唯一所有者。不得恢复全局 npm/remodex CLI、LaunchAgent 或登录 shell 依赖。
- iPhone 只消费私有同步协议与本地派生缓存；能力不兼容时明确要求更新，不增加旧协议 fallback。
- 不把 Mac 本地路径、密钥、Token、Cookie、聊天正文、会话标识或原始客户端 IP 暴露给 Relay 日志。

## 当前契约

- Node `26.6.0`、pnpm `11.18.0`，根 workspace 单一锁文件。
- GRDB.swift `7.11.1`、WhisperKit `1.1.0`、iOS 26。
- 首个支持的 Codex CLI 为 `0.147.0`。
- 同步 RPC：`sync/hello`、`sync/catalog`、`sync/thread/read`、`sync/thread/reset`、`sync/ack`。
- 缓存按 Mac 隔离，HMAC 索引、AES-GCM 正文、ThisDeviceOnly Keychain 密钥、1 GB LRU。

## 实施边界

- 不读取、删除或提交 `.cc-connect/`。
- macOS 不启动 Docker。
- VPS 写操作只通过 `.agents/skills/remodex-vps-deployment`，并且只在本地、WSS、Mac/iPhone E2E 和密文边界前置验收完成后进行。
- 保留用户未提交改动，不回退或格式化无关文件。
- 修改协议、缓存或生命周期时同步更新生产者、消费者、测试和当前文档。
