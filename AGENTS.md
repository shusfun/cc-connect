# CC-Connect 项目协作约束

> 本文件只保存项目级硬不变量。具体方案、诊断路径和验证方式必须结合当前增量选择，不在这里维护固定步骤清单。

## 1. 职责与知识路由

- 处理会影响代码、契约、运行状态、部署或发布的任务时，使用 `$cc-connect-project-context` 核验当前所有者和适用经验；纯拼写文案或用户已给出无需判断的精确命令不需要加载它。
- 当前代码、依赖清单、构建入口、CI/Release workflow 和实时平台状态优先于历史文档。`docs/history/` 只保存历史证据，不是当前运行手册。
- 架构决定归 `docs/decisions/`，外部操作归部署手册，经过复验的高收益路径归 `.agents/notes/`。同一知识只保留一个当前所有者。
- 未提交的架构过渡、单次通过数量、排查流水账、当前任务授权和未经实施的优化不得写成稳定能力。

## 2. 权威所有者与依赖方向

- `core/` 拥有通用接口、Engine 编排、会话、跨平台能力和 i18n。它可以使用与业务无关的公共依赖，但不得导入具体 `agent/*` 或 `platform/*`。
- `agent/*` 和 `platform/*` 各自拥有外部进程或平台的协议、生命周期和适配逻辑，通过 registry 与 capability interface 接入。不得在 `core/` 通过名字判断或具体类型分支承载适配器知识。
- `config/` 是配置解析与校验的权威来源；`Makefile` 是选择性编译标签的权威来源；共享构建版本以 `go.mod`、根 workspace/lock 和 workflow 为准。
- `controlplane/` 拥有认证、设备、服务和部署业务事务；`runtimeclient/`、`runtimeprotocol/` 与 `remotenative/` 共同承载配对设备边界。其部署与激活所有权以 [Control、Server 与远程 Runtime 的部署所有权](docs/decisions/2026-08-24-control-runtime-deployment.md) 为准。
- `web/` 消费管理 API，不是后端契约的第二权威来源。接口变化必须同时核对后端生产者、Web 及其他当前消费者。

## 3. 契约、兼容与数据

- REST、WebSocket、Runtime 协议、事件、配置和共享类型都只能有一个当前权威定义。修改时追踪生产者、传输边界、全部当前消费者、生成物和文档。
- 不因“稳妥”增加别名、双读双写、旧 RPC、兼容开关或静默 fallback。确有公开消费者、存量数据或版本承诺时，按 [版本、兼容与迁移所有权](docs/decisions/2026-08-27-versioning-and-compatibility.md) 记录兼容所有者与退出条件。
- 每个持久化存储自行拥有迁移策略。旧工作区聊天决定中的精确重建策略只适用于其明确的数据域，不得推广到 `control.db`、Session、配置或其他用户数据。
- 能力探测只判断当前能力是否可用；缺失时返回明确原因，不切换到未声明的旧协议。

## 4. 安全、日志与生命周期

- 运行日志统一使用 `slog` 并携带必要上下文；不得静默吞错。Token、Cookie、密码、密钥和认证材料必须在错误、日志和诊断输出中脱敏。
- 客户端提交的路径、cwd、thread、设备和资源标识都不是天然可信输入；在权威边界重新校验归属，不把设备本地路径或私有路由字段暴露到公网契约。
- 一个业务操作只能有一个事务或生命周期所有者。该所有者统一协调 context 取消、worker 登记与等待、channel 关闭、资源释放和最终状态发布。
- 用户可见终态只能在权威写入和对应输出尝试完成后发布；失败路径必须收口回滚、取消和资源清理。
- 新增用户可见文案时使用 `core/i18n.go` 的 `MsgKey`，并保持当前支持语言一致。
- Release 签名、镜像/制品身份、control 与 deploy-host 权限边界不得降级；外部状态和操作以部署手册及平台实时信号为准。

## 5. 经验驱动的操作选择

- 日志、静态分析、测试、构建、浏览器和真实入口都是候选证据，不构成默认顺序或固定套餐。
- 本地操作只补当前尚未覆盖的风险。完整合并与发布门禁的权威在 `.github/workflows/ci.yml` 和 `.github/workflows/release.yml`，普通任务不得默认在本地镜像整套 CI。
- 复用当前进程、日志、下载、缓存、构建产物和已取得的等价结果。运行高成本或外部步骤前，先说明它覆盖的独立风险；没有新增信息收益时不运行。
- 每取得一项结果都重新选择下一项操作或停止。最新需求和验收目标已满足后立即收口，不因历史清单继续追加动作。
- 发现稳定且跨任务可复用的高收益路径时，更新已有 ADR、部署手册或 Agent Note；找不到明确所有者时再建立新的窄 Note。

## 6. 当前知识入口

- 架构与版本：`docs/decisions/2026-08-23-unified-workspace-chat.md`、`docs/decisions/2026-08-24-control-runtime-deployment.md`、`docs/decisions/2026-08-27-versioning-and-compatibility.md`
- 部署运行手册：`docs/deployment.md`、`docs/deployment.zh-CN.md`
- 发布与部署经验：`.agents/notes/release-deployment-efficiency.md`
- 项目经验路由：`.agents/skills/cc-connect-project-context/SKILL.md`
- 生产浏览器认证：`.agents/skills/cc-connect-production-browser-auth/SKILL.md`
