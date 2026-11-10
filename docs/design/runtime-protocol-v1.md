# 凭据运行协议 v1（D0 冻结）

2026-10-17冻结，后续已落地Windows一次启动流程；macOS执行适配未完成。本文保留v1契约，命令使用见[逐行JSON CLI](../cli.md)。2026-10-18确认的[复用授权、普通附件及焦点填充](windows-credential-and-file-update.md)需要新增协议/能力协商，由#33/#30冻结；本文件不声称这些新接口已可用，也不把v1一次性证明升级为多次授权。执行归属见ADR0009，后续替代范围见ADR0010–0012。

## 传输与职责

通用 CLI stdin 每行一个 UTF-8 JSON 对象，stdout 每条输入恰好一个 JSON 对象加换行。所有新响应有 `protocolVersion:1`。一次输入最多 262144 UTF-8 字节（含换行），超限整行拒绝；既有命令更小的限制保持不变。未知属性、错类型、重复 JSON key、非整数数值和非有限数值均拒绝；解析层不能先丢弃重复 key 再验证。UTC 时间采用 RFC3339 毫秒和 `Z`；标识是不可推导授权的 opaque string，1–128 ASCII 字符。

服务负责批准、原子占用许可和持久化非秘密执行/清理元数据；**CLI 才是执行器**。`run-use` 经 AgentClient 内部带会话证明的私有通道领取执行材料，由 CLI 的本机执行任务直接使用进程 API 启动，不经 shell。Windows 实现使用同包内部 worker，先加入独立 Job 再创建获批程序，使 CLI 退出后仍可等待进程树并排空输出；worker 不得到本软件会话证明或执行报告 capability。通用 JSON 响应、目录和桌面历史都不含外部秘密、临时授权证明、受管材料内容或临时绝对路径。私有 HTTP 不能误用为普通 CLI command 的透传响应。

CLI 不把 JSON stdin 接给子进程；首版关闭子进程 stdin。不提供 PTY、交互输入、shell 管道、浏览器密码填充、远程执行器或多凭据组合。`run-use` 不等待程序退出：原子占用后立即返回 `executionId`，本地执行任务异步准备和启动；后续逐行输入仍能查询和完成其他工作。

## 可发现目录与申请

`{"command":"credential-catalog","cursor":null,"limit":50}`：不要求内容授权，只列用户显式允许发现的凭据。`cursor` 为 null 或 opaque string，`limit` 为 1–100 整数；按 `name` 的 NFC 排序键再按 ID 稳定排序。返回 `status:ok, credentials:[{credentialId,name,publicPurpose,form,version,availability}], nextCursor`；`form` 仅 `string|file`，`availability` 仅 `available|disabled|expired`。回收站、私有备注、导入源路径和已退休版本不列出。目录不是网络公开，不根据公开聊天 ID 放大范围。

```json
{
  "command":"request-use",
  "purpose":"检查测试服务器连通性",
  "credentials":[{"alias":"ssh_key","credentialId":"cred-ssh-test","version":2}],
  "launch":{
    "receiver":"ssh_identity",
    "executable":"C:\\Windows\\System32\\OpenSSH\\ssh.exe",
    "argv":["-T","-o","BatchMode=yes","-i",{"file":"ssh_key"},"-p","2222","developer@test.beichen.example","/usr/bin/true"],
    "cwd":"C:\\Work\\northstar",
    "env":{}
  },
  "readFields":[{"itemId":"server-test","fieldId":"host"}]
}
```

申请必须在已建立的私密会话中。`credentials` 恰好 1 项；alias 正则 `[A-Za-z_][A-Za-z0-9_]{0,63}`、version 为 1–2147483647 整数；只允许当前可用且可发现版本。`purpose` 1–2000 字符；`readFields` 可省略，默认 `[]`，最多 200 项且复合身份不能重复。普通字段不能选择到托管秘密。信息关联只辅助发现，不获得许可。

`launch` 恰含 `receiver,executable,argv,cwd,env`。`argv` 最多 128 项，每个 literal 至多 8192 Unicode 字符；`env` 最多 32 项。可执行文件/目录在客户端本机解析为规范绝对路径，最多 4096 字符；原始输入必须已经绝对，不以 PATH 猜程序。NUL 一律拒绝；Windows 不接受 drive-relative/UNC 网络可执行文件，首版只运行本机可读文件。路径存在性/可执行性在申请与运行时再次核对；环境变量名 `[A-Za-z_][A-Za-z0-9_]{0,63}`。

