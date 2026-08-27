# Release 与部署效率经验

## 适用指纹

适用于 Signed Release、Docker 多架构镜像、Release 输入、deploy-host 安装或容器 bootstrap 出现失败时。普通代码构建、运行态业务故障和当前正在替换的 Codex 会话架构不使用本 Note。

## 前提

- 用当前代码重新核验 Release 编排、容器输入、制品契约和安装所有者仍分别位于 `.github/workflows/release.yml`，`Dockerfile`、`.dockerignore`、`compose.yaml` 与根 workspace/lock，`scripts/release-manifest.go`、`releasecontract/`，以及 `deploy/`、`containerhost/`。
- 外部 run、tag、镜像、服务、Secret 和执行槽以当前平台或主机的权威状态为准；历史成功和授权不延续。
- 当前任务若命中未提交的 Codex App、Runtime protocol 或远程会话重构，不使用本 Note 推断其架构或验证范围。

Note 只提供故障信号和已验证判断；命令、制品集合和当前运行状态始终回到上述入口或平台实时接口核验。

## 候选动作与成本

| 当前信号 | 候选动作 | 消除的不确定性与成本 | 成功、失败或停止信号 |
| --- | --- | --- | --- |
| 全新 checkout 报 Release 输入缺失 | 对照 workflow 的输入检查核验目标路径是否同时存在且被 Git 跟踪 | 纯静态、低成本；区分本机脏文件与可复现 Release 输入缺口 | 缺文件或未跟踪即定位输入问题，停止重跑 Release；两者都成立再查实际失败步骤 |
| Docker 报 `ERR_PNPM_NO_LOCKFILE` | 核验 build context 是否包含唯一根 `pnpm-lock.yaml`、`pnpm-workspace.yaml`，以及 install 是否从根 workspace 执行 | 纯静态、低成本；直接验证错误所需输入，不下载镜像或启动完整构建 | 任一输入缺失即支持根因；全部存在则该经验不匹配，转查实际 Docker 日志与阶段 |
| Go embed 报输入缺失 | 核验目标文件的 Git 身份和 `.dockerignore` 排除、重包含顺序 | 纯静态、低成本；区分源文件缺失与 build context 过滤 | 目标被排除即支持根因；不能通过放宽全部敏感配置排除修复 |
| 覆盖 deploy-host 后仍表现为旧版本 | 在准确主机和 UTC 窗口读取服务主进程身份、revision 与新鲜日志 | 只读远程信号，需当前访问授权；区分磁盘文件更新与进程实际接管 | 进程仍为旧 revision 时才把 restart 作为候选外部操作；已接管则停止，不重复安装 |
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

## 证据

- `v0.1.1` 的多架构镜像构建曾因缺少 workspace 文件在依赖安装阶段失败；补齐唯一根 workspace 契约后越过该阶段。
- `v0.1.2` 随后因 `.dockerignore` 排除了 `config.example.toml` 这一 Go embed 输入而失败；按顺序显式重包含后修复。
- `v0.1.3` 的 Debian Docker 部署暴露了 systemd `RuntimeDirectory` 与 deploy-host socket GID 所有权问题；bootstrap 每次 restart 是让新二进制真正接管事务的必要信号。
- 多架构镜像、签名和外部发布属于高成本步骤。优先用单次失败的准确阶段和当前输入缩小原因，再决定是否需要新的完整运行。

## 当前限制与候选优化

- 本 Note 不证明任何历史 tag、CI run、镜像或服务当前仍可用。
- 当前工作树中的 Codex App、Runtime protocol 和远程会话重构尚未提交，不属于本 Note 的稳定能力。
- 当前没有经过实施并复验、可作为现行能力记录的额外优化候选。

## 失效条件

以下任一所有者变化后重新核验：根 workspace/lock 结构、Docker build context、Go embed 输入、Release workflow、manifest 格式、Compose 拓扑、bootstrap、deploy-host/systemd 所有权或签名身份。

## 最后核验

2026-08-28，核对提交 `d25f37e1` 中未被当前业务重构修改的 Release、Docker、workspace、bootstrap 与 deploy-host 入口。历史故障证据来自 `docs/history/agent-notes/2026-08-workspace-chat-verification.md`，该归档不是当前 runbook。
