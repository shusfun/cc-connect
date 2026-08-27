# Codex App workspace chat

The main Web chat and messaging platforms reach the currently running Codex Desktop App through the standard `Platform → Engine → AgentSession` path. The Desktop App is the sole owner of projects, tasks, turns, history, state, and writer lifecycle. cc-connect persists only the selected App task ID for each platform user and never copies authoritative conversation content.

## Prerequisites

- Codex Desktop App must be running on macOS with at least one routable task.
- `cc-connect-runtime` must start from the current Codex App interactive terminal. A regular Terminal, launchd, or another background process does not have the execution context required by the App tools Socket.
- Local projects use `agent.type = "codexapp"`. Linux control/server reaches the Mac through a paired `cc-connect-runtime` and never reads server-side `CODEX_HOME` state.
- `agent.type = "codex"` remains the explicit standalone Codex CLI adapter and is never a Desktop fallback.

The Runtime launcher first re-execs into the App-bundled Node supervisor. The supervisor prefers `CODEX_APP_TOOLS_PIPE_PATH`; otherwise it scans current-UID sockets under `/tmp/codex-browser-use/*.sock`. A candidate must pass `tools/list` schema validation and a `list_projects` probe. No candidate or multiple distinct active candidates is an explicit error. After closing the probe connection, the supervisor opens a fresh connection, starts the Go worker, and passes the duplex connection as fd 3. The worker never scans sockets itself.

## Current contract

cc-connect maps only audited semantic capabilities: projects, tasks, authoritative snapshots, waits, sends, creation, and schema-advertised title, pin, archive, fork, and handoff operations. Missing required tools, incompatible fields, or schema changes fail explicitly. Unknown tools are never exposed automatically. Runtime never starts `codex app-server` and never calls `thread/resume`.

The Socket transport uses four-byte little-endian length frames with an 8 MiB limit, JSON-RPC ID correlation, one writer, unique `callId`/`turnId` values, cancellation, and disconnect cleanup. When the App Socket closes, the supervisor terminates the old worker, rescans, and creates a new generation. The new worker reloads `tools/list`, computes a schema fingerprint, and atomically swaps the capability catalog. A write whose outcome became unknown after dispatch is not replayed.

## Projects, tasks, and history

Web `/chat` shows every project and task in the current App. Clicking a project expands tasks; explicit `…` buttons open accessible action menus. A new-task page keeps input only in browser state. Its first message calls App `create_thread` once and replaces the URL with `/chat/{projectId}/{taskId}` after receiving the real task ID.

On messaging platforms, `/new` creates only a local “waiting for first message” selection. The next ordinary message creates the App task through the same `AgentSession`. Follow-ups use `send_message_to_thread`, observation uses `wait_threads` cursors, and history always converges through `read_thread`. `Close` releases observation only; it does not stop the App or task.

Web sends through an in-process Management Platform into `Engine.ReceiveMessage`. WeCom, Feishu, and other platforms use the same Engine commands and session selection. There is no message interceptor, dedicated WeCom workspace transport, or parallel WorkspaceChat actor.

## Capabilities and failures

Menu operations come from the current App's dynamic `tools/list` schema and are transported through Runtime and the Management API. Unsupported operations are disabled with a reason. App offline, ambiguous sockets, incompatible required schema, and Runtime offline errors are shown directly, with no old RPC, CLI, or local fallback.

Workspace chat has no `workspace_chat.db`, SQLite drafts, settings copy, realtime/WebRTC state, or legacy REST/WebSocket protocol. When upgrading an old deployment, stop the service and remove exactly the legacy `workspace_chat.db`, `workspace_chat.db-wal`, `workspace_chat.db-shm`, and verified old temporary attachment directory. No migration or dual read is performed.
