---
name: cc-connect-production-browser-auth
description: 在 CC-Connect 生产控制台需要登录或登录态失效时使用；从项目内 Git 忽略的凭据文件安全读取当前账号密码并恢复浏览器会话。非生产地址、初始化管理员、重置或轮换密码时不自动使用。
---

# CC-Connect 生产浏览器认证

生产控制台认证的本机权威来源是仓库根目录下的 `.cc-connect/browser-test-credentials.json`。需要登录 `https://cc.syggu.cn` 或生产浏览器验收遇到 `/login` 时，直接使用该文件，不先向用户询问账号密码。

## 安全边界

- 先确认文件存在、权限为 `0600`，且 `git check-ignore` 证明 `.cc-connect/` 未进入 Git；任一条件不满足都明确报错并停止登录。
- 文件必须包含非空字符串 `service_url`、`username` 和 `current_password`，且 `service_url` 的 origin 必须与目标生产页一致。
- 不在 shell 输出、Node REPL 输出、工具标题、日志、截图、注释、文档或最终回复中展示账号和密码。不要读取浏览器密码库、Cookie、localStorage 或浏览器配置文件。
- 登录能力不授权部署、改密、重置账号或其他生产写操作；这些操作仍以当前用户任务为准。

## 登录方式

使用 `browser:control-in-app-browser` 控制已有的唯一生产标签页。不要新开标签页。

在持久 Node REPL 内通过 `node:fs/promises` 读取上述 JSON 到仅供当前 REPL 使用的变量，不把变量写到输出。通过页面当前可见的用户名输入框、密码输入框和登录按钮完成填写与提交，不硬编码易变化的 `node_id`，也不把凭据拼进执行标题或调试文本。

提交后同时确认：

- 页面已离开 `/login`；
- 受认证的同源 API 返回成功；
- 页面没有认证错误提示。

认证失败时保留现场并报告真实响应，不尝试 `rotated_password`、默认密码、重置、数据库修改或静默 fallback。`rotated_password` 只属于用户明确授权的改密验收流程；改密成功后按该流程原子更新凭据文件，仍保持 `0600`。
