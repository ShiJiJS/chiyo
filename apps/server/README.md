# 独立服务宿主

首轮使用同一用户的一台电脑连接服务。当前已接资料管理、同机 AI 申请审批、动态插件模板、文字与普通文件提案，以及用户文件预览/另存/打开。Agent文件授权和传输已接，CLI本机副本执行仍在#97开发；凭据由后续票接续。当前 Dockerfile 是自动验收镜像，不是 #102 的最终发布镜像。

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

Agent 使用设备登记回复中的 deviceToken，通过独立的 `Authorization: Bearer <deviceToken>` 调用 `POST /v1/agent/...`。当前已接 catalog、directories/catalog、plugins/catalog、templates/catalog、templates/read、capabilities、session、session/lifecycle、session/check、session/end、request、request/status、status、cancel、claim、read，以及 import/submit、import/revise、import/status、update/submit、update/revise、update/status、organization/request、organization/status、organization/tasks、organization/metadata、organization/submit，以及 import-file/submit、import-file/status 和下方普通文件交付接口，正文沿用 AgentProtocol。新增、修改和状态查询仍核对原设备及聊天身份；Agent 没有确认或修改正式资料的管理入口。sessionSecret、endCapability 和领取的读取 token 均绑定原设备；其他设备持有同一凭证也不能使用。用户管理 Token 不能调用 Agent 入口，设备 Token 不能调用用户管理入口。`capabilities` 只声明已接通的远程能力。

整理申请仍须在正常 App 批准，Agent 只得到获批资料的分类元数据，不得到正文。提交只能调整原批准范围的目录和标签，结果在原提案界面只读展示；查询完整目录本身不能写入。普通重启保留原获批范围与固定到期时间，已观察的到期结果也持久保存，系统时间回拨或重启不能重新启用；结束聊天同样不能恢复整理能力。

普通维护重启现在通过 OnlineInformationRuntime 保存和恢复文字聊天状态：待办、原会话与结束凭证、已批准字段、原读取凭证和固定到期时间。每个业务响应在加密状态保存成功后才发送；写入失败不交付已准备的内容。恢复先核对原审批记录，已撤销、结束、到期的许可不恢复；备份恢复会更换状态代际并清除有效接入与聊天关联。不要把普通授权历史当作可用许可导入。

**#93 文字流程已完成。** App 已接正常远程审批与待办刷新、受限设备配置生成；正式 CLI 和 Codex 关联已接 HTTPS，并通过无开发上下文 Agent 试用。接入步骤见 [正式远程说明](../../integrations/codex/REMOTE-INTEGRATION.md)。文字授权已做加密库和 HTTPS 宿主整体重建测试；普通文件的服务端授权及重启已由#97接通，本机领取/清理与凭据仍由#97/#99接续。本分支尚非 #102 的最终统一候选。

操作编号在重启后保留；客户端切换服务器时必须核对服务器身份，不能把前一服务的编号/许可直接迁用。请求格式错误返回 400，未知接口/未找到操作返回 404，核心冲突返回 409；内部错误只返回固定代码，不回显 Token、正文、密钥和本机路径。普通文件提案已经接通；含尚未接通的凭据材料仍整体拒绝，不丢掉材料后仅保存文字。目录、标签、移动、排序和整理任务已接通；文件CLI本机执行与凭据仍在开发，当前接口不代表这些完整能力已交付。

## 普通文件的当前阶段

用户侧`/v1/owner/files`已经连接上传、导入、替换/恢复、历史、原文读取及旧模板多附件表单；文件最大10MiB，原文回复含长度、SHA256与Base64字节，不含服务器路径。App本机另存/打开使用原发布和清理驱动，操作记录留在本机独立私有日志。上传暂存和正式资料、访问许可分别处理。

Agent的文件传输使用`POST /v1/agent/information-file/<action>`，同时核对受限设备与原会话。正文须含`protocolVersion:2`、对应`command:file-<action>`和`sessionSecret`，只允许规定字段：

| action | 额外输入 | 结果 |
|---|---|---|
| fetch | requestId、itemId、fieldId、operationId | 固定原操作和附件版本，先返回preparing元数据；重试不会改成新版本。 |
| status | deliveryId或operationId | 查询原结果，不新建交付。 |
| download | deliveryId | 原许可仍有效时返回该记录的不可变原文字节。 |
| complete | deliveryId、byteLength、sha256 | 设备核对副本后确认，成功才记ready。 |
| release | deliveryId | 停止使用，先记cleanup_pending。 |
| cleanup | deliveryId | 设备实际清理后确认，才结束该交付；原已结束会话可确认自己的清理，但不能领取原文。 |

