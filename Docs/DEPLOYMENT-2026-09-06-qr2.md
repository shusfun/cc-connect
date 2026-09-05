# 2026-09-06 RDX2 SSH 测试切换

依据本轮明确的测试切换授权实施；缺少 iPhone 真机 E2E，未标记为正式发布验收。未提交、推送或发布 GitHub Release。切换于服务器本地时间 2026-09-06 01:46 完成。

## 实际输入与运行身份

- 基线源码：`9d5c09cb1f22addd15ffb3317f22745869603b75` 加本地未提交修改，版本仍为 `0.5.0-alpha.1`。
- 构建归档：`remodex-compact-source-v3.tgz`，SHA-256 `e5589feabf7afac9d1837e196e4a5d21b81471edf71252b98ed527324c3287ba`。
- 服务器发布目录：`/opt/remodex-relay/releases/test-20260906-qr2-01`。
- Relay 本地不可变镜像 ID：`sha256:9294c082fe36c751f42643ec184da0530cd2c81d4cfbae32943369ea205dd012`。
- 更新器本地不可变镜像 ID：`sha256:55404c169590d931a8b317c71c7f0543a0c07b14211529994df17f7afa119d23`。
- 新数据卷：`remodex-control-data-test-20260906-qr2-01`。Compose 项目仍为 `remodex`。
- 均为 Linux amd64 本地测试镜像，不是签名的正式多架构发布镜像。

## 已取得证据

- 最终镜像构建内运行 React 构建与 11 项组件测试、56 项 Relay 测试、7 项更新器测试。
- 无网络、无公开端口的候选容器验证 schema 2 → 3 迁移；账号、设备、凭据、设置、浏览器会话及邀请内容摘要保持一致。真实库有 1 个账号、1 台设备和 1 份设备凭据，尚无手机授权。
- 实际执行一致性加密备份与恢复，用旧镜像打开恢复后的 schema 2 数据库并验证健康。修复了更新器在只读／受限能力环境下过早 chown 临时文件导致跨卷复制 EPERM 的问题，未给最终容器增加 FOWNER。
- 切换冻结管理写入和新授权，停止两业务容器后制作一致性加密备份；原数据卷只读保留，新卷迁移后再次校验内容摘要。提交标记写入后解除本事务维护。
- 本地及公网健康精确返回 `{"ok":true}`；Setup 防抢占、未登录管理接口、非法 preview、Push 不存在及未授权 WebSocket 拒绝通过。
- Relay 实际 UID/GID 10001、只读根、cap_drop ALL、无 Docker Socket，仍只发布 `127.0.0.1:9820`。更新器没有公网端口，保留明确的 Docker 高权限边界。
- OpenResty 两份配置摘要及 PHP、Redis、PostgreSQL、OpenResty 容器启动时间不变。
- 公网下载资源与运行容器的 SHA-256 相同：JS `index-CXRe-g3o.js` 为 `13e81f07fecdcda7abe13a98a2f0b7b81d7dfcd2b80096e04ab608e7331a4d2f`；CSS `index-BZ_uCPTo.css` 为 `952f98dcd037866594053ddd801da2c6f834dfa8f75a6f79176b371e779b4063`。浏览器实际显示新版中文登录页；没有代替用户提交生产登录或管理操作。

## 回滚点与限制

旧镜像、旧数据卷 `remodex-control-data-test-20260905-03`、发布目录下 `rollback/` 配置／容器重建信息和 `cutover/` 加密快照均保留。`switch.committed` 已存在；恢复业务写入后不得直接恢复旧数据库。未来回退须先冻结并备份当前数据，明确数据取舍。

首次执行因前置检查将 `1Panel-openresty-vUZF` 大小写写错而停止，当时没有停止容器或创建维护标记。核对运行态和配置均未变后，把该次前置记录保存在 `preflight-failed-01/`，修正名称后切换成功。没有删除同机无关资源或历史 CC-Connect 回滚点。

iPhone 新 IPA 尚未构建安装，真实授权 WSS／手机 E2E RPC、密文抓包及秒扫指标未完成；健康和未授权握手检查不代表全链路成功。正式更新签名和跨平台发行也不属于本次测试切换证据。

## 本地客户端交付

最终 Mac Debug 包已构建并打开，运行路径为 `/var/folders/06/xr1xh87x713bk5v__ytl_tc80000gn/T/remodex-macos-dev.XXQwE3/Remodex.app`。Swift 类型检查、生产配对解析器测试与真实 AppKit 窗口／Dock 生命周期测试通过。前一版紧凑码 Debug 曾实际连上 Relay 并生成 119 字节二维码。

最终包启动后的进程采样显示主线程阻塞在 `DeviceAccessService.init` 的 `SecItemCopyMatching`，日志停在 `app_opened`。尚不能声称最终包已经重新连通；未删除或改写 Keychain 来绕过系统授权。保留该运行实例供本机完成授权后复验。

Bridge 全套串行 606 项通过；移除旧短码后的受影响目标 19 项通过。独立二维码测试额外执行 1,000 次实际图案生成并比对摘要，全部一致。React 另有 3 项本地真实浏览器交互测试通过，不能代替生产账号操作验收。

本机 `xcode-select -p` 为 `/Library/Developer/CommandLineTools`，不能交付当前源码的新 iPhone IPA；需要有完整 Xcode 的环境，或在用户授权将改动集成推送 main 后由 CI 构建。Windows 尚无原生编译和真机证据。
