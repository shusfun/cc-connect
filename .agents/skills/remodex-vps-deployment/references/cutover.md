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

部署制品只取当前提交中的 `relay/`、根 `pnpm-lock.yaml` 和必要 workspace 清单，传到新的临时发布目录。不得在旧回滚目录内覆盖构建。构建前执行仓库基础设施审计；服务器构建必须使用当前锁文件和固定 Node 版本。

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
