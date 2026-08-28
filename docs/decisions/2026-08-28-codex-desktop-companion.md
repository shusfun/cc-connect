# Codex Desktop App 专用远程伴生产品

- 状态：Accepted
- 日期：2026-08-28
- 取代：通用多 Agent、多平台管理产品定位
- 继续适用：[Control、Server 与远程 Runtime 的部署所有权](./2026-08-24-control-runtime-deployment.md)、[版本、兼容与迁移所有权](./2026-08-27-versioning-and-compatibility.md)

## 问题

通用 Agent、平台和项目管理入口会把 CC-Connect 自身的桥接配置误呈现为 Codex 项目，并使 Web 同时存在全局导航与聊天导航。macOS 侧只有 Runtime 可执行文件，用户无法直接观察 Codex App supervisor、worker 代际、Control 连接和更新状态。Codex App 的项目、任务、Turn 与 writer 又不能被复制到 CLI、App Server 或另一个桌面聊天客户端。

## 决定

CC-Connect 收敛为 Codex Desktop App 的专用远程伴生产品。生产二进制只注册 `codexapp` Agent、飞书平台和管理 Web；不注册普通 Codex CLI、Lark、微信、企业微信或其他 Agent/平台，也不提供隐藏构建开关恢复这些入口。旧专用化之前的配置不迁移，加载时由未注册类型返回明确不支持错误，并要求管理员人工清理。

Codex Desktop App 独占项目、任务、Turn、结构化 item 和 writer。Control 只通过在线 Runtime 的第一方 Codex 契约读取这些对象；内部 `codex-runtime` 业务实例不是项目目录来源。禁止启动 `codex app-server`、Codex CLI fallback 或第二 writer。

保留 `Codex App 交互终端 -> Go launcher -> App 内置 Node supervisor -> Go Runtime worker` 拓扑。supervisor 继续拥有 worker 代际、App tools Socket 和重连生命周期；worker 只使用继承 FD。Wails App 是 `ActivationPolicyAccessory` 伴生控制器，只连接用户 Application Support 目录内权限 `0600` 的 `status.sock`，可读取状态或请求现有 supervisor 重连，不能连接 App tools Socket，也不能启动 supervisor、Runtime 或 Codex writer。

Web 使用唯一应用侧栏，项目来自 `list_projects`，每项目默认五个任务。Turn 以结构化 item 为边界虚拟滚动，plan 使用上游结构并默认折叠；未知 item 显式呈现为 unsupported。设置只保留设备、飞书、更新、账户、外观和系统。

macOS 伴生 App 固定使用 `github.com/wailsapp/wails/v3 v3.0.0-beta.15`，Bundle ID 为 `dev.cc-connect.desktop`。Release 产出 universal App ZIP 和 DMG，使用 Developer ID Application、hardened runtime、公证和 staple；entitlements 不允许 `get-task-allow`、JIT、unsigned executable memory 或 disable-library-validation。

## Release v2 迁移

Release 迁移所有者是 Control/Release 维护者。`v0.3.x` 是唯一迁移窗口：Control decoder 同时接受严格 v1 和 v2，writer 仍只生成原八制品 v1，使当前已发布的 v1 Control 可以安装迁移版。`v0.4.0` 起 writer 只生成 v2；v2 的每个 artifact 必须声明 `format`，并包含原八个 `tar.gz` 制品与 `desktop/darwin/universal/app-zip`、`desktop/darwin/universal/dmg`。

受管 Control 全部达到 `v0.3.x` 或更高是删除 v1 decoder 的必要信号。删除目标版本为 `v0.5.0`，不得晚于该版本继续接受 v1。删除前由部署清单核验所有受管 Control 版本；不能以运行时 fallback、能力探测或长期版本开关延长窗口。

## 后果

- `core` 保留通用接口作为依赖边界，但不包含 `codexapp` 名称分支。
- 飞书是唯一消息渠道，平台包不再注册 `lark`。
- Wails 登录启动只启动伴生 UI；Runtime 离线时明确要求从 Codex App 终端启动 launcher。
- Wails 可以验签桌面 manifest、下载并校验 DMG，再交给用户安装；Runtime 更新仍由 Control/activation 生命周期拥有。
- 旧通用产品 API、路由、UI 和生产注册不构成兼容面。

## 被否决的替代方案

- 在 Wails 中复制 Web 聊天或接管 writer：会形成第二任务权威。
- 由 Wails、launchd 或普通 Node 启动 Runtime：失去 Codex App 终端执行上下文并破坏 supervisor 所有权。
- 保留通用 Agent/平台作为隐藏 build tag：会形成未声明产品能力和长期兼容入口。
- 直接让当前 v1 Control 消费 v2 manifest：现有 decoder 会在部署事务前拒绝，无法通过 deploy-host 或重试修复。
