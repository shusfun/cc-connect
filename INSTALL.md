# CC-Connect 安装与配对

CC-Connect 只服务 Codex Desktop App。请先安装并登录 Codex Desktop App；不要安装或启动 Codex CLI/App Server 作为 fallback。

## 1. 部署 Control

从同一个 manifest Release 选择 Linux 原生或容器通道，当前未签名联调版本会以 `unverified=true` 标记，二者不得共享状态目录：

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap.sh --release-dir ./release
```

或：

```bash
gh release download <tag> --repo shusfun/cc-connect --dir release
sudo ./release/bootstrap-container.sh --release-dir ./release
```

首次启动仅监听 `127.0.0.1:9820`。通过 SSH 转发打开设置页，创建管理员、保存公开 HTTPS 地址并生成 Runtime 配对码；飞书可稍后配置。

## 2. 从 Codex App 终端安装 Runtime

在当前 Codex Desktop App 的交互终端运行设置页给出的命令：

```bash
curl -fsSL https://cc.example.com/runtime/v1/install.sh -o cc-connect-runtime-install.sh
sh cc-connect-runtime-install.sh --server https://cc.example.com --code <pairing-code> --tag <tag>
```

安装器验签并启动 `Go launcher -> Node supervisor -> Go Runtime worker`。完成后可以关闭终端；要恢复 supervisor，仍必须从 Codex App 终端运行：

```bash
"$HOME/Library/Application Support/cc-connect-runtime/current/cc-connect-runtime"
```

禁止用 Wails、launchd 或普通 Node 代启 supervisor。Runtime 私钥保存在 macOS Keychain，日志位于 `~/Library/Application Support/cc-connect-runtime/logs/runtime.log`。

## 3. 安装桌面伴生 App

从同一个 manifest v2 Release 下载 `cc-connect-desktop-darwin-universal.dmg`。验证通过后打开 DMG，将已公证的 `CC-Connect.app` 安装到 Applications。

伴生 App 提供托盘、attached 状态窗口、配对、重连、日志、更新检查、打开 Web 和可选登录启动。登录启动只启动 UI；supervisor 离线时会明确要求回到 Codex App 终端。

## 4. 配置飞书

在 Web 设置页填写中国区飞书 App ID、App Secret 和允许用户。飞书应用需启用机器人、WebSocket 长连接、`im.message.receive_v1` 事件和对应收发权限。详见 [docs/feishu.md](docs/feishu.md)。

## 5. 手工配置

正常生产初始化由 Control 原子生成配置。直接运行 server 时只接受一个内部 `codexapp` 项目和可选 `feishu` 平台：

```bash
cc-connect config-example
```

旧 Agent、Lark、微信、Provider、Cron、Bridge、Webhook 等配置不迁移；启动会返回明确不支持错误和删除提示。

完整生命周期、未验证部署与诊断说明见 [部署手册](docs/deployment.zh-CN.md)。
