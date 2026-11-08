# 独立服务宿主

首轮使用同一用户的一台电脑连接服务。当前已接文字资料管理、同机 AI 申请审批、动态插件模板和文字录入提案；其余资料类型依后续票接续。当前 Dockerfile 是自动验收镜像，不是 #102 的最终发布镜像。

## 启动

在本目录运行 `dart pub get`。在私有工作目录显式运行一次：

```sh
dart run bin/server.dart init-secrets /absolute/private/secrets
```

此操作生成三份互相独立的 32 字节材料：数据库密钥、用户接入 Token、服务器身份。目录必须不存在；重复初始化会拒绝，启动和重启不会自动重建丢失的密钥。文件权限为 600，目录为 700；应单独持久保管，不复制进镜像或源码。Token 的传输形式为原始字节的无填充 Base64URL，CLI 不得领取这个管理身份。受限 Agent 连接由 #93 接续。

配置文件仅含路径与监听信息，路径相对配置文件所在目录解析：

```json
{
  "dataDirectory": "data",
  "secretsDirectory": "secrets",
  "tlsCertificate": "server.pem",
  "tlsPrivateKey": "server.key",
  "address": "127.0.0.1",
  "port": 47126
}
```

TLS 私钥须为私有普通文件；证书须包含连接地址的 SAN 与服务端用途。客户端信任签发 CA 并正常验证主机名，不关闭验证，不修改系统全局信任。局域网容器可显式监听 0.0.0.0，端口与访问范围由部署配置控制。

```sh
dart run bin/server.dart serve /absolute/private/server.json
```

服务输出仅含 ready 状态、实际端口、协议版本和公开服务器身份。SIGINT/SIGTERM 关闭 HTTPS、核心及数据库。缺失/错误密钥或不合法配置直接失败，不覆盖现有库。备份恢复与普通重启不同：恢复不转移管理 Token、服务器身份或可用的旧聊天许可。

## 当前协议

协议版本为 1，所有接口均为 HTTPS，禁止浏览器 Origin。管理接口要求 `Authorization: Bearer <用户接入 Token>`，身份不合法返回 401；当前没有为 Agent 开放管理接口。

- `GET /v1/server`：协议与服务器身份。
- `GET /v1/owner/catalog`：目录层级、标签、当前启用的内置及插件模板，以及实际待办数量。
- `GET /v1/owner/summaries`：不含正文字段的资料摘要，供列表与关联名称查询。
- `GET /v1/owner/information/{id}`：指定资料的完整内容和冻结模板布局。
- `GET /v1/owner/information`：当前完整文字资料列表，供独立客户端取回核对。
- `POST /v1/owner/saves/{operationId}`：文字新增或修改。修改携带 itemId、baseVersion 及原字段身份；复用核心版本检查和原子保存。
- `GET /v1/owner/operations/{operationId}`：已提交操作的原始回执。响应丢失后先查询，或用完全相同的请求重试；同编号不同内容返回 409，不产生新资料。
- `GET /v1/owner/devices`：设备名称、编号与撤销状态，不返回接入凭证。
- `POST /v1/owner/devices`：传入 operationId、name，由用户身份登记受限 Agent 设备，回复 deviceToken。重复同一操作返回原结果，不能把用户 Token 交给 Agent。
- `POST /v1/owner/devices/{id}/revoke`：传入 operationId，撤销该设备之后的接入和内容交付。
- `POST /v1/owner/approvals/query`：按 keyword、filter、offset、limit 查询待办/已处理申请，可带 keepSelection。
- `GET /v1/owner/approvals/{id}`：待核对的字段及版本等元数据和 reviewToken，不返回正文或读取凭证。
- `POST /v1/owner/approvals/decisions`：按当前 reviewToken 提交整次批准、拒绝或撤销，使用共享 WorkspaceApprovalChange 格式；复用原审批事务和操作去重。
- `GET /v1/owner/approvals/operations/{operationId}`：核对原决定的回执；只有明确的 operation_not_found 表示未提交，连接失败不等于没有保存。
- `GET /v1/owner/plugins`：已安装插件、启停状态、模板定义及受影响资料数量。
- `POST /v1/owner/plugins/stage`：上传本机选择的声明式 JSON（filename、bytes Base64），最多1 MiB；不接收文件路径或执行代码。
- `GET /v1/owner/plugins/previews/{selectionId}`：沿用原插件校验与变更预览；`DELETE /v1/owner/plugins/selections/{selectionId}` 释放未安装的选择。
- `POST /v1/owner/plugins/changes`：以稳定 operationId 安装、启用、停用或移除；`GET /v1/owner/plugins/operations/{operationId}` 查询原操作。更新保持原启停选择，旧资料保留模板快照。
- `POST /v1/owner/proposals/query`、`GET /v1/owner/proposals/{id}`：提案清单及明确请求的完整预览，复用原新增展示、修改对比和冻结模板。
- `GET /v1/owner/proposals/catalog`：已有目录和本批建议目录，供核对保存位置；尚未批准时不会创建目录。
- `POST /v1/owner/proposals/decisions`：核对整份提案后一次保存或拒绝；版本、范围、字段格式及必填项仍由原业务规则检查。`GET /v1/owner/proposals/operations/{operationId}` 查询原回执，连接失败不能当作没有保存。
- `POST /v1/owner/proposals/{id}/related`、`saved`、`snapshot` 及 `GET .../current`：在提案内读取关联内容、此次保存的快照或当前目标，不把待入库项当作信息库记录。
- `POST /v1/owner/proposals/{id}/relations/query`、`summaries`：以 itemId、version 绑定当前提案中的关联查询。普通资料的关联查询用 `POST /v1/owner/relations/query`、`summaries`；均只返回名称、类型等元数据。

