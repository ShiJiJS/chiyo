# 通用 CLI 申请与等待

> 当前开发分支已实现 Windows 字符串凭据的一次启动流程，见下方“凭据使用”。
> 文件接收、Codex 生命周期整合和完整凭据备份仍分别由 #29–#31 继续；不要将原型占位符直接交给 shell。

CLI 使用标准输入逐行 JSON，标准输出每行一个结果。保持同一个 CLI 进程，授权会话凭据和已领取的访问凭据留在进程内；不要把凭据写入命令参数、日志或聊天。启动入口是 `dart run packages/info_cli/bin/info.dart`，默认连接本机应用端口 47125，可用 `--port` 指定开发端口。

按顺序发送（示例字段仅适用于虚构演示资料，真实字段先查询目录）：

```json
{"command":"catalog"}
{"command":"session","chatLabel":"当前聊天的说明"}
{"command":"request","purpose":"检查服务器地址","fields":[{"itemId":"demo-server","fieldId":"host"}]}
```

保存 `request` 返回的 `requestId`。返回值还包括创建时间 `createdAt` 和待审批到期时间 `requestExpiresAt`，均为 UTC。默认待审批 30 分钟；用户可以在桌面设置中调整新请求的有效期，已提交请求的截止时间保持不变。

以下示例的 `REQUEST_ID` 替换为原来的请求标识：

```json
{"command":"status","requestId":"REQUEST_ID"}
{"command":"wait","requestId":"REQUEST_ID","timeoutMs":30000}
```

`wait` 每次只查询原请求，默认等待 30 秒，`timeoutMs` 可为 0–300000 毫秒。0 表示只查询一次。单次通信额外受 5 秒网络超时限制，所以最坏返回时间为等待时长加 5 秒。返回 `pending` 且 `waitTimedOut: true` 表示这次等待结束，**不表示申请取消或过期**。可以先做不依赖资料的工作，再使用原 `requestId` 查询或等待。查询不产生新申请或新的待办通知事件。

| status | 下一步 |
| --- | --- |
| pending | 仍待用户决定；稍后查询同一请求。 |
| approved | 使用 `claim` 领取用户批准范围，然后 `read`。 |
| denied | 用户已拒绝。停止等待，不自动重新提交。 |
| expired | 待审批或授权已到期。不自动重新提交；确有需要时向用户说明。 |
| cancelled | 申请已取消，不再批准。 |
| revoked | 用户已撤销授权，停止读取。 |
| unauthorized | 当前会话或授权不允许这次访问，不能靠换请求标识绕过。 |
| service_unavailable | 服务不可用；检查应用状态。不要用重提申请处理网络错误。 |
| invalid_request | 输入不合法或操作与终态冲突；检查原请求状态。 |

```json
{"command":"claim","requestId":"REQUEST_ID"}
{"command":"read","requestId":"REQUEST_ID","itemId":"demo-server","fieldId":"host"}
```

授权仅包含用户批准时选中的字段，新增信息或字段需要另行申请。已经批准的请求不能再取消；如需停止已有访问，由用户撤销授权。

用户可能只批准一部分，也可能改选其他信息项或补选字段。`claim` 返回的 `fields` 才是最终可读范围，不应继续假定原申请范围已全部批准。`expiresAt` 是本次授权固定的 UTC 到期时间；默认从批准时起 8 小时，用户可在批准前调整，重复领取或读取不会延长。`scopeNotice` 明确说明新增信息项或字段需要新申请。上述输出不包含实际访问凭据；凭据仍由 CLI 进程保管。

放弃尚未处理的申请时可显式发送：

```json
{"command":"cancel","requestId":"REQUEST_ID"}
```

桌面上的聊天名称及用途是 agent 自述，不能作为可信身份凭据。CLI 没有批准或拒绝入口。收到拒绝或过期时，agent 不得自动循环重提、自动扩展范围，或将重新提交当作轮询手段。

自动化已覆盖核心公开接口、真实 CLI 子进程及 Flutter 无窗口组件测试。真实桌面手动执行“等待超时后批准，再查询原结果”的验收仍需用户配合；本任务没有操作用户桌面。

## 修改提案

`catalog` 的每条信息包含当前 `version`。选择目标及基础版本，通过标准输入提交明确操作：

