# 通用 CLI 申请与等待

App 根据当前本地或服务器模式自动准备并复用受限设备配置。通用入口 `info` 默认发现当前连接，`info --connection <配置路径>` 可固定独立目标；隔离配置可设置 `CHIYO_CONNECTION_DIRECTORY`，接入入口见 [AI 与 CLI 接入](../integrations/codex/README.md)。Mac / Windows 均使用同版本准备包中的 Skill、`info-codex` 和 `info-codex-hook`。只有受限设备接入凭证进入 CLI，用户管理 Token 留在 App。实际可用能力以 `capabilities` 为准，不按开发分支或旧下载包推测。

远程文字新增和修改提案已接通，沿用以下模板查询和 import/update 命令。每次提交给稳定 operationId，结果不确定时查询原操作；用户在正常 App 预览类型、目录和内容后一次保存整份。App 关闭不停止服务器，重开后可处理待办。文件、密码和密钥仍按各自能力标记接续，不能把材料去掉后改报成功。

远程整理也沿用 `organize-request`、`organize-status`、`organize-tasks`、`organize-metadata`、`organize-submit`：先在 App 批准限定资料，再获取这次任务的分类元数据及版本，最后提交该范围内的分类和标签变动。不能仅凭目录查询改动分类，不能混入未批准资料或字段内容。结果在 App 的录入提案中只读查看；普通重启保留有效范围和原期限，已到期、撤销或聊天结束的任务不会恢复。

## 提交主题和来源

新版 `info` 和 `info-codex` 的申请需要服务具备 `submission-metadata.v1`。`--help` 或 `{"command":"help"}` 可在未连接时查看用法。

所有新申请填写 `purpose`；`import-submit`、`update-submit`、`delete-submit`、`organize-request` 还必须有 `title`。例如“补齐 NAS 应用清单”，而不是只写条数。每次申请的 `agentName` 是实际提交者名称，`externalChatId` 是实际聊天标识；它们只作说明，不能代替私密会话证明。`info-codex` 自动提供 Codex 和当前聊天标识。通用 CLI 在 `session` 提供 `externalChatId`，每次申请提供 `agentName`，也可以单次明确提供聊天标识。

标题、名称、聊天标识各最多200字、不含换行；用途最多2000字。不要将密码、Token、私钥或资料正文放入这些说明。模板例子中的主题和来源都是虚构值，提交时替换为当前任务的信息；具体 `items`／`update` 结构仍从当前插件查询。

缺少或超长时返回 `invalid_request`、`errorCode:invalid_submission_metadata` 和按字段给出的 `fieldErrors`，补齐原意图后再提交。CLI 自动附 `submissionVersion:1`；直接调用新版 API 时也提供该标记，服务端按相同规则核对。旧传输和旧库缺少的字段保留为空，App 使用原用途和聊天说明，不伪填 Agent 名称或历史标题。修订待审内容保留原提案的主题和来源；批准范围和整份保存规则不变。

## 查询完整资料目录

能力查询中的 `information-directory-discovery.v1` 表示支持
`{"command":"directory-list"}`。结果一次返回全部当前目录，含空目录，
`complete:true`、`total` 与 `directories` 明确表示完整结果，不接受分页参数。
每个目录包含稳定 `id`、`parentId`、`version`、完整 `path`、从根开始的
`pathIds` 和从零开始的同级 `order`。同名目录按完整路径和 ID 区分。

联网模式目录数据来自当前服务器；新建、移动、重命名或删除后重新查询即可取得最新结构。
录入建议可复用目录 ID，可发现普通资料和凭据的元数据包含 `directoryId`。
此查询不返回正文、文件内容、凭据材料或待审批资料，不创建整理任务，也不授予写入能力。
目录写入及整理继续按原审批流程。

## 查询当前插件和资料模板

App 运行后发送 `{"command":"plugin-list"}` 或 `{"command":"template-list"}`；后者支持 `packageId`、`offset`、`limit`。选择启用的模板后发送 `{"command":"template-read","templateId":"查询所得ID"}`，按返回的 `definition` 和 `submissionExample` 填写，不能把固定模板列表抄进 Skill。插件安装、更新、启停和移除在下一次查询中生效。没有适合的模板就建议用户补充并暂缓，不自行生成安装插件。

