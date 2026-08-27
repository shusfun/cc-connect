# Web 控制面部署

## 权威来源

Release workflow 及其签名 manifest 是构建契约，选定的 GitHub Release 是制品来源，服务和部署的实时状态是运行事实。仓库示例与历史日志仅用于指引。安装、更新、回滚或诊断前，必须核验 `<tag>`、commit、目标架构、manifest identity 和当前服务状态。

正式 Release 包含 Linux amd64/arm64 的 control、server、deploy-host，以及 macOS amd64/arm64 的 Runtime。安装与更新验证 GitHub OIDC/Sigstore identity 和每个 SHA-256，拒绝未签名制品。

Linux 有两条相互独立的通道：原生安装由 systemd 管理 control；容器安装由 systemd 只管理 deploy-host，deploy-host 管理 control 容器，control 仍是 server 的唯一生命周期所有者。两条通道不得共用持久目录。macOS Runtime 不容器化，也不通过 launchd 直连 App 私有 Socket。

## Docker deploy-host 通道

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap-container.sh --release-dir ./release
```

bootstrap 只安装 `cc-connect-deploy-host.service`。宿主执行器固定操作仓库 `shusfun/cc-connect`、镜像 `ghcr.io/shusfun/cc-connect`、Compose 项目 `cc-connect` 和 service `cc-connect`。制品内的 `compose.yaml` 是执行器输入，不是绕过执行器的独立生产入口。

容器默认只映射 `127.0.0.1:9820`，以 UID/GID 10001 和只读根文件系统运行，状态分别保存在 `/var/lib/cc-connect-docker/control` 与 `/var/lib/cc-connect-docker/app`。control 不挂载 Docker Socket，只通过受限 Unix Socket 请求 deploy-host。Web 更新与回滚的业务事务由 control 所有，deploy-host 只负责容器替换和上一签名 digest 的看门狗恢复。

## 原生 systemd 通道

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap.sh --release-dir ./release
```

bootstrap 创建 `/opt/cc-connect/releases` 版本槽、`/var/lib/cc-connect/control` 控制状态、`/var/lib/cc-connect/app` 应用状态和 `/run/cc-connect` 私有 Socket。systemd 只管理 control，server 由 control 独占监管。

## 初始化与 Runtime 配对

首次启动只监听 `127.0.0.1:9820`，一次性设置 Token 出现在对应通道的服务日志中。通过 SSH 转发完成 Web 初始化：创建管理员、保存公开 HTTPS 地址、配对 Runtime、验证 Codex 与至少一个项目、按需配置企业微信，再原子生成配置并启动 server。公开 HTTPS 使用 Release 内的 `openresty-1panel.conf`。

在当前 Codex Desktop App 的交互终端运行设置页生成的 Runtime 安装命令，等价于：

```bash
curl -fsSL https://cc.example.com/runtime/v1/install.sh -o cc-connect-runtime-install.sh
sh cc-connect-runtime-install.sh --server https://cc.example.com --code <pairing-code> --tag <tag>
```

安装器验签、安装并配对后，会在同一 App 终端以前台进程启动 Runtime；关闭该终端会使设备离线。旧 `dev.cc-connect.runtime` LaunchAgent 会被停止并精确删除。已安装 Runtime 可从 App 终端重新启动：

```bash
"$HOME/Library/Application Support/cc-connect-runtime/current/cc-connect-runtime"
```

Runtime 私钥只保存在 macOS Keychain。launcher re-exec 为 App 内置 Node supervisor，再将已校验的 App Socket 通过继承 FD 交给 Go worker。Runtime 通过出站 TLS/WebSocket 连接 control；catalog 同步只传不透明项目元数据，不上传对话正文。Runtime 不启动第二个 Codex App Server。

## 更新、回滚与诊断

更新与回滚从 Web 发起。control 检查活动操作、备份 `control.db`、协调 Runtime 激活，并与重启共用一个执行槽。原生通道切换签名 Release 槽并由 systemd 恢复；容器通道请求 deploy-host 切换已验证 digest，并使用独立持久化 activation 状态。不得手工修改 release 链接、activation、deployer 状态或数据库备份。

诊断从真实症状、UTC 时间窗口、目标 tag/commit 和实时运行状态开始，只选择能区分当前假设的信号；下列日志与状态入口是候选证据，不是固定逐项清单：

- 原生通道：Web 运维状态、`systemctl status cc-connect-control.service`、`journalctl -u cc-connect-control.service`。
- 容器通道：Web 运维状态、`systemctl status cc-connect-deploy-host.service`、deploy-host journal，以及与目标镜像 digest 对应的只读容器状态和日志。
- Runtime：设备连接历史、Runtime launchd 状态与日志，以及 control 侧关联的 run/request ID。

取消或重试前，重新读取当前 run 状态，并取得日志新鲜度、健康状态、执行槽或候选 revision 中的一项独立信号。自动恢复失败时保留 activation 和 backup 现场。