```json
{"command":"update-submit","update":{"itemId":"ITEM_ID","baseVersion":1,"description":"修订后的公开描述","changes":[{"operation":"correct","fieldId":"FIELD_ID","value":"修正后的值"}]}}
{"command":"update-status","proposalId":"PROPOSAL_ID"}
```

`correct` 仅修正值并保留字段身份；`add` 使用 `field` 对象新增字段；`replace` 使用 `fieldId` 和 `field` 替换业务含义；`remove` 使用 `fieldId` 移除字段。`field` 对象包含 `name`、`description`、`value` 和 `kind`（`structured` 或 `textNote`）。新增和替换使用新字段身份，原授权不会自动包含它们。移除后旧授权永久停止提供该字段，其余获准字段仍可读。`name`、`description` 是可选的信息项公开元数据修改。

提交仅返回 `pending` 和 `proposalId`，不读取当前值、不直接覆盖资料。每次提案最多 200 个操作，单值最多 64000 字符，提案 JSON 最多 240000 UTF-8 字节。相同字段只能出现一个操作；最终信息必须保留至少一个字段。提案状态仅创建它的私密会话可查询，且不返回变更内容、原值或差异。Agent 无预览、确认、拒绝或历史读取入口；需要原值时先申请正常读取授权。

用户在“录入提案”中查看修改前后信息和公开描述，明确确认或拒绝。状态为 `confirmed`、`rejected` 或 `conflicted`；版本冲突不会覆盖当前资料。冲突后根据当前目录版本和用户要求重新准备提案，避免自动重提。用户确认修正后，仍有效的原字段授权可读取最新值。确认操作可安全重试，不会重复增加版本或历史。

## 凭据使用（Windows 开发分支）

当前支持字符串凭据接收配置 `gh_token`，版本探测只接受已验证的 GitHub CLI 2.102.0。其他平台的默认执行器在占用前拒绝；SSH/AWS 文件交付尚待 #29。正式二进制必须将 `info-runtime-worker.exe` 与 `info.exe` 放在同一目录，Codex bundle 准备器会一起复制。原有已安装 CLI 不会自动获得新增命令。

先查询 `{"command":"credential-catalog"}`，并在私密授权会话中提交完整计划。下面的 ID、程序和工作目录必须换成当前目录结果及本机实际绝对路径，Token 原文不写入输入：

```json
{"command":"request-use","purpose":"查看技能仓库信息","credentials":[{"alias":"github_token","credentialId":"CREDENTIAL_ID","version":1}],"launch":{"receiver":"gh_token","executable":"C:\\Program Files\\GitHub CLI\\gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:\\Work\\northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

保存返回的 `requestId`，用原有 `status` / `wait` 等待用户在桌面决定；可附带 `readFields`，字段与凭据的批准范围、期限和失效独立。只有 `decision.credentialUse.approved:true` 且许可仍有效时才发送：

```json
{"command":"run-use","requestId":"REQUEST_ID"}
{"command":"execution-status","executionId":"EXECUTION_ID"}
{"command":"execution-output","executionId":"EXECUTION_ID","cursor":0,"limit":16}
```

`run-use` 只引用获批计划，不接受修改后的命令。返回 `accepted` 表示尝试已占用、正在准备，不能当作已创建进程或执行成功；随后根据 `execution-status` 的 `processStarted`、`executionState`、`exitCode` 和独立 `cleanupState` 判断。准备/启动失败也消耗一次尝试；响应丢失先查询原请求取得执行编号，不能自动重跑或重提。程序位置、参数、工作目录、凭据版本在提交后固定；普通文本中的占位符不会替换。

输出仅保留在启动该任务的 CLI 内存，按块返回 base64、流标签和全局接收序号，最多首4MiB，超限后继续排空。其他 CLI 或进程关闭后输出不可恢复；外部输出可能含秘密，勿写入聊天、审计或历史。stdin EOF 等待已启动任务结束，但不结束共享授权会话。重启只保留非秘密事实，无法确认的执行显示 `unknown`，不恢复启动能力。Token 不创建凭据文件，清理为 `not_needed`。完整约束、错误码和边界见[协议 v1](design/runtime-protocol-v1.md)。