- `POST /v1/owner/classification/changes`：复用原目录和标签的新建、更名、版本核查及原操作回执；`GET .../operations/{operationId}` 核对原结果，`GET .../tag-removal/{tagId}` 先核对移除标签的影响范围。目录删除由 #100 接续，目前明确拒绝。
- `POST /v1/owner/library/preview`、`targets`、`moves`：完整选择、后代目录和资料、目标路径与前后位置经原移动规则核查；`GET .../operations/{operationId}` 核对丢失回复，不能自动换编号重做。`GET/POST .../order` 读取或保存原手动、名称、更新时间排序方式。
- `/v1/owner/catalog` 的 `workspace` 使用共用分类投影，包含后代目录计数和当前模板；`recordOrder` 是服务器的资料顺序。没有接通的文件或凭据创建入口不会因存储支持而提前开放。

用户审批接口复用 packages/info_workspace 中从原 App 提取的纯 Dart 适配，不在 HTTP 层重写审批规则。`GET /v1/server` 额外返回不含正文的 workspaceObservation，App 用它发现新待办及状态变化；它不广播到其他电脑，也不代表后置的跨端提醒已经完成。

Agent 使用设备登记回复中的 deviceToken，通过独立的 `Authorization: Bearer <deviceToken>` 调用 `POST /v1/agent/...`。当前已接 catalog、directories/catalog、plugins/catalog、templates/catalog、templates/read、capabilities、session、session/lifecycle、session/check、session/end、request、request/status、status、cancel、claim、read，以及 import/submit、import/revise、import/status、update/submit、update/revise、update/status、organization/request、organization/status、organization/tasks、organization/metadata、organization/submit，正文沿用 AgentProtocol。新增、修改和状态查询仍核对原设备及聊天身份；Agent 没有确认或修改正式资料的管理入口。sessionSecret、endCapability 和领取的读取 token 均绑定原设备；其他设备持有同一凭证也不能使用。用户管理 Token 不能调用 Agent 入口，设备 Token 不能调用用户管理入口。`capabilities` 只声明已接通的远程能力。

整理申请仍须在正常 App 批准，Agent 只得到获批资料的分类元数据，不得到正文。提交只能调整原批准范围的目录和标签，结果在原提案界面只读展示；查询完整目录本身不能写入。普通重启保留原获批范围与固定到期时间，已观察的到期结果也持久保存，系统时间回拨或重启不能重新启用；结束聊天同样不能恢复整理能力。

普通维护重启现在通过 OnlineInformationRuntime 保存和恢复文字聊天状态：待办、原会话与结束凭证、已批准字段、原读取凭证和固定到期时间。每个业务响应在加密状态保存成功后才发送；写入失败不交付已准备的内容。恢复先核对原审批记录，已撤销、结束、到期的许可不恢复；备份恢复会更换状态代际并清除有效接入与聊天关联。不要把普通授权历史当作可用许可导入。

**#93 文字流程已完成。** App 已接正常远程审批与待办刷新、受限设备配置生成；正式 CLI 和 Codex 关联已接 HTTPS，并通过无开发上下文 Agent 试用。接入步骤见 [正式远程说明](../../integrations/codex/REMOTE-INTEGRATION.md)。文字授权已做加密库和 HTTPS 宿主整体重建测试；文件和凭据的重启、执行与清理仍由 #97/#99 接续。本分支尚非 #102 的最终统一候选。

操作编号在重启后保留；客户端切换服务器时必须核对服务器身份，不能把前一服务的编号/许可直接迁用。请求格式错误返回 400，未知接口/未找到操作返回 404，核心冲突返回 409；内部错误只返回固定代码，不回显 Token、正文、密钥和本机路径。提案中的文件或凭据材料在对应功能接通前整体拒绝，不丢掉材料后仅保存文字。目录、标签、移动、排序和整理任务已接通；完整文件与凭据协议由对应后续票接通，当前接口不代表这些能力已交付。

## 自动检查

```sh
dart test --reporter expanded
dart analyze bin lib test
```

从仓库根目录运行 Linux ARM64 验收和实际容器重建：

```sh
docker build -f apps/server/Dockerfile -t chiyo-server-verification:a01 .
docker run --rm chiyo-server-verification:a01
python3 scripts/qa/check-server-container.py
```

测试只生成合成资料、临时证书及密钥。它验证真实 SQLCipher、独立进程正常退出/重开、TLS 校验、操作去重、旧单机格式加密备份恢复，以及删除/重建容器后的资料取回。脚本结束会移除自己的容器和临时目录，不操作其他容器或个人资料。
