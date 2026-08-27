# Release 与部署效率经验

## 适用指纹

适用于 Signed Release、Docker 多架构镜像、Release 输入、deploy-host 安装或容器 bootstrap 出现失败时。普通代码构建、运行态业务故障和当前正在替换的 Codex 会话架构不使用本 Note。

## 前提

- 用当前代码重新核验 Release 编排、容器输入、制品契约和安装所有者仍分别位于 `.github/workflows/release.yml`，`Dockerfile`、`.dockerignore`、`compose.yaml` 与根 workspace/lock，`scripts/release-manifest.go`、`releasecontract/`，以及 `deploy/`、`containerhost/`。
- 外部 run、tag、镜像、服务、Secret 和执行槽以当前平台或主机的权威状态为准；历史成功和授权不延续。
- Codex App、Runtime protocol 和远程会话的架构事实由对应 ADR、协议文档与 Codex Desktop Bridge Note 所有；本 Note 只处理其发布、安装和激活故障。

Note 只提供故障信号和已验证判断；命令、制品集合和当前运行状态始终回到上述入口或平台实时接口核验。

## 候选动作与成本

| 当前信号 | 候选动作 | 消除的不确定性与成本 | 成功、失败或停止信号 |
| --- | --- | --- | --- |
| 全新 checkout 报 Release 输入缺失 | 对照 workflow 的输入检查核验目标路径是否同时存在且被 Git 跟踪 | 纯静态、低成本；区分本机脏文件与可复现 Release 输入缺口 | 缺文件或未跟踪即定位输入问题，停止重跑 Release；两者都成立再查实际失败步骤 |
| Docker 报 `ERR_PNPM_NO_LOCKFILE` | 核验 build context 是否包含唯一根 `pnpm-lock.yaml`、`pnpm-workspace.yaml`，以及 install 是否从根 workspace 执行 | 纯静态、低成本；直接验证错误所需输入，不下载镜像或启动完整构建 | 任一输入缺失即支持根因；全部存在则该经验不匹配，转查实际 Docker 日志与阶段 |
| Go embed 报输入缺失 | 核验目标文件的 Git 身份和 `.dockerignore` 排除、重包含顺序 | 纯静态、低成本；区分源文件缺失与 build context 过滤 | 目标被排除即支持根因；不能通过放宽全部敏感配置排除修复 |
| 覆盖 deploy-host 后仍表现为旧版本 | 在准确主机和 UTC 窗口读取服务主进程身份、revision 与新鲜日志 | 只读远程信号，需当前访问授权；区分磁盘文件更新与进程实际接管 | 进程仍为旧 revision 时才把 restart 作为候选外部操作；已接管则停止，不重复安装 |
| 新 Release 删除旧 control 仍要求的 manifest 字段 | 先用当前运行 control 的 `releasecontract.Decode` 契约检查目标 manifest | 纯静态、低成本；判断升级是否会在进入 deploy-host 事务前失败 | 契约不兼容即停止 Web 重试，先交付可被当前 control 读取的补丁升级路径；不得靠 deploy-host 重装掩盖 control 侧拒绝 |
| watchdog 已回滚，但旧 control 反复重启 | 同时读取宿主 `CurrentTag/LastOutcome/Pending` 与 control activation 记录 | 只读、低成本；区分真实候选失败与已回滚后残留 activation 的恢复循环 | 宿主已回到前版且 activation 仍存在即定位残留所有权问题；由 activation 所有者收敛后再重启，不重复触发部署 |
| 纯 Web 项目在生成配置或启动时被判定“无平台” | 在 Agent 能力已初始化后，通过真实 Engine 组装入口验证 management Web 平台可达 | 聚焦组装验证；区分静态配置形状与运行时能力 | Web 平台可达即允许纯 Web 项目；不可达时返回准确能力错误，不添加虚构消息平台 |
| Runtime 暂存 Release 报 `cosign` 不在 PATH | 核验常驻 Runtime 的真实可执行文件、进程 PATH 来源和安装入口传入的 cosign 所有权 | 只读检查加一次签名探针；区分制品错误与验证器未进入常驻环境 | manifest 用同一 OIDC identity 验签成功但常驻进程找不到命令即定位环境所有权；先修正受管 Runtime 环境，不重试部署或跳过签名 |
| 核验 deploy-host 版本 | 只调用 `cc-connect-deploy-host --version`，并同时核对 systemd `MainPID` | 裸 `version` 会被 Go flag 解析器忽略并启动第二个服务实例，可能替换同一路径 Unix Socket | 版本命令退出且进程列表只有 systemd `MainPID`；若 Socket API 与状态文件不一致，先排查重复实例，不继续部署 |
| 已失败的 Release 需要修复交付 | 核验失败 tag 的 SHA、不可变状态和后续目标提交 | 低成本平台查询；避免移动历史 tag 或重复同一失败输入 | 使用新提交和后续补丁 tag；没有当前发布授权时止于诊断与建议 |

