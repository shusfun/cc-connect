# Codex Desktop App 任务所有权与统一聊天链路

- 状态：Accepted
- 日期：2026-08-23
- 最后核验：2026-08-28，当前 Codex Desktop App tools schema 与真实活动任务
- 适用边界：Web 主聊天、消息平台、`codexapp` Agent、macOS Runtime 与 Desktop App 任务生命周期
- 失效条件：Codex App 提供公开稳定且具有等价所有权语义的 Remote/Socket API，或新的 Accepted ADR 明确替换本文

本文记录 `v0.1.0` 当前唯一协议。版本、协议和持久化判断同时遵循[版本、兼容与迁移所有权](./2026-08-27-versioning-and-compatibility.md)。

## 问题

旧工作区聊天自行启动 `codex app-server`，再通过 `thread/resume` 读取 Desktop App 已打开的任务。这会为同一 task 建立第二个 writer，并产生 `already has an active writer`。独立 `WorkspaceChatService`、草稿 SQLite、消息拦截器和企业微信专用 transport 还绕过了 `Platform → Engine → AgentSession` 主链，形成两套任务、历史和关闭语义。

Codex App 的第三方 tools Socket 没有公开稳定 API。当前 App 还会校验连接来自 App 内置 Node 和当前 App 交互终端；普通后台进程、Go 直连、自建 PTY或由 Go 派生的 Node 都会被拒绝。cc-connect 不能用第二个 App Server 或 CLI fallback 掩盖这一边界。

## 决定

Codex Desktop App 是项目、任务、Turn、历史、状态和 writer 生命周期的唯一所有者。`agent/codexapp` 实现通用 `core.Agent` 与可选项目、任务、历史和元数据能力；cc-connect 只做代理和平台适配。`agent/codex` 仅服务用户显式配置的普通 CLI 项目，不能成为 Desktop 链路 fallback。

Web、企业微信及其他平台统一进入 `Platform → Engine → AgentSession`。SessionManager 只保存平台用户当前选择的 App task ID 和“等待首条消息”状态，不复制权威历史、Turn 或交互状态。Web 发送同样经 Management Platform 进入 `Engine.ReceiveMessage`，不存在平行 WorkspaceChat actor、消息拦截器或平台专用聊天 transport。

Runtime launcher 必须从当前 Codex App 交互终端启动。launcher 通过 `syscall.Exec` 替换为 App 内置 Node supervisor；supervisor 选择当前 UID 的唯一活动 tools Socket，完成 `tools/list` 与 `list_projects` 只读探测，再启动 Go Runtime worker，并通过双向 FD 3 转交连接。worker 不再次扫描 Socket。Socket 断开时 supervisor 终止旧 worker、重新扫描并建立新代际。

Bridge 使用 4 字节 little-endian 长度帧，单帧上限 8 MiB，负责 JSON-RPC ID 对应、单写入、取消和断线清理。每次 `tools/call` 使用进程无关的唯一 `callId` 与 `turnId`。App 重启后重新读取 `tools/list`、计算 schema 指纹并原子替换能力目录。结果未知的写操作不自动重放。

必需能力为 `list_projects`、`list_threads`、`read_thread`、`wait_threads`、`send_message_to_thread` 和 `create_thread`。重命名、置顶、归档、fork 与 handoff 只有在当前 schema 兼容时才暴露。未知工具不自动开放；必需字段缺失或 schema 不兼容时返回具体错误。Runtime 不启动 `codex app-server`，也不调用 `thread/resume`。

Web 新建页只保存浏览器内临时输入；首条消息一次调用 `create_thread` 并携带 prompt，成功后使用真实 task ID。消息平台裸 `/new` 进入等待首条消息状态。已有任务 follow-up 使用 `send_message_to_thread`，观察使用 `wait_threads` cursor，历史始终通过 `read_thread` 权威快照收敛。`AgentSession.Close` 只释放观察，不关闭 App、不终止任务。

## 被考虑的替代方案

- 保留旧 WorkspaceChat 路由并新增 Desktop 路由：会形成两套生产者、消费者和 writer，项目处于 `v0.1.0`，因此直接替换。
- 后台 Runtime 直接扫描并连接 Socket：当前 App 会拒绝非 App 顶层执行上下文，已由真实 Socket 验证，不构成可用部署拓扑。
- 自启 App Server 后 `thread/resume`：会争抢 App 已持有的 writer，正是本次用户故障的根因。
- 使用普通 Codex CLI 作为 fallback：会得到不同的任务目录、历史和写入所有者，不能伪装成当前 App。
- 将历史或草稿写入 SQLite：会形成双权威；新建任务由 App 的 `create_thread` 原子创建，不需要本地草稿数据库。

## 兼容与清理

旧 `WorkspaceChatService`、`storage/workspacechat`、NativeConversation、App Server RPC、独立 REST/WS、消息拦截器、企业微信专线、配置字段、测试和文档在同一变更中删除，不提供别名、双读、双写或版本开关。

`workspace_chat.db` 不再属于当前系统。升级旧部署时先停止服务，再精确删除 `workspace_chat.db`、`workspace_chat.db-wal`、`workspace_chat.db-shm` 和已核验的旧临时附件目录；不迁移、不自动重建，也不读取旧结构。

## 生命周期与风险

同一 task 的发送、等待和关闭由一个 `AgentSession` 协调；App 保持唯一 writer。断线会取消旧等待，supervisor 重建连接代际后由 `read_thread` 权威快照收敛。发送结果不确定时不自动重发。能力目录只在完整 schema 校验后原子发布。

主要风险是 App 私有身份校验变化、Socket 多候选歧义、schema 漂移、重复调用 ID、App 重启、非幂等写入结果未知，以及 Web 与消息平台选择关系漂移。验证必须从真实 App 入口证明相同 task ID 与内容、无 active writer 错误、无新增 App Server 进程，并覆盖分帧、粘包、超限、取消、错误 ID、重连和能力热切换。