`information-attachments.v1`和`information-device-delivery.v1`表示文件传输接口已接通。当前Mac CLI使用真实本机文件驱动登记、写入、验证，并重新核对原许可后返回本机路径；不打印download原文或内部清理证明。`info --connection`在准确配置文件旁保存私有设备登记；Codex封装在准确关联文件旁保存，不能按公开聊天ID查找读取能力。一次CLI进程退出后，同包`info-runtime-worker --information-file-guardian`内部模式继续看护副本，不要求App打开。该模式不是Agent命令或新的用户入口。

`information-file-cleanup-watch.v1`提供仅供本机看护的`watch`、`discard`动作。正文严格为`protocolVersion:2`、`command:file-watch`或`file-discard`、`deliveryId`及`cleanupCapability`，不接受sessionSecret或路径；同时核对原设备和这份副本的清理证明。它只能观察最小状态和确认本机已清理，不能获取文件、版本元数据、聊天或访问许可。清理证明仅在原会话认证的fetch及内部download/complete回复中提供；普通status、历史、目录及备份均不包含它。

本机登记只保存操作、副本身份、看护进程身份及清理/控制证明，不保存可读聊天证明或原文。看护进程退出后的恢复先核对真实进程身份和OS锁，再按原文件身份清理并确认；观察超时不会启动第二份副本。日常CLI命令也会尝试补清已确认死亡的看护遗留，即使原聊天已结束；清理失败保留登记，不阻断无关查询，也不宣称清理成功。网络状态无法确认时停止交付并清理副本，恢复连接后再确认。用户自行另存的文件不在该回收范围内。

服务器本身没有文件副本lease。普通重启保留仍有效的原会话、操作和期限，结束/撤销/观察到期不恢复；未确认物理清理的设备副本继续记待清理。含清理证明的服务器私有交付记录启用库格式55，旧程序应拒绝；此前格式54的非终态设备记录在正常会话fetch时一次补入证明，身份、版本和期限不变且证明不可轮换。便携历史仍不包含运行证明、设备路径或活动许可。文件协议错误使用现有协议2结果包返回，HTTP 200不表示其status为ok；认证层失败仍返回401等HTTP错误。#102统一匹配候选仍未交付；原生面板与正式安装后置，其他平台本机行为不在此声明通过。

## 用户凭据保存

`/v1/owner/credentials`只接受用户管理身份，Agent设备凭证不能使用。这组接口接通保存，不代表AI已获得使用凭据的许可；联网凭据执行由#99接续。

| 方法与路径 | 用途 |
|---|---|
| POST `inputs` | 专用私有输入：operationId、form=string及secret，或form=file、filename及Base64 bytes。字符串最多64KiB，文件最多1MiB。返回不含材料的候选及输入摘要。 |
| GET / DELETE `inputs/<operationId>` | 核对或取消原输入；丢回复不改操作编号，查询失败不视为不存在。 |
| DELETE `candidates/<id>` | 释放已确认的表单候选；不会撤销或重做已保存的操作。 |
| POST `save` / `enabled` | 使用共享WorkspaceCredentialWrite / Toggle保存或停用；复用原记录/材料版本、分类关联、操作去重与事务。 |
| GET `operations/<operationId>` | 查询原持久回执；不返回材料。 |
| GET `<credentialId>` / `<credentialId>/materials` | 说明、账号、关联和材料版本元数据；不包含密码、文件原文或服务器路径。 |

暂存沿用原16份、合计16MiB限制，只在私有内存中持有材料；提交后进入原SQLCipher加密库。输入操作的元数据数量另限512，未完成输入按单调时钟30分钟释放，取消早于上传时也阻止该迟到上传。Host周期清理且关闭时清除暂存；未知保存结果仍按原操作/回执核对，不因释放表单而猜结果或重复创建。

Mac App通过正常“添加凭据”、更换材料、编辑和停用入口接这些接口，复用同一私有输入组件及原生选择边界。用户填写的材料不进入普通Workspace DTO或列表；信息库摘要与关联选择包括凭据元数据。资料读取与凭据详情共用原展示投影。Agent也可按当前动态模板提交字符串、Token及凭据文件提案；凭据保存与实际使用分开，后者仍由#99接续。


## 凭据提案与用户补填密码

正常Agent协议现宣告`credential-import.v1`。CLI按动态模板提交整份提案：未进入AI上下文的人设密码使用`source: owner`占位，Token或已读到的密码使用`agentString`并标明已进入上下文；凭据文件使用原`agentFile`/`filePath`提交，不增加配置字段提取协议。关联仍用原`relations`，同份待录入引用以`itemKey`标识。

正常App沿用原提案预览和内联密码组件，类型、账号、用途与关联为元数据；显示/隐藏由用户操作。专用用户管理接口如下，只供受信任Host，不属于Agent协议或普通Workspace DTO：

