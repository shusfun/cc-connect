# 飞书渠道

CC-Connect 只支持中国区飞书，不注册 Lark 别名或兼容配置。飞书只是 Codex 任务的消息入口；项目、任务、Turn 和 writer 始终由 Codex Desktop App 所有。

## 创建应用

1. 在飞书开放平台创建企业自建应用。
2. 启用机器人能力。
3. 使用 WebSocket 长连接订阅 `im.message.receive_v1`。
4. 授予机器人接收消息、读取必要用户信息和以机器人身份发送消息的权限。
5. 发布应用版本并确认可用范围。

## 配置

推荐在 Control 的 Web 设置页保存 App ID、App Secret 和允许用户。手工配置只接受：

```toml
[[projects]]
name = "codex-runtime"

[projects.agent]
type = "codexapp"

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
app_id = "${FEISHU_APP_ID}"
app_secret = "${FEISHU_APP_SECRET}"
# allow_from = "ou_xxx"
```

不要使用 `type = "lark"`。专用版本会明确拒绝 Lark 和其他平台，不做别名转换。

## 诊断

先核对飞书应用发布状态、可用范围、事件订阅和权限，再读取 server 脱敏日志中的项目、平台和关联 ID。不得记录或输出 App Secret、Token、Cookie 或消息敏感正文。