argv 项只能是字符串或恰含 `file` 的对象；env 值只能是字符串、恰含 `file` 或恰含 `secret` 的对象。字符串不做替换，`"{{file:x}}"` 是字面文本。文件对象须引用 file 凭据，secret 对象须引用 string 凭据；至少有一个引用，别名完全匹配。Windows 环境变量按不区分大小写检测冲突；所有平台拒绝大小写折叠后重复 key。一个别名可重复使用，在同一执行中得到同一材料；不允许拼接引用或让用户指定受管文件路径。字符串原文不能放 argv。

有效申请返回：

```json
{"protocolVersion":1,"status":"pending","requestId":"use-024","createdAt":"2026-10-17T06:40:00.000Z","requestExpiresAt":"2026-10-17T07:10:00.000Z","planHash":"sha256:…"}
```

`planHash` 由服务器对解析后规范计划计算，不由 Agent 提交；对象 key 按 Unicode 码点排序、数组顺序不变、UTF-8 无空白 JSON 再 SHA-256（不含申请用途/审批结果/秘密）。待审批期限沿用设置，默认30分钟。申请建立后凭据 ID/版本、exe、argv、cwd、env、receiver 不可修改；新计划必须新申请，重试查询不能生成新请求。

## 接收配置与基础环境

首版仅三个明确接收配置，其他 `receiver` 返回 `unsupported_receiver`。受控自动测试通过依赖注入启动测试程序，不开放一个绕过检查的生产 test receiver。

| receiver | 凭据/绑定 | 固定约束与账号来源 |
| --- | --- | --- |
| `gh_token` | string；env `GH_TOKEN:{secret:alias}` | 真实 gh 程序；`GH_HOST=github.com`、`GH_PROMPT_DISABLED=1`，每次私有空 `GH_CONFIG_DIR`；支持普通内建命令 `repo,issue,pr,api,gist,release,workflow,run,search,status` 的固定完整 argv，包括写操作和显式 API method；全部参数/输入文件引用展示后批准。拒绝 `--hostname`、`--web`、`-w`、`auth,config,alias,extension`、命令名以 `!` 开头、未知顶层命令和shell入口。`api` 仅 github.com 的相对路径端点（不接受 URL），method可为 GET/POST/PUT/PATCH/DELETE，精确展示并纳入计划。不继承其他 GitHub 认证变量或用户 config。 |
| `ssh_identity` | file；argv `-i,{file:alias}` | 真正 ssh；要求 `-T`、`BatchMode=yes`、一个固定远端非交互命令，拒绝本地转发/ProxyCommand/LocalCommand/配置重写/交互/多个身份/ssh-agent；执行器附加 `-F` 指向受管空配置、`IdentitiesOnly=yes`、`IdentityAgent=none`、`PasswordAuthentication=no`、`KbdInteractiveAuthentication=no`、`StrictHostKeyChecking=yes`，受管 known_hosts 从用户显式选定的已确认主机快照复制。未知主机失败，不关闭验证、不自动信任。全部附加参数在批准前作为 effective argv 展示并纳入 planHash。 |
| `aws_shared_credentials` | file；env `AWS_SHARED_CREDENTIALS_FILE:{file:alias}` | 真正 AWS CLI v2；支持固定完整 argv 的非交互服务/操作命令及读写，要求显式 region，profile为 `default`。`sts get-caller-identity`是验收例，不是唯一允许操作。拒绝 configure/sso/login、其他profile、无签名调用、交互提示和额外配置/认证来源；自定义 endpoint 仅接受显式计划中的 HTTPS 或本机回环HTTP，不接受 URL 内认证信息。`AWS_CONFIG_FILE` 指向受管空配置、`AWS_EC2_METADATA_DISABLED=true`、`AWS_PAGER=""`、禁用自动提示，不继承 `AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN/AWS_PROFILE`；受管配置不含 `credential_process`、SSO 或 role chaining。只使用受管文件中的静态 default 凭据。 |

这些限制定义经验证的接收配置，不能以程序名相同宣称排除了任意恶意二进制或同用户进程。接收配置隔离的是认证来源，具体业务读写由完整命令审批决定，不能把验收用例误实现为只读或单一操作白名单。exe 需要规范路径并在批准时记录文件大小、修改时间与 SHA-256；启动前重新核对，变化返回 `executable_changed`，消耗本次尝试并要求新申请。执行器附加的配置路径使用类型化内部 material 引用，在 UI 显示“空配置/已确认主机快照”；不能偷偷增加未展示的网络或命令参数。SSH known_hosts 未准备好时在申请阶段返回 `receiver_not_ready` 并指向桌面配置入口。