| 方法与路径（相对`/v1/owner/proposals`） | 用途 |
|---|---|
| POST `<id>/passwords/read` | 严格接收`version`、`itemKey`，只读准确待处理版本中用户填写的密码，初始化私有输入控件。 |
| POST `<id>/passwords/fill` | 严格接收`version`、`operationId`、`values`，一次修订整批输入并原子保存私有回执；不正式入库，也不批准AI使用。 |
| GET `password-operations/<operationId>` | 核对原密码填写操作；确认不存在才返回`operation_not_found`，查询失败不是不存在。 |

密码批次和不含原文的回执共用SQLCipher事务；回执只在服务器私有状态中，普通提案、目录、日志、Agent状态和便携备份都不包含密码或私有填写回执。已保存的资料/凭据仍走原备份范围；未处理提案输入沿用原策略，不进入便携备份。普通服务器重启保留私有填写结果及原操作身份。

丢回复先查原操作，不换编号自动重填；查询失败保留私有输入并要求核对。核对成功只恢复审阅，不自动审批整份提案；确认未保存后才允许用户明确重试或修正输入。必填缺少、版本变化或实际存储失败都不能部分入库。受限Agent设备凭证不能访问这些用户私有接口。


## 凭据设备申请与执行（#99接续中）

独立Host使用`EncryptedInformationRepository.openOnline`保留运行事实，再由`OnlineInformationRuntime`恢复私有原设备/聊天绑定；旧单机`open`行为不变。私有textRuntime格式3保留已批混合字段范围及原期限、未确认决定的禁用状态、观察到的到期。旧文本运行格式可读，但不能从缺少绑定的凭据历史生成许可；便携恢复也不带该绑定。

内部Agent路径`/credential-use/device/request`接收原协议2的request-use正文、sessionSecret及deviceLaunch。DeviceCredentialLaunch在执行电脑做工具/工作目录预检，绑定准确原计划；身份取认证网关，不接受正文指定设备。服务器沿用原接收方式校验并保存申请，不探测设备路径，不启动程序；status/claim及正常用户审批继续共用。正常长驻CLI已接设备执行；服务器宣告credential-device-execution.v1，尚不宣告credential-use-reuse.v1。

正常App读取审批详情使用显式v2路径`/v1/owner/approvals/details/<id>`，它完整携带原Workspace的凭据及执行元数据。原GET `/v1/owner/approvals/<id>`仍是v1，拒绝凭据详情以免旧客户端静默丢掉接收程序等审阅内容。两种路径均只接受用户管理身份；动作仍走原decisions及持久回执，不另写批准规则。

内部设备路径还包括`/credential-use/device/operation`、`operation/status`、`execution/status`及证明控制的`worker/register`、`materials/register`、`execution/report`、`cleanup/complete`。首次领取走私有材料DTO，不能透传普通CLI输出；以后同操作仅返回元数据。执行证明在发布前持久保存并绑定原设备，清理证明不能读取材料或启动另一操作。私有credentialRuntime2嵌在textRuntime3，旧inner1可读取。

CLI在自己的电脑核对程序、工作目录、进程组和文件身份，先写私有清理登记再允许材料写入及worker启动。服务器不创建这些明文文件、不查设备PID。正常JSON-lines CLI已实际通过Token/文件合成接收、系统SSH连接独立容器、服务重开、撤销/聊天结束、崩溃清理和丢回复不重放检查。逐命令Codex适配器也已接仅回环的设备后台程序，共用原16条执行/输出限制及30分钟完成输出保存；连接记录只有控制证明与进程身份，不保存聊天读取证明。两个CLI竞争、连接记录丢失及接受回复丢失均不会第二次启动，并已用独立客户端/worker二进制验证。正常App已接原SSH信任导入、预览及确认/撤销，并通过SSH会话内不限时、Token固定期限审批后关闭App继续实际使用的完整场景；未确认审批重开后准确核对原回执仍待续，#99仍打开。阶段证据见`docs/development/evidence/server-a09/README.md`。

## SSH主机信任管理

正常App在服务器插件设置中选择本机known_hosts文件，读取与原始文件1MiB限制在设备上核对，服务器不接受设备路径或探测网络。用户预览来源、指纹及替换范围后确认，保存仍由原OwnerWorkspaceHosts规则处理。文件暂存固定30分钟、最多32份选择，正常导入/撤销有持久原操作回执，重试不重复变更。预览与上传均不授予Agent使用凭据。

`/v1/owner/ssh-hosts`仅供用户管理身份：GET清单及已导入文件；POST inputs上传公钥记录、GET inputs/<operationId>查原选择；GET previews/<selectionId>预览、DELETE selections/<selectionId>释放；POST imports确认整份导入、GET import-operations/<id>核对；POST read按原资料/身份读取；POST changes确认或撤销、GET operations/<id>核对原结果。清单、预览及回执DTO不含原文件字节、私有会话或使用证明。普通读取/审批与设备凭据执行仍各用原通道。

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
