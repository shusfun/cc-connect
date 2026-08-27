# Codex App 工作区聊天

Web 主聊天和消息平台通过 cc-connect 的标准 `Platform → Engine → AgentSession` 链路连接当前运行的 Codex Desktop App。Desktop App 是项目、任务、Turn、历史、状态和写入生命周期的唯一所有者；cc-connect 只保存平台用户当前选择的 App task ID，不复制对话正文或活动 Turn。

## 前置条件

- macOS 上的 Codex Desktop App 必须正在运行，并且至少有一个可路由任务。
- `cc-connect-runtime` 必须从当前 Codex App 的交互终端启动。普通 Terminal、launchd 和其他后台进程不具备 App tools Socket 所需的执行上下文。
- 本地运行时使用 `agent.type = "codexapp"`。Linux control/server 通过已配对的 `cc-connect-runtime` 访问用户 Mac；服务器不读取 `CODEX_HOME`。
- `agent.type = "codex"` 仍表示用户显式配置的普通 Codex CLI 项目，不能作为 Desktop App 的 fallback。

Runtime launcher 先 re-exec 为 App 内置 Node supervisor。supervisor 优先连接 App 明确传入的 `CODEX_APP_TOOLS_PIPE_PATH`，否则扫描 `/tmp/codex-browser-use/*.sock` 中当前 UID 所有的 Socket。候选必须通过 `tools/list` schema 校验和 `list_projects` 探测；没有候选或存在多个不同的活动候选都会明确失败。探测连接关闭后，supervisor 使用新连接启动 Go worker，并通过双向 FD 3 转交连接；worker 不自行扫描 Socket。

## 当前契约

cc-connect 只映射审核过的语义能力：项目列表、任务列表、权威快照、等待、发送、新建，以及 App schema 实际提供的重命名、置顶、归档、fork 和 handoff。必需工具缺失、字段不兼容或 schema 变化时返回具体错误；未知工具不会自动暴露，也不会启动 `codex app-server` 或调用 `thread/resume`。

Socket 使用 4 字节 little-endian 长度帧，单帧上限 8 MiB。Bridge 负责 JSON-RPC ID 对应、单写入所有者、唯一 `callId`/`turnId`、取消和断线清理。App Socket 关闭时 supervisor 终止旧 worker，重新扫描并创建新代际；新 worker 读取 `tools/list`、计算 schema 指纹并原子替换能力目录。已派发但结果未知的写操作不会自动重放。

## 项目、任务与历史

Web `/chat` 展示当前 App 的全部项目和任务。项目主点击只展开任务；项目和任务行的 `…` 打开可聚焦的操作卡。新建页只在浏览器保存尚未提交的输入，首条消息通过 App 的 `create_thread` 一次创建真实任务，成功后 URL 切换到 `/chat/{projectId}/{taskId}`。

消息平台的 `/new` 只创建“等待首条消息”的本地选择状态；下一条普通消息由同一个 `AgentSession` 创建真实 App 任务。已有任务的 follow-up 使用 `send_message_to_thread`，状态观察使用 `wait_threads` cursor，历史始终通过 `read_thread` 收敛。`Close` 只释放观察连接，不关闭 Desktop App，也不终止任务。

Web 通过 Management Platform 把发送请求交给 `Engine.ReceiveMessage`。企业微信、飞书及其他平台使用同一 Engine 命令和 session 选择机制，不存在消息拦截器、专用 WeCom transport 或平行 WorkspaceChat actor。

## 能力与错误

菜单能力来自当前 App 的动态 `tools/list` schema，并通过 Runtime 和 Management API 传递。缺少能力的操作会禁用并显示原因。App 离线、Socket 歧义、必需 schema 不兼容或 Runtime 离线都会直接显示真实错误，不切换到旧 RPC、CLI 或本地默认实现。

工作区聊天不使用 `workspace_chat.db`，没有 SQLite 草稿、设置副本、Realtime/WebRTC 状态或旧 REST/WS 协议。部署旧版本升级时，应在服务停止后精确删除遗留的 `workspace_chat.db`、`workspace_chat.db-wal`、`workspace_chat.db-shm` 和已核验的旧临时附件目录，不做迁移或双读。
