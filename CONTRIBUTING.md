# Remodex 开发说明

## 环境

- macOS 与完整 Xcode（支持 iOS 26 SDK）
- Node `26.6.0`
- pnpm `11.18.0`
- 已登录且版本不低于 `0.147.0` 的 Codex

## 本地验证

```bash
corepack enable
corepack prepare pnpm@11.18.0 --activate
pnpm install --frozen-lockfile
pnpm --filter remodex test
pnpm --filter remodex-relay test
```

使用 `CodexMobile/CodexMobile.xcodeproj` 构建 iPhone 与 Mac target。Mac App 在构建时打包 Node 和 Bridge，并直接拥有 helper 生命周期；不要安装全局 `remodex` CLI 或 LaunchAgent。

## 变更要求

- 协议、缓存、生命周期改动必须同时覆盖生产者、消费者和测试。
- 不新增旧协议 fallback、Push/APNs、托管后台或 VPS 模型执行。
- Relay 日志不得包含原始 sessionId、客户端 IP、Token、Cookie、密钥、路径或聊天正文。
- UI 变更需覆盖 Dynamic Type、VoiceOver、减少动态效果和至少 44pt 点击区域。
- 完整发布验收包括 Relay/Bridge 全测、Xcode 单元/UI 测试、iOS 26 真机离线语音、WSS E2E 配对和密文边界检查。

生产切换只通过 `.agents/skills/remodex-vps-deployment`，且前置验收不完整时不得执行。