新增通过 `import-submit` 的 `items` 提供 `name`、`description`、`templateId`、`templateVersion`、`templateDigest`、`values`，与用户审批共用原入口。按模板修改仍走 `update-submit`，在 `update` 中提供已有 `itemId`、`baseVersion`、相同三个模板标识和完整 `values`，不要与平面 `changes` 混用。类型和格式不再降为通用文字。

模板变化返回 `template_changed`，停用返回 `template_unavailable`，移除返回 `template_missing`。字段不合格式返回 `validation_failed` 和不含字段值的 `fieldErrors`；核对最新模板后重新提交，不静默换用其他模板。普通资料与凭据的待入库引用已接入，文件新建提案已接入，已有资料的附件修改通过下述 `information-file-update.v1` 能力核对。

## 普通文件新建录入

先核对`information-file-upload.v1`，按`template-read`返回的`fileInput`及`submissionExample`填写。CLI的`attachments[].versions[].filePath`接收用户给定原文件路径，`values`中的声明文件字段填匹配的附件key，`templateField`标明声明字段；新文件必须绑定声明字段，原件有独立用途时建立文件资料并关联，不追加未绑定来源副本。每组用从1开始数的`currentVersion`选择当前原文，并填写`label`与`sourceNote`说明来源。单份文件上限10MiB，原文不会进入Agent的响应或普通字段。

新建文件提案须给稳定`operationId`，不确定时先用`import-status`按此编号核对；CLI另报上传编号时用`import-file-status`查询原文收件情况。提案待审批、已批准待引用与真正入库分别报告。用户可预览待审原文，批准时原文、资料、版本与回执一起保存。已有资料文件修改另核对`information-file-update.v1`，按动态`fileUpdateExamples`走`update-submit`：在`update`中给准确itemId、baseVersion及attachments；新文件绑定templateField所指的声明文件字段，已有附件加版本指定现有文件字段fieldId（包括旧的额外附件）。只补历史时currentVersion为null，原当前选择不变。只补文件可省略templateId和values，无关正文保持；完整模板修改则对已有文件提供`{"retain":true}`，其他values仍完整。修改的稳定operationId可用`update-status`查询，发生冲突要重新核对原资料并审批。

## 登记已准备好的 Codex 运行包

正式个人 Skill 从系统默认的公开 `integration.json` 定位同版本运行包。安装者核对准备好的目录后，可显式运行同包 `info-prepare-codex --register-existing <运行包目录>`。支持交付包的 `template/` 或准备后的 `skills/agent-info-access/`，要求三个程序和完整说明齐全；登记只保存公开路径、大小和摘要，不建立会话、不编辑 Codex 配置，也不授予 hooks 信任。常规准备命令仍只向新目录输出，不自动登记。

Mac 描述位于 `~/Library/Application Support/AgentInfo/codex/integration.json`，Windows 位于 `%LOCALAPPDATA%/AgentInfo/Codex/integration.json`。更新运行包须重新核对和登记，不能把旧描述当作新版已就绪。当前登记与定位的故障检查在 Mac 上运行；未据此宣称 Windows 原生安装验收通过。

## 同批资料与提案引用

新增资料可在 `relations` 中用 `{"kind":"information","itemKey":"条目key"}` 关联同批待审批条目；跨提案加同一会话中已提交的 `proposalId`。`import-status` 返回每条 `key`、审批状态和真正入库后的ID。新回执还给出 `savedLocation: {directoryId, path}`，其中 `path` 为保存时的完整目录名称数组，未分类为 `directoryId:null, path:[]`；这是保存当时的位置，之后移动或改名不回写。旧回执没有这一字段时不推测其历史位置。已批准但有未获批引用时状态为 `approved_awaiting_admission`；被引用内容拒绝后为 `needs_attention`，不是入库成功或自动拒绝。`import-revise` 携带 `proposalId`、当前 `version` 和待修改 `items`（保留原 `key`），修改后要重新审批。

