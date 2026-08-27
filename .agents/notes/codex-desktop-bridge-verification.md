# Codex Desktop Bridge 连接验证经验

## 适用指纹

适用于以下任一信号：

- App tools Socket 立即 EOF 或显示 `Codex app tools pipe closed`。
- Runtime 断线后反复报告 `socket closed during probe`，但 App 自带的 `list_projects` 仍可用。
- 读取当前 Desktop task 时出现 `already has an active writer`。
- Runtime 能读取 `tools/list`，但 `tools/call` 返回 `Codex app tool request failed`。
- 需要判断 Runtime 是否意外启动了第二个 `codex app-server`。

普通 Codex CLI 项目、公开 Codex Remote API 和与 Desktop tools Socket 无关的 Agent 故障不使用本 Note。

## 前提

- Codex Desktop App 正在运行，当前操作来自 App 内交互终端。
- App 提供 `CODEX_APP_TOOLS_PIPE_PATH` 和 `CODEX_THREAD_ID`。
- 使用 App bundle 内的 Node，例如 `/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node`；路径和 App 名称必须按当前安装实时核验。
- `tools/list` schema、Socket 路径和活动 task ID 都是时效性事实，不能从旧日志推断。

## 已验证路径

1. 顶层 `cc-connect-runtime` 必须从当前 App 交互终端启动。
2. launcher 使用 `syscall.Exec` 替换为 App 内置 Node supervisor，保留 App 顶层执行上下文。
3. supervisor 对候选 Socket 使用数字 JSON-RPC ID 依次执行 `tools/list` 和 `list_projects`；唯一候选校验成功后必须把同一连接移交 worker。不能关闭探测连接后再建立业务连接，当前 App 会关闭尚未及时发送首个请求的新连接；多个候选均成功时关闭全部已探测连接并明确报歧义。当前 App 主机对字符串探针 ID 会直接关闭新连接。
4. supervisor 启动 Go Runtime worker，并通过双向 FD 3 转交已验证连接；worker 不自行扫描或直连 Socket。
5. 每次 `tools/call` 都生成新的 `callId` 和 `turnId`。固定 ID 即使上一进程已经退出，也可能被 App 拒绝。
6. Socket 关闭时 supervisor 终止旧 worker、重新扫描并建立新代际；新 worker 从 `read_thread` 权威快照收敛。

该路径只观察和代理 App tools，不启动 `codex app-server`，不调用 `thread/resume`，也不取得 task writer 所有权。

## 已证实的低收益路径

- 普通 pipe 或后台进程运行 App 官方 `server.mjs`：App 关闭 tools pipe。
- 自建 PTY：拥有 TTY 不等于拥有 App 顶层执行上下文。
- Go 进程直接连接 tools Socket：App 拒绝连接。
- Go 进程派生 App 内置 Node：子进程仍缺少顶层 App 终端身份。
- launchd 常驻 Runtime 直接扫描 Socket：执行上下文不匹配，不能作为部署入口。
- 自启 Codex App Server 再 `thread/resume`：会与 Desktop App 的活动 writer 冲突。
- 重用固定 `callId` 或 `turnId`：首次可能成功，后续业务调用会被拒绝。
- 用字符串作为 App tools Socket 的 JSON-RPC 请求 ID：App 自带客户端和真实 Socket 都使用数字 ID；字符串探针会在响应前被关闭。

## 成功、失败与停止信号

- 成功：真实 App 集成可列出项目和任务，并通过 `read_thread` 读取当前 `CODEX_THREAD_ID`；App Server 进程表与操作前基线一致。
- 连接失败：保留 `tools/list`、`list_projects` 或业务调用阶段的脱敏错误，不切换到 CLI/App Server fallback。
- 多个活动 Socket：明确报告歧义，停止猜测前台 App。
- schema 缺失必需工具或字段：明确能力错误，停止调用未知工具。
- 非幂等写入断线：报告结果未知，不自动重放。

## 失效条件

Codex App 发布公开稳定的等价 Remote/Socket API、tools Socket 身份校验变化、App bundle Node 拓扑变化，或 `tools/list` schema 改变时，必须回到真实 App 入口重新核验。未经复验不得把旧路径包装为 fallback。

## 最后核验

2026-08-28，在真实 App Socket 和活动 task 上验证：字符串探针 ID 会在响应前断开，数字 ID 可返回 27 项工具；`tools/list` 与 `list_projects` 成功后复用同一 Socket 可启动 worker，丢弃已验证连接后再建立空业务连接会在 worker 接管前被 App 关闭。顶层 App Node supervisor、worker FD 3、唯一调用 ID 可完成项目、任务和历史只读集成，且未新增 `codex app-server` 进程。
