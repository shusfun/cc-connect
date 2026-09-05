# 激活反馈、后台组件与 Mac 窗口

## 配套升级边界

本次源码将管理数据库升级到 schema 3，为旧审计记录新增可空的 `diagnostic` 字段；旧账号、会话和设备不清空，旧审计不补造诊断信息。迁移在事务中执行，不支持旧程序直接读取新版 schema。

激活申请创建和状态查询返回 `expiresAt`、`serverTime`。Mac 以服务端时间计算等待期限，因此新 Mac 发起激活需要配套的新后台；已有本地凭据不会因本次改造被主动清除。本地构建不代表 VPS 已升级，生产替换须另按部署 Skill 执行。

## 激活提交与权威状态

- 网页通过 React Router 的 replace 导航清理激活参数并进入设备页，不再只修改浏览器地址栏。
- 已批准、已兑换的终态查询不受邀请兑换期限限制，但只向所属账号开放；已撤销设备不能显示为激活成功。
- 网络超时、响应丢失或已消费冲突先查询权威状态，不重复批准，也不将其他账号占用视为成功。
- 组件卸载、切换申请及注销使旧请求失效。完成过的申请不会因旧 URL 再次出现批准按钮。
- Mac 只有在 Keychain 保存成功后才发布已激活状态；保存失败、取消、超时均有独立反馈。

## 诊断与隐私

管理请求返回随机 `x-remodex-request-id`；客户端可携带随机 UUID `x-remodex-operation-id` 关联本次操作。服务端只记录白名单接口名称、阶段、HTTP 状态、稳定错误码、耗时和结果。正常等待不逐次写日志。

诊断字段可在审计详情和 Mac 复制诊断中查看。不记录请求正文、令牌、Cookie、密钥、公钥原文、激活申请 ID、二维码、工作区路径或原始 IP。Mac 日志写入失败时，最近阶段仍保存在内存并在界面提示诊断不可用。

## 后台组件

后台使用 shadcn/ui new-york 的 Radix 组件、Lucide SVG 图标和 Tailwind v4，依赖固定在根 workspace 锁文件。组件许可见 `apps/control/SHADCN-LICENSE.md`。

布局、页面、激活流程和共享组件分别维护。危险操作使用确认弹窗，详情使用具备焦点约束与恢复的 Dialog；操作错误持续显示，成功提示不替代错误反馈。窄屏表格在自己的容器内横向滚动。

CSP 的脚本来源仍仅允许本站；每次 HTML 响应为 Radix 注入的样式元素生成 nonce，动态定位的 style 属性单独放行，不放行内联脚本。

## Mac 窗口与图标

`WindowCoordinator` 拥有唯一管理窗口。显示前切换 `.regular`；真正关闭后切换 `.accessory`。最小化不视为关闭，关窗不停止 Bridge；退出程序才停止本 App 的子进程。菜单栏与 Finder 再次唤起复用窗口。

手动启动显示窗口；登录启动且已激活时仅显示菜单栏。激活未完成或启动失败时显示窗口。图标由现有品牌素材生成 `.icns`，Debug 与正式打包共用 `prepare-macos-runtime.sh` 的生成入口。

## 验证入口与证据范围

```sh
pnpm --filter @remodex/control build
pnpm --filter @remodex/control test
REMODEX_TEST_BROWSER_CHANNEL=chrome pnpm --filter @remodex/control test:e2e
node --test relay/*.test.js packages/updater/*.test.js
swiftc -swift-version 5 -parse-as-library CodexMobile/RemodexMenuBar/ActivationPolicy.swift CodexMobile/RemodexMenuBar/WindowCoordinator.swift CodexMobile/scripts/test-macos-feedback.swift -o /tmp/remodex-feedback-tests
/tmp/remodex-feedback-tests --window
```

浏览器测试使用隔离的本地 HTTPS 服务和测试账号，不连接生产。`--window` 在真实 AppKit 中验证窗口复用、最小化、关闭与 Dock 策略；不读取 Keychain、不启动 Bridge。

本轮取得 Relay／更新器 61 项、React 组件 11 项、浏览器 3 项测试通过，以及 Mac 类型检查、AppKit 生命周期和 Debug 包签名校验证据。AppKit 测试不是完整应用的 Finder／菜单栏人工验收，也不是生产激活或 Mac／iPhone E2E 验收；Linux Docker、Windows 和 iPhone 真机未在本轮验证。