不继承父进程环境。Windows 基础仅 `SystemRoot,WINDIR,COMSPEC`（供 DLL/工具定位，不允许 shell 接收配置）、受控 `TEMP/TMP`、`PATH=<SystemRoot>\\System32;<exe目录>`，并由执行器把 `ProgramData` 设置为本次私有空目录，不继承系统共享目录；Unix 仅 `PATH=/usr/bin:/bin`、受控 `TMPDIR`、`LANG=C.UTF-8`。HOME/USERPROFILE/APPDATA/LOCALAPPDATA/XDG_CONFIG_HOME 指向每次私有空配置目录。应用会话、grants、Git、SSH、云账号、代理认证等其他变量一律不继承。显式 env 中不能覆盖配置隔离变量（包括 `ProgramData`）或注入 `PATH,COMSPEC,LD_PRELOAD,DYLD_*,PYTHONPATH,NODE_OPTIONS` 等程序加载控制；接收配置仅允许表中认证变量和已列出的非秘密常量。无法核实当前工具版本的账号优先级时返回 `unsupported_tool_version`，不能用原用户环境重试。

2026-10-17 接收预检修订：本机 Windows OpenSSH 9.5p2 在缺少 `ProgramData` 时，连 `-V` 也退出255且没有可用标准错误；设置为本次空目录即可初始化。该变量是执行器生成的隔离配置位置，不是增加可继承认证来源。SSH 同时显式设置 `GlobalKnownHostsFile` 为受管空文件，`UserKnownHostsFile` 为已确认快照，两项均作为内部类型化材料纳入 effective argv 与 planHash；不能只隔离用户 known_hosts 而遗漏全局文件。依据及真实工具预检边界见[运行工具预检](https://github.com/ShiJiJS/chiyo/blob/46ff2a9ba5bda130c88f9aac9beef72eb586e781/docs/development/runtime-receiver-preflight.md)。

同轮 gh 预检发现：空 `GH_CONFIG_DIR` 不保证没有系统 keyring 认证。`gh_token` 执行器在私有材料准备后、启动前必须确认 `GH_TOKEN` 的非空值恰来自本次获批字符串；缺失、空值或绑定错误一律准备失败且不启动，不能通过不设置该变量让 gh 自行选账号。申请层和私有材料层均核对，测试覆盖“空 Token 时未创建进程”。真实工具负向验收始终带非空合成 Token，预期401；缺 Token 的对照只在受控程序/注入测试中执行，不再让真实 gh 查询用户已有账号。

## 决定、领取与一次启动

桌面决定在一个事务中记录请求终态及两个独立许可。`status` / `wait` 沿用请求 ID 和私密会话，新增 `approved|partially_approved` 响应：

```json
{"protocolVersion":1,"status":"partially_approved","requestId":"use-024","decision":{"credentialUse":{"approved":false},"fieldRead":{"approved":true,"fields":[{"itemId":"server-test","fieldId":"host"}],"expiresAt":"2026-10-17T06:55:00.000Z"}},"planHash":"sha256:…"}
```

若 `credentialUse.approved:true`，还包含 `credentialId,version,expiresAt,maxAttempts:1,attemptsConsumed:0`。两项均未批准只允许 `denied`，不能返回部分批准。组合字段期限默认跟随15/30分钟启动窗口，两个精确到期时间分别显示；独立字段申请仍默认8小时。`claim` 对组合申请只领取实际批准的 fieldRead，响应沿用既有 fields/expiresAt；不批准字段返回 `scope_not_approved`。`read` 不改变使用额度；准备/启动失败不撤销字段许可。

`decision.credentialUse.state` 表示当前使用许可：`not_approved|available|consumed|revoked|expired|version_invalidated`。`approved`保留当时决定，撤销/到期后不会改写成“过去未批准”；新启动还须当前state为available并由Core再次核对。`partially_approved`不能单独说明哪一项获准。

`{"command":"run-use","requestId":"use-024"}` 恰含这两个字段，不接受新 launch/version/env。私密会话的内部请求先事务核对请求已批准、会话活跃、未到期/撤销、当前凭据版本可用和计划完整，再将一次尝试从 available 改 consumed，创建 execution。原子占用和执行记录任一审计写入失败均回滚，返回 `audit_unavailable`，不交付秘密。成功响应：

```json
{"protocolVersion":1,"status":"accepted","requestId":"use-024","executionId":"exec-024","attemptConsumed":true,"processStarted":false,"executionState":"preparing"}
```

占用之前被拒绝时 `attemptConsumed:false`，不创建 execution；额度已占用的重放返回 `attempt_consumed` 和同会话可见原 executionId，绝不重新交付。占用之后准备失败、私有领取失败、exe改变或启动失败都消耗本次尝试，由 execution记录失败。网络响应丢失时先 status 或 execution-status 查询；不得自动重新申请。没有私密会话的请求编号、Credential ID、executionId 都不能领取秘密。

### 内部私有领取边界（不属于通用 JSON CLI）

AgentClient 经本机 loopback `POST /credential-use/consume` 发送 `sessionSecret,requestId`，服务原子占用并返回 `executionId,executionCapability,approvedPlan,credentialMaterial`。材料仅含恰好一个已批版本，字符串原文或 base64 文件字节；HTTP 原始响应不得返回给 execute() 调用者、stdout、debug logger 或异常消息。服务监听沿用现有本机服务，仍需私密证明，不凭来源IP授权；库密钥不交给CLI。

默认Windows执行器还发送`supervisorPid,supervisorCreatedAt`成对私有字段；Core核对实际存活身份，在占用事务中生成并保存随机私有Job名，私有材料DTO携带该Job名。worker加入Job后等待，宿主持执行capability向`/credential-use/worker/register`提交`executionId,executionCapability,workerPid,workerCreatedAt`；Core核对原宿主仍存活、worker实际身份及Job成员关系并保存后才放行启动。确认前断开不启动。登记仅进私有存储，公开状态和备份不带PID/创建身份/Job名；参见ADR0009。

CLI 在受管目录建立执行日志（只有executionId、文件身份、进程身份、清理状态；无原文/证明），使用 `POST /credential-use/execution/report` 持 `executionCapability` 报告准备/启动/退出/清理状态。capability 只能更新这个执行的允许状态，不能再次领取或启动其他执行；结束会话/撤销后可继续上报已启动执行的退出与清理，不因此恢复普通访问。服务核对状态单调、子进程身份与受管文件身份，不接受任意路径删除指令。内部 `/credential-use/execution/status` 使用会话证明查询所属执行；桌面 owner API 可读全部非秘密记录。接口各自输入输出应有专门 DTO；不能把 credentials/material 混入通用 Map 后靠 remove() 黑名单过滤。

## 查询、输出与清理

`{"command":"execution-status","executionId":"exec-024"}` 只在所属私密会话中，服务可返回已结束会话关联的历史事实但不给恢复许可；重新打开同名聊天不是原会话。返回字段固定：

```json
{"protocolVersion":1,"status":"ok","executionId":"exec-024","requestId":"use-024","executionState":"exited","attemptConsumed":true,"processStarted":true,"exitCode":0,"errorCode":null,"startedAt":"2026-10-17T06:41:00.000Z","finishedAt":"2026-10-17T06:41:02.000Z","cleanupState":"complete","outputAvailable":true,"outputTruncated":false}
```

所有时间和 exitCode 在未知/未发生时为 null。`executionState`: `preparing|running|exited|prepare_failed|start_failed|unknown`；exited 用 exitCode区分成功/失败。`cleanupState`: `not_needed|pending|complete|failed|needs_check`。`processStarted` 只有执行器收到 OS 创建成功事实才为true。请求状态、使用许可、执行和清理四个维度分开；文件清理失败不能把非零退出改为成功，Token 使用是 not_needed，不能画成“SSH文件已清理”。

备份格式5恢复的Owner历史可附可选UTC时间`restoredAt`，只说明这份事实何时恢复；没有原私密会话/能力，Agent不能据编号领取或重新启动。原preparing/running事实恢复为unknown，不补造退出码或结束时间；本机不恢复原设备运行材料、进程身份或输出。普通当前运行响应不因此新增必填字段，申请输入schema保持不变。

`{"command":"execution-output","executionId":"exec-024","cursor":0,"limit":16}`：cursor为下一个 chunk序号（0起），limit1–16，默认16。仅查询当前 CLI 内存缓冲，不把输出传回服务或写库；其他CLI进程即使获准查询历史也返回 `output_unavailable`。响应：

```json
{"protocolVersion":1,"status":"ok","executionId":"exec-024","chunks":[{"seq":0,"stream":"stdout","dataBase64":"b2sK"}],"nextCursor":1,"hasMore":false,"outputComplete":true,"outputTruncated":false}
```

每块最多4096原始字节，stdout/stderr带独立 stream标签，seq按CLI接收顺序全局递增，不能承诺跨流真实时间全序。每执行总共保留首4MiB原始字节；超出后继续排空管道但丢弃后续输出，`outputTruncated:true`，避免子进程卡住；最多保留16个执行的缓冲（退出超过30分钟或CLI关闭即丢弃，先清理最早结束项，不驱逐运行中项；16个仍活跃时拒绝新运行 `execution_capacity`，占用前拒绝）。输出是外部不可信数据，可能含秘密，不承诺变形泄漏打码；UI默认不展开，不进入历史/审计/备份，不在自动截图/测试日志输出真实材料。`outputComplete`在管道关闭时true，退出结果未知不能仅由有输出推定成功。

`{"command":"cleanup-use","executionId":"exec-024"}` 只重试已登记材料清理，绝不执行命令。服务与执行器核对同会话/执行身份，返回 `status:ok,executionId,cleanupState`；仍有活动身份或路径不匹配时 `cleanup_busy|cleanup_identity_mismatch`，保留登记并给owner操作指引。没有文件时返回 not_needed。文件owner-only权限（Windows仅当前用户及必要系统主体；Unix0600目录0700），拒绝 symlink/reparse point；相同别名复用同一副本。退出后等待受管进程树确定结束再清理，不把父进程退出等于后代都结束。不能确定后代身份时 needs_check，保留失败事实，禁止盲删用户文件。

CLI stdin EOF：停止接收新命令，保持执行监护和清理直到已启动受管进程树结束；**不结束共享授权会话**，普通CLI退出不等于Codex聊天结束。只有既有可信生命周期适配器明确结束会话才撤销其许可，不把stdout管道关闭等于完成。CLI崩溃/被强杀/服务重启：受信桌面owner/后台在下次启动核查已登记执行和材料，依据服务内登记、路径/文件身份及进程创建时间等事实决定清理；本地无秘密journal不是权限证明，不能据此恢复启动许可。能核实进程树仍活跃则保留，无法核实标 unknown/needs_check；不重放、不将未知标成功。服务重启使未消费能力失效。CLI内存输出丢失返回 output_unavailable，桌面仅显示执行事实。撤销/到期不自动杀进程；用户若需终止已运行进程需用系统工具，本版无“撤销即杀进程”。

上述EOF规则针对持续通用JSON-lines CLI。逐次Codex适配器只转发本机`/credential-use/hosted`的运行/状态/输出/清理命令，持续执行器由应用托管，因此单个适配器退出不会丢失该执行的内存输出。全局最多16项、各自原有4MiB上限；运行中不驱逐，已结束项可腾出容量且30分钟后淘汰。宿主缺失不回退为另一条执行路径；运行响应不确定先查原requestId。应用宿主退出会丢失内存输出，外部worker仍保持已启动程序的进程组与管道排空；重开后保留执行事实并核查清理，不恢复输出或启动许可。

## 错误码与重试

新命令失败采用 `{"protocolVersion":1,"status":"invalid_request|unauthorized|service_unavailable|denied|expired|revoked|conflict","errorCode":"…","retryable":false,"attemptConsumed":false}`；验证错误还带非秘密 `fieldPath`（例如 launch.argv[3]），不能回显输入值。不会产生运行错误的catalog/status可省略 attemptConsumed；error消息固定模板，不能附异常正文或原文。

| errorCode | status | 自动重试条件 |
| --- | --- | --- |
| `invalid_json,unknown_field,invalid_type,invalid_reference,invalid_plan,invalid_env,limit_exceeded` | invalid_request | 修正输入；不能自动扩大范围 |
| `unsupported_receiver,unsupported_tool_version,receiver_not_ready` | invalid_request | 用户完善配置或换受支持方式后新申请 |
| `session_required,session_mismatch,scope_not_approved` | unauthorized | 不凭公开ID绕过；需要正确会话/另行批准 |
| `request_pending,request_terminal` | conflict | 查询原请求；pending可wait |
| `request_denied` | denied | 停止，不循环重提 |
| `grant_expired,credential_expired` | expired | 明确说明后新申请 |
| `grant_revoked,credential_disabled,credential_deleted` | revoked | 停止使用 |
| `credential_version_changed,executable_changed,plan_changed` | conflict | 重新发现/核对后新申请；exe运行时改变已有execution且尝试已消耗 |
| `attempt_consumed` | conflict | 查询原execution，不重放 |
| `audit_unavailable,service_unavailable,execution_capacity` | service_unavailable | 确认attempt未占用才可同原请求重试；状态不明先查 |
| `material_prepare_failed,material_claim_failed,process_start_failed` | invalid_request | execution终态，尝试消耗；纠正原因后新申请 |
| `execution_unknown` | conflict | 核查原执行/残留，不自动重做 |
| `output_unavailable,cursor_out_of_range` | invalid_request | 输出已丢失不重跑；游标错误可从0重新查询剩余缓冲 |
| `cleanup_busy,cleanup_failed,cleanup_identity_mismatch` | conflict | 只重试清理，保持执行结果与消耗不变 |

`retryable:true`只用于已确认未占用且短暂可恢复的服务/审计不可用，或cleanup_busy的清理重试；任何调用若未收到响应，先查原请求/执行。requestUse status需包含已有executionId（同会话），解决run-use响应丢失后的定位。服务/CLI日志只记录错误码、对象ID和状态；不记录私密HTTP原body、输入env值或输出。

D6实现澄清：私有领取尚未建立连接时可以明确返回`service_unavailable,attemptConsumed:false`；请求已发出但响应断开、损坏或超时，不能据此证明事务未占用，CLI返回`material_claim_failed,retryable:false,attemptConsumed:true`作保守处理，再以原请求status中的执行编号及服务事实核对。不得把这个本地通信失败转换成可安全重跑的未占用许可。

## D7 实现澄清（2026-10-18）

- Windows已实测接收配置：GitHub CLI 2.102.0、AWS CLI 2.38.1、Windows OpenSSH 9.5p2；版本识别在隔离环境执行，仍绑定程序规范路径/大小/时间/hash。其他版本不自动计为已验证。SSH首版面向Linux/Unix的POSIX远端命令；客户端直接创建进程，不经本机shell。SSH远端仍由账户shell解释命令，执行器逐项按POSIX引用字面参数，不是任意远端shell的参数数组协议；cmd/PowerShell远端不在本接收配置范围内。
- 所有者显式导入并确认known_hosts，schema16保存不可变快照ID、字节及确认时间；ID和内容hash进入有效计划。相同内容重新确认也产生新ID，旧未启动SSH申请失效。领取交付原批准快照，运行中任务不跟随设置改变。服务关闭后不能设置或清除确认记录。
- 同一alias可合法重复用于多个SSH `-i` 参数，复用同一材料路径，不引入多个不同身份。普通包含占位符的字符串保持原样。原始申请与附加隔离参数后的有效计划分开保留，均可在审批中核对。
- 私有材料领取DTO可包含credentialMaterial、内部主机快照和materialLease，响应上限4MiB，覆盖两份各最多1MiB材料的base64及计划。此限制与4MiB输出缓冲是两个不同边界；公开CLI/HTTP请求的262144字节上限不变。材料字节、受管路径/真实身份及进程组私有登记不进入普通CLI响应、公共目录或历史导出。
- 文件登记先于秘密写入：服务持久化受限目录身份，CLI独占建立空文件，私有能力接口核对并保存全部预期文件身份后才写入。正常终态和重启核查按真实身份清理；活动或不确定进程、身份不匹配或额外硬链接均保留材料，只能重试清理，不能重放启动。退出码与清理结果独立。

Windows验证及未完成项见[实施记录](https://github.com/ShiJiJS/chiyo/blob/46ff2a9ba5bda130c88f9aac9beef72eb586e781/docs/development/round05-29-files.md)。完整凭据历史/Codex持续执行衔接归#30，格式5及用户资料迁移归#31；不扩大浏览器填充、交互SSH或服务器同步范围。

## 直接验收 seam

D6/D7先经公开核心服务验证批准/组合许可/过期/撤销/并发一次消费与版本失效，再通过真实 CLI 子进程驱动 JSON lines，以受控假程序核对获得的env或文件内容及父环境未变；测试程序只回传布尔比对事实，不打印秘密。核对输出base64、限额、并发输入/输出不混行、启动失败额度消耗、清理身份保护、服务重启/CLI异常后的unknown与残留。gh/SSH/AWS配置用假凭据和隔离本地测试服务做代表验收，缺真实工具条件时记录具体未验证项，不宣称所有工具接入完成。Windows先验收；macOS真实环境按用户指示延期。