`update-submit` 也支持上述待录入普通资料关联，必须提供目标的 `proposalId`。批准但未具备保存条件时，保留审核结果，原资料不变。`update-status` 返回提案 `version`，以及等待／待处理状态，真正保存后才返回 `result`。`update-revise` 携带 `proposalId`、当前 `version`、修订的 `update`，保留原资料ID，可以更新 `baseVersion`，修订后清除旧批准并重新审批。按模板修改的 `values` 要包含模板所有字段，不能靠省略来清空字段；补充字段保持不变。待审批凭据也遵循整份提案保存规则，具体输入格式从当前动态模板取得。

## 分类名称与整理兼容（0.4.1+13）

新建分类时，`directoryName`／`suggestedDirectory` 是单级根目录名称，不是路径；
禁止 `/` 和反斜杠。要使用已有层级位置，请从获准元数据中选择现有 `directoryId`。
目录同级名称、标签全局名称在去除首尾空白后忽略大小写判重；名称上限仍为200。
旧库中包含斜杠的名称保留原义，不自动拆分；原名不变的移动兼容旧名称，改名按新规则校验。
这些限制不扩大Agent整理权限：仍只能按同一获批任务的最终信息身份及版本提交；
目录／标签删除由用户在 App 操作。使用方式见[整理与查找](usage.md#整理与查找)，目录整批回收见 [ADR0022](adr/0022-recycle-directory-batches.md)。

## Windows 应用状态与正常退出（0.4.0+11起）

独立子命令 `info.exe app status` / `info.exe app quit` 不读取标准输入，不需要信息授权。
默认只定位同一交付目录的 `app/info_desktop.exe`；要退出另一目录的实例，先核对进程路径，
再显式加 `--pid <进程号>`。多实例返回 `ambiguous_target`，不会批量退出。
源代码运行时须指定PID，因为Dart SDK旁边没有同包桌面程序。

```powershell
& 'C:\Tools\AgentInfoManage\cli\info.exe' app status
& 'C:\Tools\AgentInfoManage\cli\info.exe' app quit --timeout-ms 15000
```

正常退出停用所有会话许可、保存结束记录、关闭服务与库，再结束进程。输出为单行JSON，
含 `controlVersion:1`、`status`，定位成功时含 `processId`，不含资料或凭据。
只有核对绑定的进程确已以0退出才返回 `exited`。同包没有实例为 `not_running`，重复调用可用；
`running` / `starting` / `exiting` 是只读状态。以上退出码0。
`shutdown_failed` 表示保存/关闭失败（退出码1），保留窗口和库供修复后再调用退出；
`timeout` 表示期限内未确认结束（退出码75），不能当成功或强杀理由，先查询原实例。
可用 `--timeout-ms 100–60000` 调整等待。
`target_mismatch` / `target_unavailable` / `ambiguous_target` / `control_unavailable` 为75；
`unexpected_exit` 为1；旧版不支持或对应平台没有实现时为69；参数错误为64。
显式PID不存在或不可确认不会伪装成成功；旧版 `unsupported_version` 需按原有托盘入口退出。

入口使用同一本机桌面的Windows消息、程序身份及进程句柄；消息只含目标PID和状态/退出操作。
不向公开HTTP添加用户管理接口，不靠请求编号退出应用，也不是同一Windows用户进程之间的安全沙箱。
运行中的已启动命令仍遵守原有生命周期规则；退出不会擅自杀死它们，材料可能待下次启动核查回收。

## Mac 应用状态与正常退出

Mac 新源码提供对应的 `cli/info app status` / `cli/info app quit`；需要桌面应用与CLI
一起更新，旧预览包仍不支持。命令不读取标准输入，不依赖信息授权，也不申请系统输入
或辅助功能许可。正常退出复用应用的保存、撤销会话、关闭服务/库和原生退出流程。

```sh
'/稳定路径/AgentInfoManage/cli/info' app status
'/稳定路径/AgentInfoManage/cli/info' app quit --timeout-ms 15000
```

只匹配该CLI同包的 `app/info_desktop.app/Contents/MacOS/info_desktop` 规范路径，
同时核对当前用户、PID及内核启动时间。`--pid` 也不能选择另一目录的应用；多实例
不指定PID时返回 `ambiguous_target`。使用源码直接运行CLI时，SDK旁没有同包应用，
因此不能靠指定PID把它变成任意应用的控制器。

输出仍为单行 `controlVersion:1` JSON；`running`、`starting`、`exiting`、`not_running`
退出码0，`startup_failed`、`shutdown_failed`、`unexpected_exit` 为1，`timeout` 和
无法确认身份/通信的结果为75；`unsupported_version` 为69。每次 `quit` 只发一次退出
请求，丢回复或超时后只查询原实例；保存失败后，新的显式CLI调用才重新尝试退出。

Mac 的 `exited` 表示本机私有回执已确认应用完成收尾，并且绑定的内核进程身份已结束，
不表示已取得原生退出码。输出显式保留 `exitCode:null`，不能与Windows进程句柄确认的
退出码0混用。没有收尾回执就消失的进程返回 `unexpected_exit`；不会强杀、重开应用、
修复资料库或自动删除不确定的登记。

私有控制通道仅监听IPv4 loopback的临时端口，登记在当前Mac应用容器的
`Library/Application Support/AgentInfoManage/app-control/`。目录0700、登记0600，
每次启动随机控制证明、单一文件锁和进程身份绑定；只接受状态/退出，没有AgentServer
主人接口，不输出证明、内部地址或资料。它不构成同一系统用户进程间的强安全隔离。
登记、锁及回执不属于可迁移备份。控制登记损坏不会阻止应用正常开库或原生菜单退出。

macOS还可能限制外部CLI对应用容器的访问，未获得访问时返回控制不可用，不放宽容器
保护或自动重新创建登记。当前ad-hoc整包的实际数据访问提示仍待联合验收；不能把
无界面临时目录的检查当作跨容器许可已通过。
[Apple容器数据保护说明](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers)。

这些是源码能力和无界面接收进程的开发检查；最终签名Mac应用及新整包的联合验收仍待。

## 信息申请

> 2026-10-19：开发分支的新CLI默认凭据协议v2，需要服务明确支持credential-use-reuse.v1；#33的Windows功能验收通过，生产入口已启用v2。当前已交付0.4.0+8预览仍为v1，须整包更新应用、CLI和worker后才能使用新版流程。普通附件仍待#37/#38；本机焦点填充已接Windows构建绑定入口与QA整包，正向GUI/内置浏览器仍待#35验收。真实Codex、通知和干净环境门槛继续保留。

CLI 使用标准输入逐行 JSON，标准输出每行一个结果。保持同一个 CLI 进程，授权会话凭据和已领取的访问凭据留在进程内；不要把凭据写入命令参数、日志或聊天。启动入口是 `dart run packages/info_cli/bin/info.dart`，默认连接本机应用端口 47125，可用 `--port` 指定开发端口。

按顺序发送（示例字段仅适用于虚构演示资料，真实字段先查询目录）：

```json
{"command":"catalog"}
{"command":"session","chatLabel":"当前聊天的说明","externalChatId":"example-current-chat"}
{"command":"request","agentName":"Example Agent","operationId":"inspect-host-01","purpose":"检查服务器地址","fields":[{"itemId":"demo-server","fieldId":"host"}]}
```

保存 `request` 返回的 `requestId`。返回值还包括创建时间 `createdAt` 和待审批到期时间 `requestExpiresAt`，均为 UTC。默认待审批 2 小时（设置可选30分钟、1/2/4/8/24小时）；用户可以在桌面设置中调整新请求的有效期，已提交请求的截止时间保持不变。

Mac 新开发源码（#71，尚未交付到当前预览）支持 `information-request-operations.v1`。
新接入应为每个申请意图指定 `operationId`：1–128 个 ASCII 字符，以字母或数字开头，
其余允许字母、数字、`.`、`_`、`:`、`-`。相同私密会话、编号、用途和字段集合的重试返回
原请求和固定截止时间，不重复通知；相同编号换用途/字段返回 `operation_conflict`。
不同编号表示新的明确申请，不按内容自动合并。旧调用可省略编号，但不具备去重/按操作找回能力。
CLI 在发送带编号的请求前检查服务能力，旧服务返回 `unsupported_capability`，不静默降级。

提交后通信中断返回 `request_unknown`，有编号时同时返回原 `operationId`。先查询原操作：

```json
{"command":"request-status","operationId":"inspect-host-01"}
```

查询只返回同一私密会话的原请求状态，不创建请求、不返回会话秘密或访问凭据。
`not_found` 只是当前未找到，不证明之前在途的提交不会稍后到达；不要自动换编号重发。
页面重开或有效会话重连可找回原申请；服务关闭、会话结束或资料库恢复后，旧会话不再有效，
不能凭公开请求/操作编号恢复能力。用户可查看保留的无正文历史，异常中止无法确认的结果仍属未知。

同一开发源码的 `catalog` 支持 `query`、`typeId`、`tagId`、`offset`、`limit`（1–100，默认20），
保留已有 `directoryId` 过滤。返回分页 `items`、`total`、`nextOffset`，以及全部当前标签 `tags`（ID和名称，含尚未使用的标签）；
每项包含 `typeId`、标签名称/归属和字段说明。无布局旧资料的类型为 `generic`。
关键词只搜索公开说明和标签名称，不搜索正文；目录树、资料关系、布局快照、文件原文和密钥不公开。

```json
{"command":"catalog","query":"业务服务器","typeId":"server","tagId":"TAG_ID","offset":0,"limit":20}
```

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

用户可能只批准一部分，也可能改选其他信息项或补选字段。`claim` 返回的 `fields` 才是最终可读范围，不应继续假定原申请范围已全部批准。`expiresAt` 是本次授权固定的 UTC 到期时间；默认从批准时起 2 小时（可选2/4/8/24小时），用户可在批准前调整，重复领取或读取不会延长。`scopeNotice` 明确说明新增信息项或字段需要新申请。上述输出不包含实际访问凭据；凭据仍由 CLI 进程保管。

放弃尚未处理的申请时可显式发送：

```json
{"command":"cancel","requestId":"REQUEST_ID"}
```

桌面上的聊天名称及用途是 agent 自述，不能作为可信身份凭据。CLI 没有批准或拒绝入口。收到拒绝或过期时，agent 不得自动循环重提、自动扩展范围，或将重新提交当作轮询手段。

自动化覆盖核心公开接口、真实 CLI 子进程及 Flutter 无窗口组件；实际宿主事件和系统输入需独立验证。当前任务状态见 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues)。

