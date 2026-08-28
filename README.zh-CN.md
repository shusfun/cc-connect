# CC-Connect

CC-Connect 是 Codex Desktop App 的专用远程伴生产品。Codex Desktop App 独占项目、任务、Turn、历史和写入；CC-Connect 提供远程 Web 工作区、可选飞书渠道、配对的 macOS Runtime，以及 Wails 3 菜单栏伴生 App。

## 产品边界

- Agent：只支持 `codexapp`，不存在 Codex CLI、App Server 或第二 writer fallback。
- 渠道：只支持中国区飞书，不支持 Lark 和其他旧消息平台。
- Web：唯一 Codex 风格侧栏、按项目分页任务、Turn 虚拟滚动、计划折叠，以及设备/更新/账户设置。
- Runtime：必须从 Codex App 终端启动 Go launcher；launcher re-exec 为 Node supervisor，由 supervisor 管理 Go Runtime worker 代际。
- 桌面伴生：Wails 3 菜单栏 UI 负责状态、配对、日志、重连、登录启动、更新检查和打开 Web；它不启动 supervisor，也不替换 Runtime。

## 架构

```text
Codex Desktop App -> Codex App 终端 -> Go Runtime launcher
  -> Node supervisor -> Go Runtime worker（继承 fd 3）
  -> Control -> Web / 飞书

Wails 伴生 App
  -> ~/Library/Application Support/cc-connect-runtime/status.sock
```

supervisor 状态 Socket 仅当前用户可访问，权限为 `0600`。伴生 App 只读取状态并请求受限重连，不连接 Codex tools Socket。

## 开发

需要 Go `1.25.1`、Node.js `20`、pnpm `10.32.1`；Wails 伴生 App 需要 macOS。

```bash
pnpm --dir web install --frozen-lockfile
pnpm --dir web build
go test ./agent/codexapp ./runtimeprotocol ./runtimeclient ./runtimecompanion ./controlplane
go build ./cmd/cc-connect ./cmd/cc-connect-control ./cmd/cc-connect-runtime ./desktop
```

`github.com/wailsapp/wails/v3` 固定为 `v3.0.0-beta.15`。

## 文档

- [安装说明](INSTALL.md)
- [部署手册](docs/deployment.zh-CN.md)
- [Codex 工作区契约](docs/workspace-chat.zh-CN.md)
- [飞书配置](docs/feishu.md)
- [Codex 伴生架构决定](docs/decisions/2026-08-28-codex-desktop-companion.md)

内嵌的 [配置示例](config.example.toml) 有意保持精简。旧通用 Agent/平台配置会返回明确的人工清理错误，不自动迁移。
