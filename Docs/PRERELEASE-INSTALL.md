# Remodex 测试预发布安装

本包为 alpha 测试版，不进入 VPS 正式版自动更新渠道。`remodex-prerelease.json` 仅描述测试制品，不是正式签名更新清单，不能用于网页自动安装。

- iPhone：直接下载 `Remodex-版本-unsigned.ipa`，使用自己的签名方式安装；未签名 IPA 不能直接点按安装。RDX2 配对需要本版本手机应用和配套桌面 Bridge。
- macOS：按 Intel／Apple Silicon 选择 DMG，将应用拖到“应用程序”快捷方式。本地开发仍可保留独立 Debug 包；发行包未公证，不建议关闭系统安全机制。
- Windows：使用 x64 中文安装程序。安装包未作发布者签名；卸载不删除 Codex、Git 和用户项目。
- 服务器：镜像索引 digest 与支持架构见测试清单。仅供获授权的隔离 Docker Compose 测试；已有服务器必须走项目事务部署流程，不执行首次安装脚本覆盖原目录。本次发布本身不会升级任何 VPS。

下载后核对 `SHA256SUMS` 和制品内源码 SHA。`compose.yaml` 及 `remodex.sh` 是运维参考；测试包不提供绕过正式签名校验的安装入口。

尚需用户真机验证：iPhone 秒扫、首次／可信配对、加密 RPC、离线 Whisper、Windows 安装升级卸载，以及跨设备切换。模拟器截图与单元测试不代表这些真实链路已经通过。
