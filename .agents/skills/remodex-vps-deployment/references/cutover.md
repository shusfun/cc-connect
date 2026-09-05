# 事务切换手册

## 连接前核验

先在本机只读核验私钥权限与公钥指纹；不得输出私钥正文：

```bash
test -f /Users/wangshangbin/Downloads/pem/2h4g5mGzShus.pem
ssh-keygen -y -f /Users/wangshangbin/Downloads/pem/2h4g5mGzShus.pem | ssh-keygen -lf -
ssh-keygen -F 106.55.5.233 -f /Users/wangshangbin/.ssh/known_hosts
```

统一 SSH 前缀：

```bash
ssh -i /Users/wangshangbin/Downloads/pem/2h4g5mGzShus.pem \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/Users/wangshangbin/.ssh/known_hosts \
  root@106.55.5.233
```

首次连接只读采集目标身份和占用：主机名、时间、`127.0.0.1:9820` 监听者、`cc-connect-deploy-host.service` 状态、旧 CC-Connect 容器的精确 ID/镜像/挂载、两个回滚目录是否存在，以及新部署目录是否已存在。发现目标身份或资源所有权不一致时停止。

## 制品与启动

优先按已验证镜像 digest 部署，不使用浮动 main 作为运行身份。用户明确要求重建时，构建上下文包含 `relay/`、`apps/control/`、`packages/protocol/`、`packages/updater/`、根锁文件与 workspace 清单，以及下述两个 Bridge 测试辅助文件；不传 `.cc-connect/`、本机依赖、凭据或完整工作区。记录基线 SHA、未提交部署修复及输入归档 SHA-256；传到独立发布目录，不覆盖旧回滚目录。构建前执行基础设施审计；构建内执行 React 构建、Relay 和更新器测试，使用固定 Node/pnpm 和基础镜像摘要。macOS 不启动 Docker。

主密钥和一次性 Setup 凭据在服务器生成，文件所有者必须允许容器 UID 10001 读取，权限 0400，不在日志或对话中回显。新镜像的 `/data` 预置 UID/GID 10001，确保首次命名卷初始化可写。先用无发布端口、隔离测试卷的候选容器验证真实入口、只读文件系统、SQLite WAL、Setup 错误凭据拒绝及未授权 WSS 拒绝；不可在生产数据库预置测试账号。

现有 Relay 集成测试依赖 Bridge 的 `secure-transport.js` 与 `secure-device-state.js`，构建上下文须包含这两个测试辅助源文件；它们只进入测试构建阶段，不进入服务器运行镜像，不跳过对应测试。

Compose 消费 `REMODEX_IMAGE` 与 `REMODEX_UPDATER_IMAGE`，固定到已验证仓库 digest，不在 `up` 时隐式构建。旧测试部署缺少执行器凭据、更新卷、标签与挂载，不能直接覆盖 Compose 后启动。先备份原数据库与配置，在隔离环境验证迁移及失败回滚，再按当前授权切换。新更新器只处理固定项目归属标签，不能把同机已有无归属容器自动收编。

切换窗口内记录旧服务与容器精确状态，然后停止旧 CC-Connect 容器和 `cc-connect-deploy-host.service`，不删除任何旧文件。启动新容器后核验：

```bash
curl --fail --silent http://127.0.0.1:9820/health
```

响应必须为 `{"ok":true}`。同时核验容器实际用户、只读根、capabilities、绑定地址、健康状态和日志轮转，不以 Compose 文本代替运行态。

## 外部与 E2E 验收

从外部对 `wss://cc.syggu.cn` 做真实握手，确认 TLS 域名和代理上游未变。随后用当前 Mac Remodex.app 与 iPhone 完成扫码/短码配对、加密握手和一项无副作用 RPC。检查 Relay 日志不得包含 sessionId、Token、Cookie、密钥、路径或聊天正文。

完整验收未完成时保持旧目录与服务可恢复。不要因为健康检查通过就提前删除回滚点。

## 回滚与清理

任一新链路验收失败：停止新容器，按切换前记录恢复旧容器与 `cc-connect-deploy-host.service`，再次核验 `cc.syggu.cn`。不要修改 OpenResty、1Panel 或数据库补救应用错误。

只有全部完成条件通过后，才可删除旧服务定义、旧容器以及：

- `/opt/cc-connect-docker`
- `/var/lib/cc-connect-docker`

删除前再次解析绝对路径、确认无新容器挂载且资源属于旧 CC-Connect。清理后复验新容器健康、WSS 和 E2E 连接。