## 修改提案

`catalog` 的每条信息包含当前 `version`。选择目标及基础版本，通过标准输入提交明确操作：

```json
{"command":"update-submit","agentName":"Example Agent","title":"修正服务器地址","purpose":"更新用户指出的地址变化","update":{"itemId":"ITEM_ID","baseVersion":1,"description":"修订后的公开描述","changes":[{"operation":"correct","fieldId":"FIELD_ID","value":"修正后的值"}]}}
{"command":"update-status","proposalId":"PROPOSAL_ID"}
```

`correct` 仅修正值并保留字段身份；`add` 使用 `field` 对象新增字段；`replace` 使用 `fieldId` 和 `field` 替换业务含义；`remove` 使用 `fieldId` 移除字段。`field` 对象包含 `name`、`description`、`value` 和 `kind`（`structured` 或 `textNote`）。新增和替换使用新字段身份，原授权不会自动包含它们。移除后旧授权永久停止提供该字段，其余获准字段仍可读。`name`、`description` 是可选的信息项公开元数据修改。

提交仅返回 `pending` 和 `proposalId`，不读取当前值、不直接覆盖资料。每次提案最多 200 个操作，单值最多 64000 字符，提案 JSON 最多 240000 UTF-8 字节。相同字段只能出现一个操作；最终信息必须保留至少一个字段。提案状态仅创建它的私密会话可查询，且不返回变更内容、原值或差异。Agent 无预览、确认、拒绝或历史读取入口；需要原值时先申请正常读取授权。

