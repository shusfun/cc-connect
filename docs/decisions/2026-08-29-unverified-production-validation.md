# 未验证制品线上联调

- 状态：Accepted
- 日期：2026-08-29
- 适用范围：`v0.4.0-rc.*-unverified` 联调版本
- 继续适用：[Control、Server 与远程 Runtime 的部署所有权](./2026-08-24-control-runtime-deployment.md)

## 决定

当前线上联调允许没有 `manifest.bundle` 的 Release，所有安装、更新和桌面下载结果必须明确标记 `unverified=true`。该模式不调用 cosign，也不把未签名制品描述为正式签名 Release。

跳过签名不等于跳过身份和完整性校验。Release 必须仍满足固定仓库 `shusfun/cc-connect`、固定 workflow `.github/workflows/release.yml`、合法 tag、manifest schema、commit 元数据、每个 artifact 的大小与 SHA-256、固定 GHCR 仓库 digest，以及 candidate Control、Runtime reconnect 和服务健康检查。失败时由现有 activation/rollback 所有者收口，不自动重放非幂等操作。

未验证版本使用 prerelease tag，不覆盖 latest。Apple Developer ID、公证、staple、Sigstore bundle 和 image signature 不属于本联调验收范围；正式发布前必须另行恢复并验证签名门禁。

## 迁移边界

已发布的旧 Control/deploy-host 若仍在下载阶段强制请求 `manifest.bundle`，不能消费未验证 Release。必须先通过现有受信任的宿主升级路径部署支持无 bundle 的迁移版本，或由部署所有者执行等价的受控替换；未取得该路径时，不得宣称线上部署完成，也不得通过伪造 bundle、覆盖旧 tag 或关闭健康检查绕过阻塞。

## 证据

本次 `v0.4.0-rc.4-unverified` 的 GitHub Actions run `33244573127` 已完成 Linux、macOS unsigned Desktop 和多架构 GHCR 构建，publish 成功。对 `cc.syggu.cn` 显式发起的 run `T6SXeygAazL8ibPEzd-g-TaO` 在旧 v0.3.0 Control 下载 `manifest.bundle` 时收到 404，服务保持 v0.3.0 运行，未发生 candidate commit。
