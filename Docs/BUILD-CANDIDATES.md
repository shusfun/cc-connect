# 全平台候选包

候选包用于安装和诊断，不等于通过全部验收的 GitHub 预发布版。

- iOS 仍执行完整单元和 UI 测试，不忽略失败。测试执行结束后允许归档候选 IPA；即使归档成功，失败的测试仍使整个 job 失败，`publish-server.yml` 的 Release 依赖因此不能通过。
- IPA 的 `Info.plist` 写入 `RemodexIOSTestOutcome`、`RemodexSourceSHA` 和 `RemodexReleaseVersion`。测试详情保存在同一运行的 `remodex-ios-test-evidence`；不能只凭安装包存在判断测试通过。
- macOS Intel／Apple Silicon DMG 和 Windows x64 EXE 使用同一源码 SHA。DMG 保留应用程序文件夹快捷方式；不替换本机运行的 Debug 应用。
- `Build Remodex server candidate` 仅手动触发，运行服务器工作区测试后生成 Relay／Updater 的 amd64、arm64 镜像，采用 `candidate-完整源码SHA` 标签，并交付 digest 清单。它不创建 GitHub Release，不签发正式更新清单，也不部署 VPS。
- `remodex-candidate.json` 明确标记 `clientValidation: not-certified`、`automaticUpdateEligible: false`。安装参考见 `INSTALL-TEST.md`；现有生产服务不能直接覆盖。

未签名 IPA 需自行签名；Mac 未公证，Windows 未签名。iPhone 真机扫码、端到端配对、离线语音和 Windows 真机安装体验仍须实际验证。Mac 开发环境的钥匙串阻塞不属于本轮修复声明。
