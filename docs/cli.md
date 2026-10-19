# 通用 CLI 申请与等待

> 2026-10-19：开发分支的新CLI默认凭据协议v2，需要服务明确支持credential-use-reuse.v1；#33的Windows功能验收通过，生产入口已启用v2。当前已交付0.4.0+8预览仍为v1，须整包更新应用、CLI和worker后才能使用新版流程。普通附件仍待#37/#38；本机焦点填充已接Windows构建绑定入口与QA整包，正向GUI/内置浏览器仍待#35验收。真实Codex、通知和干净环境门槛继续保留。

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

## 凭据使用（Windows开发分支，协议v2）

先查询`capabilities`；新版CLI的request-use/run-use/operation-status省略协议版本时按2处理，必须共同支持`credential-use-reuse.v1`。旧服务返回unsupported_capability，不能静默降级或重提单次申请。其他查询可按执行事实返回原版本。旧v1记录与明确的v1调用保留一次尝试，不能升级旧许可；这不是用户的单次/多次模式开关。

字符串接收配置gh_token、文件接收配置ssh_identity/aws_shared_credentials沿用已验证工具版本及严格接收器规则。程序、CLI、worker整包匹配；CLI只在自己创建的子进程中注入值或文件路径，不修改Agent当前shell、全局环境或返回秘密材料。

查询credential-catalog选择相关凭据及固定版本，然后在现有私密会话提交一次申请。以下ID与绝对路径需替换为当前实际结果，普通字段可用readFields同时申请：

```json
{"protocolVersion":2,"command":"request-use","purpose":"查看技能仓库信息","credentials":[{"alias":"github_token","credentialId":"CREDENTIAL_ID","version":1}],"launch":{"receiver":"gh_token","executable":"C:/Program Files/GitHub CLI/gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:/Work/northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

首条launch供用户理解用途。通过原requestId查询status/wait，用户批准不会自动执行。credentialUse.approved及当前state为available时，使用授权固定15/30分钟，期间每个操作独立提交完整launch和唯一operationId，不逐命令再审批；普通字段独立默认8小时，可由用户缩短。复用不续期，新增未批凭据或使用方式需要新申请。

```json
{"protocolVersion":2,"command":"run-use","requestId":"REQUEST_ID","operationId":"repo-check-01","launch":{"receiver":"gh_token","executable":"C:/Program Files/GitHub CLI/gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:/Work/northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
{"command":"execution-status","executionId":"EXECUTION_ID"}
{"command":"execution-output","executionId":"EXECUTION_ID","cursor":0,"limit":16}
```

同一私密会话的同operationId和完整内容重试只返回原事实；换内容为operation_conflict，不会再次交付材料。响应丢失时复制原run-use对象，仅把command改为operation-status，按原ID/原内容查询。unknown不代表未运行，不自动改ID重做。明确失败只属于本次操作，不消费整个授权；修正并核查原因后，可在仍有效的批准范围内明确提交新ID和新命令。

accepted只表示登记操作；根据processStarted、executionState、实际exitCode和独立cleanupState判断运行结果。每次执行冻结自己的程序身份/参数/目录/注入计划，材料及Job独立。撤销、到期、轮换、停用、删除、会话结束及重启拒绝新操作，已运行任务继续；某任务退出只清理自己的材料。cleanup-use按原executionId重试清理，不能当作重新运行。重启保留未知结果但不恢复许可。

Typed env/argv对象才产生注入：GH_TOKEN接收`{"secret":"alias"}`；SSH的-i后独立参数`{"file":"alias"}`接收临时路径；AWS_SHARED_CREDENTIALS_FILE接收`{"file":"alias"}`路径。普通文本{{SSH_KEY_FILE}}不替换。通用cookie文件、普通附件领取和浏览器密码填充不由这些接收器自动支持。

输出在执行宿主内存有界保留、base64按流/序号分页；已知凭据直接回显在保留前遮挡，但不保证编码、截图或外部文件安全。输出不可用不代表执行失败。通用CLI需保持进程接续；Codex由持续宿主跨单命令进程保管，结束/缓存淘汰后不恢复输出。CLI的stdin EOF不结束共享会话。

完整协议、兼容和边界见[协议v2](design/runtime-protocol-v2.md)，Agent流程见[随包凭据使用说明](../integrations/codex/skills/agent-info-access/references/credential-use.md)。

## 开发中的本机焦点填充（#35）

核心/CLI、Flutter及Windows构建绑定入口已接通，见[整包检查点](development/issue35-focused-fill-bundle.md)。源码/QA包按束校验条件启用；用户原0.4.0+8包未启用，正向GUI及内置浏览器仍待验收。必须同时协商协议2、`credential-use-reuse.v1`和`credential-focused-fill.v1`，未提供时停止，不退回返回密码原文。需要私密会话，不能只凭请求ID使用。

若另有`credential-focused-target.v1`，`{"protocolVersion":2,"command":"focus-target"}`可观察本机当前密码目标，仅返回ready/refused和就绪应用路径/SHA；不提供值、窗口句柄或PID，不预留焦点、不审批、不输入。批准后必须重新点击空密码框。详见[原生合同与当前验证范围](design/windows-focused-fill-native.md)。

`request-use`提交一个字符串凭据引用和`fill`（应用绝对路径/字节摘要、仅供判断的网址），不同时提供`launch`，也不附带普通字段授权。请求格式见[填充合同](design/local-focused-fill-contract.md)。批准固定凭据版本、应用、方式及15/30分钟期限；批准不输入。Agent准备空密码框、重新点击目标，再后台调用：

```json
{"protocolVersion":2,"command":"fill-use","requestId":"REQUEST_ID","operationId":"password-fill-01"}
{"protocolVersion":2,"command":"fill-status","requestId":"REQUEST_ID","operationId":"password-fill-01"}
```

省略版本也按2处理。`fill-use`只登记/请求该次操作，宿主保管秘密；CLI没有输入值、窗口句柄、秘密文件路径或命令模板参数。`fill-status`仅查询；相同操作ID返回原记录，不再发送。响应丢失用原requestId/operationId查询，不改ID自动重试。

结果区分checking、sent、refused、partial、unknown；sent仅表示Windows接受输入，不等于完整接收或登录成功。填充不返回命令退出码/文件清理或秘密。partial/unknown保留原事实并停止同会话的新操作，不能换另一已批申请绕过；用户检查目标并通过所有者恢复入口确认后才可明确重做，不续期、不清空、不重放旧操作。仍在执行时返回busy且不排队。保持密码遮挡，不读取或显示明文，不自动提交登录。
