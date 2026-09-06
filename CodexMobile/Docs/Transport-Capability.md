# SSE / WebRTC 迁移能力门禁

## 当前交付状态

本文件记录 2026-09-06 的代码边界，不是发布完成声明。生产传输入口尚未切换：当前安装的 App 没有被替换或重启，Relay 未部署新入口，iOS 仍使用既有承载。旧路径保留是因为迁移能力门禁尚未通过，不是新协议的运行时 fallback。

| 范围 | 当前状态 |
| --- | --- |
| Mac 原生进程控制 | 已接入异步控制命令、串行操作队列、意图/世代隔离、有限恢复策略；状态文件读取和诊断落盘移到后台；尚未完成真实窗口故障注入验收 |
| Node Bridge 启动 | 已接入可取消退避、启动心跳、终止错误阻断和控制命令进程组回收 |
| Relay SSE / 信令 | 已实现候选控制器和 HTTP 适配器，有真实 SQLite、签名鉴权、SSE 测试；尚未接入 `production-access.js` 和管理事务提交钩子 |
| Apple 共享传输 | 已实现并构建独立能力包：签名 HTTP、成熟 SSE 客户端适配、WebRTC DataChannel、有界分片、背压和连续单调时钟租约；尚未接入两个 App 的业务消费者 |
| 原生 Transport Helper / 本机认证 WS | 尚未实现和嵌入；原生能力探针不是产品 Helper |
| `sync/watch` / `sync/events` | 尚未迁移；现有五个同步 RPC、App 日常网络轮询仍保留 |
| coturn / 发布支持矩阵 | 尚未新增生产 Compose 服务或修改发布资产；不能把当前 Windows 包称为新传输兼容客户端 |

## 固定依赖与所有权

- `CodexMobile/Package.swift` 是候选 Apple 传输包的依赖定义；`Package.resolved` 固定 swift-eventsource `3.3.0` 的提交。WebRTC `152.0.0` 使用二进制目标和 SHA-256 校验和，不引入 Node 原生绑定。
- WebRTC ZIP 校验和：`115cb9944248a3302c0c8af17462e2576a28ccc7adef9f6a1fe66ee75d9e1cc8`。
- `relay/package.json` 与根 `pnpm-lock.yaml` 固定 better-sse `0.16.1`。Node `26.6.0`、pnpm `11.18.0` 不变。
- WebRTC 使用发行物附带的 BSD 许可证；swift-eventsource 为 Apache-2.0；better-sse 为 MIT。正式打包仍须收集依赖及传递依赖许可、嵌入并签名 Framework 和 Helper。独立 Swift 包构建不等于这项打包工作完成。
- SwiftUI 主进程目前只新增纯 Foundation 的策略和异步进程代码；没有加载 WebRTC 或 SSE SDK。后续由 App 拥有 Bridge，再由 Bridge 拥有原生 Helper。

## 实现约束

- `relay/transport-control.js` 只在内存保留连接和信令；必须由最终 HTTP 服务所有者每 20 秒调用 `tick()`，在管理数据成功提交后调用 `changed()`，关闭服务时调用 `close()`。尚未完成这些生产接线，不得直接把候选模块视为线上有效授权门禁。
- `relay/transport-http.js` 仅处理新设备接口。流有保活、认证、请求签名、防重放、慢消费者限制和设备范围快照。接线时必须替换旧 session 在线索引，并明确拒绝旧业务 WS 客户端，不能同时开放两个业务承载来掩盖迁移缺口。
- `AccessEventStream` 使用 swift-eventsource 解析 SSE，每轮重连重新签名并重新取得快照。外围 Foundation HTTP 适配器拒绝重定向、禁用持久缓存/Cookie、限制事件大小，保留脱敏错误码并尊重 `Retry-After`。它不实现另一套 SSE 解析器。
- `PeerDataChannel` 把所有 SDK 回调异步转回自身串行队列。不得在 SDK signaling 回调里同步调用另一 peer；能力验证曾捕获这种互等，修正后才通过互通测试。
- DataChannel 可靠、有序；wire 分片默认最多 16 KiB，并取远端 SDP 允许值的较小值。完整消息最多 16 MiB，发送准入在入队前限额，重组与排队均有超时；关闭会取消待发消息。完成回调只表示本地 SDK 接受了发送，不等于业务执行成功，禁止据此自动重放命令。
- 授权使用包含休眠时间的 `ContinuousClock`，基于请求开始时间保守计算期限；重放的 sequence 不续租。最终 Bridge 的逐 RPC 租约/身份/世代检查仍待 Helper 接线，不能以策略单测代替实际业务门禁。
- 协商 API 不记录 SDP、ICE、凭据或正文。UI 路径必须使用实际选中 candidate pair；配置了 TURN 不等于正在中继。

## 可复现验证

在仓库根运行：

