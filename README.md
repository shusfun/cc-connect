# Remodex

Remodex 是一套私有移动开发终端。Codex、Git、工作区与任务始终运行在 Mac；iPhone 通过端到端加密通道操作 Mac 上的 Codex；VPS 只负责设备会合、短码解析和密文转发。

```text
iPhone Remodex
    ⇅ wss://cc.syggu.cn（E2E 密文）
VPS Relay（无数据库、无模型、无聊天存储）
    ⇅
Mac Remodex.app
    ⇅ App Bundle 内置 Node + Bridge
codex app-server + Codex Desktop IPC
```

## 组件

- `CodexMobile/CodexMobile`：iOS 26 App，包含聊天、审批、结构化提问、Git、文件、图片、SSH 终端、增量缓存和离线语音转写。
- `CodexMobile/RemodexMenuBar`：原生 macOS 菜单栏 App，拥有 Bridge 子进程生命周期、配对、状态和诊断。
- `phodex-bridge`：App Bundle 内的 Node Bridge，以 `codex app-server` 为任务权威接口，并跟随 Codex Desktop IPC 实时状态。
- `relay`：无状态会合与 WebSocket Relay。只暴露 `/health`、配对/可信会话解析和 `/relay/{sessionId}`。

Mac App 不安装 LaunchAgent，不依赖全局 npm 或 `remodex` CLI。退出 App 会关闭父进程管道并终止唯一 Bridge 进程。系统睡眠后 Mac 不可达；App 不修改睡眠策略。

## 同步与缓存

Bridge 的私有同步协议包含 `sync/hello`、`sync/catalog`、`sync/thread/read`、`sync/thread/reset` 和 `sync/ack`。目录及任务 revision 单调递增，幂等 journal 保留 30 天且最多 50,000 条；revision 缺口只重建受影响任务最近 5 Turn。

iPhone 使用 GRDB/SQLite WAL 保存按 Mac、Thread、Turn、Item 拆分的派生缓存。索引使用 HMAC，正文与结构化 payload 使用 AES-GCM，密钥保存到 `ThisDeviceOnly` Keychain。默认上限为 1 GB，LRU 不自动删除置顶任务、活动任务及其最近 5 Turn。

启动时先显示本地目录和当前任务缓存，再执行增量同步。离线草稿会持久化，但离线时不能发送；重连发现任务 revision 已变化时必须由用户确认，绝不自动发送。

## 离线语音

iPhone 使用 WhisperKit `1.1.0` 和多语言 `small` 模型本地转写。录音最长 150 秒，转写结果只插入当前草稿，不自动发送。失败录音加密保留用于重试，并在成功、主动丢弃或 24 小时后删除。

## 工具链

- Node `26.6.0`
- pnpm `11.18.0`
- GRDB.swift `7.11.1`
- WhisperKit `1.1.0`
- 首个验收 Codex CLI：`0.147.0`
- 最低 iOS：iOS 26

```bash
corepack enable
corepack prepare pnpm@11.18.0 --activate
pnpm install --frozen-lockfile
pnpm --filter remodex test
pnpm --filter remodex-relay test
```

macOS/iOS 工程位于 `CodexMobile/CodexMobile.xcodeproj`。Mac target 构建时由 `CodexMobile/scripts/prepare-macos-runtime.sh` 将固定 Node 和 Bridge 复制到 App Bundle。签名 Team 只在本机 Xcode 配置，不提交账号或证书。

使用免费 Apple ID 安装到真机时，开发签名通常约 7 天到期，需要重新连接 Xcode 签名并安装。

## Relay 部署边界

生产 Relay 固定由项目 Skill `.agents/skills/remodex-vps-deployment` 管理。容器仅绑定 `127.0.0.1:9820`，以非 root、只读根文件系统和 `cap_drop: ALL` 运行，不包含 Push/APNs 路由。

切换生产前必须完成本地测试、WSS 握手、Mac/iPhone E2E 配对和密文边界验收。完整验收通过前不得删除旧 CC-Connect 服务与两个回滚目录，也不得修改同机的 1Panel、OpenResty、PostgreSQL、Redis 或其他站点。

## 隐私

Relay 可以看到连接时间、密文大小和会合所需的控制元数据，但看不到聊天正文、Mac 本地路径、密钥或 Git 内容。配对材料、Token、Cookie、私钥和原始客户端 IP 不写入 Relay 日志。

许可证见 `LICENSE`。