每轮只选择与精确错误和当前身份匹配的一项。没有匹配信号时回到 workflow、脚本和实时状态形成新的候选，不依次尝试本表。

## 成功、失败与停止信号

- 当前输入、失败步骤或运行进程已经解释症状时，停止重复下载日志、启动 watcher 或重跑完整 Release。
- 候选检查否定历史经验时，不扩大旧事故的适用范围；根据最新失败阶段选择一项新信号。
- 只有根因修复后仍需要证明完整发布契约，且用户已经授权相应外部操作时，完整 Release 才进入候选。
- 当前任务只要求诊断时，以根因证据和未执行操作的影响说明收口，不把诊断自动升级为发布。

## 已证实的低收益路径

- 不复制第二份前端 lock，不关闭 frozen lockfile，也不反复更换工作目录试错。
- 不因一次多架构失败重复下载相同日志、重复启动 watcher 或立即重跑完整 Release。
- 不把过去通过的 build、test、race、lint 数量当成当前变更的验证清单。
- 不在 macOS 本地启动 Docker 来模拟正式容器通道。
- 不在目标 manifest 已被当前 control 拒绝时重复更新 deploy-host；该操作不能改变 control 进程内的解码契约。
- 不在 watchdog 已回滚后只靠反复重启 control 清除 activation；残留记录会让旧 control 重新进入同一恢复分支。

## 证据

- `v0.1.1` 的多架构镜像构建曾因缺少 workspace 文件在依赖安装阶段失败；补齐唯一根 workspace 契约后越过该阶段。
- `v0.1.2` 随后因 `.dockerignore` 排除了 `config.example.toml` 这一 Go embed 输入而失败；按顺序显式重包含后修复。
- `v0.1.3` 的 Debian Docker 部署暴露了 systemd `RuntimeDirectory` 与 deploy-host socket GID 所有权问题；bootstrap 每次 restart 是让新二进制真正接管事务的必要信号。
- `v0.2.14` 至 `v0.2.16` 的实机升级确认：当前 control 会先按自身 manifest 契约读取目标 Release；删除其必需字段时不会通过重装 deploy-host 自动恢复。watchdog 回滚与 control activation 是两个状态所有者，宿主已回滚但 activation 残留时会形成恢复重启循环。
- Web-only 项目必须在 Agent 能力已知后验证 management Web 平台；静态阶段要求外部消息平台会错误拒绝合法配置。
- `v0.2.16` Runtime 暂存失败证明安装脚本使用的临时 cosign 路径不会自动成为常驻 Runtime 的 PATH；签名验证器属于 Runtime 更新环境的持续依赖。
- 多架构镜像、签名和外部发布属于高成本步骤。优先用单次失败的准确阶段和当前输入缩小原因，再决定是否需要新的完整运行。

## 当前限制与候选优化

- 本 Note 不证明任何历史 tag、CI run、镜像或服务当前仍可用。
- 当前 Runtime 仍依赖外部 `cosign`；安装与手动启动会把显式验证器路径传入常驻进程。让 Release 自包含验证器仍只是候选设计，实施并复验前不得视为现行能力。

## 失效条件

以下任一所有者变化后重新核验：根 workspace/lock 结构、Docker build context、Go embed 输入、Release workflow、manifest 格式、Compose 拓扑、bootstrap、deploy-host/systemd 所有权或签名身份。

## 最后核验

2026-08-28，按 `v0.2.14` 至 `v0.2.16` 的 Signed Release、Debian 容器部署与 macOS Runtime 实机升级复验 Release、manifest、activation、Web-only 组装和 cosign 环境边界。历史故障证据来自 `docs/history/agent-notes/2026-08-workspace-chat-verification.md`，该归档不是当前 runbook。
