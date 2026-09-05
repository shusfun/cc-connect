# iOS 本地化与预发布门禁

界面支持 `en`、`zh-Hans` 和跟随系统。非简体中文系统语言回退英文；用户选择保存在独立 `remodex.language` 偏好中。SwiftUI 根环境更新 locale，不使用 `.id(language)` 重建 CodexService；普通字符串展示使用 `L10n`，UIKit 菜单重新打开时重建，跨 UIHostingController 显式传递 locale。

`Localizable.xcstrings` 是文案来源，`InfoPlist.xcstrings` 管理五项系统权限说明。新增可见文案必须登记双语；用户消息、代码、命令、路径、设备备注和服务端结构化问题内容不作为界面词条翻译。不可用对任意字符串做搜索替换的方式汉化。

数量文案使用完整句式；文件数与工具调用数由 String Catalog 的复数规则处理。日期和相对时间使用当前应用语言的 Locale。服务端授权错误按稳定错误码映射，仅附加经过 UUID 校验的诊断编号，不展示原始响应正文。

本地检查：`node CodexMobile/scripts/check-localization.cjs` 校验双语完整性、占位符及自有 UI 字面量入口。该检查不等于逐屏显示验收。

GitHub iOS 工作流执行整个 scheme 的单元／UI 测试后才归档，上传 `.xcresult` 和截图证据。语言 UI 测试使用实际页面和明确的 DEBUG 测试入口，禁止连接真实 Relay、审批或下载模型；生产 Release 不包含测试入口。历史 timeline 性能测试的启动参数也已接到真实 TurnView 测试数据。

即时同步回归使用当前 `sync/catalog`、`sync/thread/read` 契约，不再模拟已退出的两次 `thread/list` 全量读取。连续切换合并为一次目录增量读取，只同步最后选中的任务；目录请求过程中再次切换须跳过旧任务。服务持有合并任务并在停止时取消，旧任务完成不得清除替代任务；测试覆盖以上行为，不恢复旧协议来迎合旧夹具。

归档后 `verify-ios-localization.cjs` 校验编译后的两种语言、权限资源、版本、构建号和源码 SHA。真机首次配对、秒扫、离线转写及 Windows 安装验收独立记录，不用模拟器或构建成功代替。

本轮目标版本为 `0.5.0-alpha.2`、iOS 构建号 `131`。仅在远端所有要求平台的构建和语言测试通过后创建预发布；失败不得标记汉化／发行完整通过。正式自动更新继续拒绝 alpha。