用户在“录入提案”中查看修改前后信息和公开描述，明确确认或拒绝。状态为 `confirmed`、`rejected` 或 `conflicted`；版本冲突不会覆盖当前资料。冲突后根据当前目录版本和用户要求重新准备提案，避免自动重提。用户确认修正后，仍有效的原字段授权可读取最新值。确认操作可安全重试，不会重复增加版本或历史。

## 凭据使用（协议v2）

先查询`capabilities`；新版CLI的request-use/run-use/operation-status省略协议版本时按2处理，必须共同支持`credential-use-reuse.v1`。旧服务返回unsupported_capability，不能静默降级或重提单次申请。其他查询可按执行事实返回原版本。旧v1记录与明确的v1调用保留一次尝试，不能升级旧许可；这不是用户的单次/多次模式开关。

字符串接收配置gh_token、文件接收配置ssh_identity/aws_shared_credentials沿用已验证工具版本及严格接收器规则。程序、CLI、worker整包匹配；CLI只在自己创建的子进程中注入值或文件路径，不修改Agent当前shell、全局环境或返回秘密材料。

查询credential-catalog选择相关凭据及固定版本，然后在现有私密会话提交一次申请。以下ID与绝对路径需替换为当前实际结果，普通字段可用readFields同时申请：

```json
{"protocolVersion":2,"command":"request-use","purpose":"查看技能仓库信息","credentials":[{"alias":"github_token","credentialId":"CREDENTIAL_ID","version":1}],"launch":{"receiver":"gh_token","executable":"C:/Program Files/GitHub CLI/gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:/Work/northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

首条launch供用户理解用途。通过原requestId查询status/wait，用户批准不会自动执行。credentialUse.approved及当前state为available时，使用授权默认2小时，可选2/4/8/24小时；SSH还可由用户选择“本聊天内不限时”，期间每个操作独立提交完整launch和唯一operationId，不逐命令再审批；普通字段独立默认2小时，可选2/4/8/24小时。复用不续期，新增未批凭据或使用方式需要新申请。

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

## 平台相关的本机焦点填充

本功能按平台及实际运行包能力提供，不因源码中有接口就默认启用。必须同时协商协议2、`credential-use-reuse.v1`和`credential-focused-fill.v1`，未提供时停止，不退回返回密码原文。需要私密会话，不能只凭请求ID使用。实际输入与拒绝规则见下列原生合同。

若另有`credential-focused-target.v1`，`{"protocolVersion":2,"command":"focus-target"}`可观察本机当前密码目标，仅返回ready/refused和就绪应用路径/SHA；不提供值、窗口句柄或PID，不预留焦点、不审批、不输入。批准后必须重新点击空密码框。详见[原生合同与当前验证范围](design/windows-focused-fill-native.md)。

`request-use`提交一个字符串凭据引用和`fill`（应用绝对路径/字节摘要、仅供判断的网址），不同时提供`launch`，也不附带普通字段授权。请求格式见[填充合同](design/local-focused-fill-contract.md)。批准固定凭据版本、应用、方式及用户选择的2/4/8/24小时期限；批准不输入。Agent准备空密码框、重新点击目标，再后台调用：

```json
{"protocolVersion":2,"command":"fill-use","requestId":"REQUEST_ID","operationId":"password-fill-01"}
{"protocolVersion":2,"command":"fill-status","requestId":"REQUEST_ID","operationId":"password-fill-01"}
```

省略版本也按2处理。`fill-use`只登记/请求该次操作，宿主保管秘密；CLI没有输入值、窗口句柄、秘密文件路径或命令模板参数。`fill-status`仅查询；相同操作ID返回原记录，不再发送。响应丢失用原requestId/operationId查询，不改ID自动重试。

结果区分checking、sent、refused、partial、unknown；sent仅表示Windows接受输入，不等于完整接收或登录成功。填充不返回命令退出码/文件清理或秘密。partial/unknown保留原事实并停止同会话的新操作，不能换另一已批申请绕过；用户检查目标并通过所有者恢复入口确认后才可明确重做，不续期、不清空、不重放旧操作。仍在执行时返回busy且不排队。保持密码遮挡，不读取或显示明文，不自动提交登录。
