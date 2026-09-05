# 测试预发布版与 Mac 本地开发

`0.5.0-alpha.1` 是供人工测试的预发布版，不代表账号、跨平台设备与完整发布计划已经全部验收。

- iPhone：Release 配置的未签名 IPA，需要自行签名；最低 iOS 26。
- Mac：Intel 与 Apple Silicon 分别提供 Debug DMG，包含 Node 与 Bridge。仅 ad-hoc 签名，未经 Apple 公证。DMG 包含应用程序目录快捷方式。
- Windows：Windows 11 x64 自包含中文安装／卸载包，包含 Node 与 Bridge，未做发行商签名。
- 包内保存版本和源码 SHA；发布页提供 SHA-256 清单。Debug 不表示绕过设备激活，也不表示自动热更新。

## 不装完整 Xcode 的 Mac 开发方式

本机需已安装 Apple Command Line Tools（含 Swift）、项目固定版本 Node 和 pnpm。先在仓库根目录安装依赖，再构建：

```sh
pnpm install --frozen-lockfile --ignore-scripts
bash CodexMobile/scripts/build-macos-dev.sh
```

脚本以当前工作树编译 SwiftUI Debug App，并复制当前 Bridge 和固定版本 Node。终端打印 App 路径和打开命令；先退出旧 Remodex，再打开新 App。修改 Swift 或 Bridge 后重新运行脚本。没有安装全局 Remodex CLI，没有 LaunchAgent，也不会自动启动 Bridge 或修改系统设置。

每次构建使用独立临时目录，不覆盖已运行 App；不应长期保留所有构建副本。临时目录及其体积由终端输出的位置识别，确认不再使用后由使用者清理。登录、配对仍使用本机 Keychain，不能同时运行多个版本。

## 已知边界

本次不部署或重启 VPS，不发布服务端安装脚本为已验证产品。现有旧 Relay 不能据此视作已具备新账号授权接口；新激活流程需要匹配的服务器与 GitHub OAuth 配置。

完整汉化、账号／设备缓存隔离、手机与两种桌面系统端到端操作、真实设备语音和安装体验仍需继续实现或验收。构建通过不能替代这些证据；没有相应服务器时客户端只能测试安装及可进入的本地界面。不要在验证前使用重要工作区作为测试对象。