```sh
bash CodexMobile/scripts/test-transport-capability.sh
pnpm --filter remodex --filter remodex-relay test
```

能力脚本只创建本任务临时目录和回环服务，不读用户设备凭据、不写生产、不开 Docker、不启动已安装 App。依赖下载由 SwiftPM 核验固定摘要；不读取 macOS Keychain/netrc 中的下载凭据。保留临时证据目录供定位失败，不自动删除用户文件。

脚本验证：

1. 独立 Swift 包真实构建，包含固定版本原生 SDK。
2. 租约过期/重放/延迟、恢复额度、分片上限、重组超时、内存准入。
3. 真实 SDK 双向 DataChannel、16 MiB 消息和实际选中直连路径。
4. 两个原生 peer 经真实签名 SSE 和回环 HTTP 协商，承载原有 Bridge E2E 握手与真实 `sync/hello` 协调器；SSE 重新签名订阅、授权撤销关闭。
5. HTTP 重定向拒绝、错误 MIME、大响应/大事件、HTTP-date 与秒数 `Retry-After`、取消清理。
6. 默认 100 轮 SDK 建连探针，以及控制命令输出灌满、超时、取消、启动失败、串行操作竞争。

第 4 项中的电话端身份握手是测试客户端，两个原生 peer 在同一个 Mac 测试进程中；HTTP 为显式允许的 `127.0.0.1` 测试通道。这不是 iPhone 真机、公网 HTTPS、完整 Helper IPC、100 次完整业务重连或 8 小时稳定性证据。

### 本次实测记录

- 最终源码：Bridge 610 项、Relay 64 项测试通过，无跳过；独立 Swift 传输包、Mac App 全部源文件编译、Xcode 项目 plist 校验通过。
- 策略、16 MiB 双向原生传输、签名协商/E2E/`sync/hello`、SSE 重订阅与撤销、HTTP 异常边界、100 轮 SDK 建连、异步命令及串行取消测试通过。
- 新增 SDP 限额测试捕获了 Swift 按字符拆分 CRLF 时没有识别 `max-message-size` 的问题；已修正换行识别并复验，不以默认 16 KiB 掩盖更小的远端上限。
- 首次能力脚本构建期间源码仍有改动，SwiftPM 拒绝该构建；该次结果无效。冻结源码后复用相同临时依赖缓存，重跑脚本中的全部编译/验证步骤通过。
- 根 `pnpm test` 没有全绿：未修改的管理端 `activation.test.tsx` 在 Vitest fork worker 启动阶段超时，没有执行用例。独立重跑管理端仍出现同一启动错误；没有降低超时门禁、跳过或改写该测试。
- 构建基础 stack 审计通过。source 启发式审计将既有 `relay/Dockerfile` 的两个 `FROM runtime` 阶段别名误报为浮动镜像；人工确认它们引用同文件已固定 Node 版本及 digest 的 `runtime` 阶段，没有为消除误报改动 Dockerfile 或登记例外。

隔离 TURN 验证入口已经预留。只有取得可用测试服务后，才分别设置 `REMODEX_TEST_PATH=turn-udp`、`turn-tcp`、`turn-tls`；通过环境注入该服务的 `REMODEX_TEST_TURN_URLS` JSON 数组和测试签发密钥 `REMODEX_TEST_TURN_SECRET`。每轮只能配置一种承载，并强制 relay-only、核验实际选中中继路径。不得填写生产长期密钥或将这些值写入仓库/日志。缺少配置直接失败，不会跳过或冒充 TURN 通过。

## 阻断全面切换的资源门禁

- 当前本机仅有 Command Line Tools；没有可用完整 Xcode、iPhone 签名/真机与 Apple Silicon 验收环境的已确认入口。CLT 已支持本机 x86_64 原生能力验证，不能替代其余设备验收。
- 未取得获准使用的隔离 Linux/coturn 测试服务、证书和可验证的 UDP/TCP/TLS 端口。不能为通过该门禁而在生产 VPS 临时开服务；现有部署规则和本次授权都不允许这样做。
- 公网 HTTPS SSE、TURN/UDP、TURN/TCP、TURN/TLS、Mac/iPhone E2E、流量对照、100 次完整恢复及 8 小时运行仍须实测。

取得上述资源后，先补齐 Helper 与原生消费者的完整能力链路并通过门禁，再同步完成生产入口替换、逐 RPC 授权、TURN 凭据续期/ICE 重建、管理快照消费、同步推送与五分钟校准、iOS 前后台、coturn 配置/摘要/证书重载、签名打包、Windows 支持提示/资产和当前文档迁移。原部署安全门禁只能等价替换，不能提前删去以制造通过。

用户已于 2026-09-06 授权提交、推送、GitHub Actions 构建及 VPS 发版。该授权不豁免项目既有测试与部署门禁；不以本地能力脚本通过替代完整发布验收，未接入生产的传输模块不得宣称已上线。
