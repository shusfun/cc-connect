# CC-Connect

CC-Connect is a Codex Desktop App remote companion. Codex Desktop App remains the sole owner of projects, tasks, turns, history, and writes; CC-Connect provides a remote Web workspace, optional Feishu access, a paired macOS Runtime, and a Wails 3 menu bar companion.

## Product boundary

- Agent: `codexapp` only. There is no Codex CLI, App Server, or second-writer fallback.
- Channel: Feishu only. Lark and all legacy messaging platforms are unsupported.
- Web: one Codex-style sidebar, per-project task pagination, virtualized turns, collapsible plans, and control/device/update settings.
- Runtime: the Codex App terminal launches the Go launcher, which re-execs the Node supervisor and owns Go Runtime worker generations.
- Desktop companion: Wails 3 menu bar UI for status, pairing, logs, reconnect, login startup, updates, and opening Web. It never launches the supervisor or replaces Runtime.

## Architecture

```text
Codex Desktop App -> Codex App terminal -> Go Runtime launcher
  -> Node supervisor -> Go Runtime worker (inherited fd 3)
  -> Control -> Web / Feishu

Wails companion
  -> ~/Library/Application Support/cc-connect-runtime/status.sock
```

The supervisor status Socket is current-user only and mode `0600`. The companion supports only status reads and bounded reconnect requests; it never connects to the Codex tools Socket.

## Development

Requires Go `1.25.1`, Node.js `20`, pnpm `10.32.1`, and macOS for the Wails companion.

```bash
pnpm --dir web install --frozen-lockfile
pnpm --dir web build
go test ./agent/codexapp ./runtimeprotocol ./runtimeclient ./runtimecompanion ./controlplane
go build ./cmd/cc-connect ./cmd/cc-connect-control ./cmd/cc-connect-runtime ./desktop
```

`github.com/wailsapp/wails/v3` is fixed at `v3.0.0-beta.15`.

## Documentation

- [Installation](INSTALL.md)
- [Deployment](docs/deployment.md)
- [Codex workspace contract](docs/workspace-chat.md)
- [Feishu](docs/feishu.md)
- [Codex companion ADR](docs/decisions/2026-08-28-codex-desktop-companion.md)

The embedded [configuration example](config.example.toml) is intentionally narrow. Legacy general-purpose Agent/platform configurations are rejected with an explicit cleanup error.
