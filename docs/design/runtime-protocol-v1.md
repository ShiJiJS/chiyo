# 凭据运行协议 v1（D0 冻结）

2026-10-17，Issue #22 的实施输入。本文是待实现协议，不表示现有 CLI 已提供这些命令。保留 [现行逐行 JSON CLI](../cli.md) 的命令名、会话私密证明保管和单输入/单响应结构；新增接口按本文实现。产品边界见[实施契约](runtime-implementation-contract.md)、ADR0008。

## 传输与职责

通用 CLI stdin 每行一个 UTF-8 JSON 对象，stdout 每条输入恰好一个 JSON 对象加换行。所有新响应有 `protocolVersion:1`。一次输入最多 262144 UTF-8 字节（含换行），超限整行拒绝；既有命令更小的限制保持不变。未知属性、错类型、重复 JSON key、非整数数值和非有限数值均拒绝；解析层不能先丢弃重复 key 再验证。UTC 时间采用 RFC3339 毫秒和 `Z`；标识是不可推导授权的 opaque string，1–128 ASCII 字符。

服务负责批准、原子占用许可和持久化非秘密执行/清理元数据；**CLI 才是执行器**。`run-use` 经 AgentClient 内部带会话证明的私有通道领取执行材料，在当前 CLI 进程中直接 `Process.start`，不经 shell。通用 JSON 响应、目录和桌面历史都不含外部秘密、临时授权证明、受管材料内容或临时绝对路径。私有 HTTP 不能误用为普通 CLI command 的透传响应。

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
| `aws_shared_credentials` | file；env `AWS_SHARED_CREDENTIALS_FILE:{file:alias}` | 真正 AWS CLI；首版固定 `sts get-caller-identity --region REGION`，profile为 `default`；`AWS_CONFIG_FILE` 指向受管空配置、`AWS_EC2_METADATA_DISABLED=true`、`AWS_PAGER=""`，不继承 `AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN/AWS_PROFILE`；受管配置不含 `credential_process`、SSO 或 role chaining。只支持受管凭据文件中的静态 default 凭据。 |

这些限制定义经验证的接收配置，不能以程序名相同宣称排除了任意恶意二进制或同用户进程。exe 需要规范路径并在批准时记录文件大小、修改时间与 SHA-256；启动前重新核对，变化返回 `executable_changed`，消耗本次尝试并要求新申请。执行器附加的配置路径使用类型化内部 material 引用，在 UI 显示“空配置/已确认主机快照”；不能偷偷增加未展示的网络或命令参数。SSH known_hosts 未准备好时在申请阶段返回 `receiver_not_ready` 并指向桌面配置入口。

不继承父进程环境。Windows 基础仅 `SystemRoot,WINDIR,COMSPEC`（供 DLL/工具定位，不允许 shell 接收配置）、受控 `TEMP/TMP`、`PATH=<SystemRoot>\\System32;<exe目录>`；Unix 仅 `PATH=/usr/bin:/bin`、受控 `TMPDIR`、`LANG=C.UTF-8`。HOME/USERPROFILE/APPDATA/XDG_CONFIG_HOME 指向每次私有空配置目录。应用会话、grants、Git、SSH、云账号、代理认证等其他变量一律不继承。显式 env 中不能覆盖配置隔离变量或注入 `PATH,COMSPEC,LD_PRELOAD,DYLD_*,PYTHONPATH,NODE_OPTIONS` 等程序加载控制；接收配置仅允许表中认证变量和已列出的非秘密常量。无法核实当前工具版本的账号优先级时返回 `unsupported_tool_version`，不能用原用户环境重试。

## 决定、领取与一次启动

桌面决定在一个事务中记录请求终态及两个独立许可。`status` / `wait` 沿用请求 ID 和私密会话，新增 `approved|partially_approved` 响应：

```json
{"protocolVersion":1,"status":"partially_approved","requestId":"use-024","decision":{"credentialUse":{"approved":false},"fieldRead":{"approved":true,"fields":[{"itemId":"server-test","fieldId":"host"}],"expiresAt":"2026-10-17T06:55:00.000Z"}},"planHash":"sha256:…"}
```

若 `credentialUse.approved:true`，还包含 `credentialId,version,expiresAt,maxAttempts:1,attemptsConsumed:0`。两项均未批准只允许 `denied`，不能返回部分批准。组合字段期限默认跟随15/30分钟启动窗口，两个精确到期时间分别显示；独立字段申请仍默认8小时。`claim` 对组合申请只领取实际批准的 fieldRead，响应沿用既有 fields/expiresAt；不批准字段返回 `scope_not_approved`。`read` 不改变使用额度；准备/启动失败不撤销字段许可。

`{"command":"run-use","requestId":"use-024"}` 恰含这两个字段，不接受新 launch/version/env。私密会话的内部请求先事务核对请求已批准、会话活跃、未到期/撤销、当前凭据版本可用和计划完整，再将一次尝试从 available 改 consumed，创建 execution。原子占用和执行记录任一审计写入失败均回滚，返回 `audit_unavailable`，不交付秘密。成功响应：

```json
{"protocolVersion":1,"status":"accepted","requestId":"use-024","executionId":"exec-024","attemptConsumed":true,"processStarted":false,"executionState":"preparing"}
```

占用之前被拒绝时 `attemptConsumed:false`，不创建 execution；额度已占用的重放返回 `attempt_consumed` 和同会话可见原 executionId，绝不重新交付。占用之后准备失败、私有领取失败、exe改变或启动失败都消耗本次尝试，由 execution记录失败。网络响应丢失时先 status 或 execution-status 查询；不得自动重新申请。没有私密会话的请求编号、Credential ID、executionId 都不能领取秘密。

### 内部私有领取边界（不属于通用 JSON CLI）

AgentClient 经本机 loopback `POST /credential-use/consume` 发送 `sessionSecret,requestId`，服务原子占用并返回 `executionId,executionCapability,approvedPlan,credentialMaterial`。材料仅含恰好一个已批版本，字符串原文或 base64 文件字节；HTTP 原始响应不得返回给 execute() 调用者、stdout、debug logger 或异常消息。服务监听沿用现有本机服务，仍需私密证明，不凭来源IP授权；库密钥不交给CLI。

CLI 在受管目录建立执行日志（只有executionId、文件身份、进程身份、清理状态；无原文/证明），使用 `POST /credential-use/execution/report` 持 `executionCapability` 报告准备/启动/退出/清理状态。capability 只能更新这个执行的允许状态，不能再次领取或启动其他执行；结束会话/撤销后可继续上报已启动执行的退出与清理，不因此恢复普通访问。服务核对状态单调、子进程身份与受管文件身份，不接受任意路径删除指令。内部 `/credential-use/execution/status` 使用会话证明查询所属执行；桌面 owner API 可读全部非秘密记录。接口各自输入输出应有专门 DTO；不能把 credentials/material 混入通用 Map 后靠 remove() 黑名单过滤。

## 查询、输出与清理

`{"command":"execution-status","executionId":"exec-024"}` 只在所属私密会话中，服务可返回已结束会话关联的历史事实但不给恢复许可；重新打开同名聊天不是原会话。返回字段固定：

```json
{"protocolVersion":1,"status":"ok","executionId":"exec-024","requestId":"use-024","executionState":"exited","attemptConsumed":true,"processStarted":true,"exitCode":0,"errorCode":null,"startedAt":"2026-10-17T06:41:00.000Z","finishedAt":"2026-10-17T06:41:02.000Z","cleanupState":"complete","outputAvailable":true,"outputTruncated":false}
```

所有时间和 exitCode 在未知/未发生时为 null。`executionState`: `preparing|running|exited|prepare_failed|start_failed|unknown`；exited 用 exitCode区分成功/失败。`cleanupState`: `not_needed|pending|complete|failed|needs_check`。`processStarted` 只有执行器收到 OS 创建成功事实才为true。请求状态、使用许可、执行和清理四个维度分开；文件清理失败不能把非零退出改为成功，Token 使用是 not_needed，不能画成“SSH文件已清理”。

`{"command":"execution-output","executionId":"exec-024","cursor":0,"limit":16}`：cursor为下一个 chunk序号（0起），limit1–16，默认16。仅查询当前 CLI 内存缓冲，不把输出传回服务或写库；其他CLI进程即使获准查询历史也返回 `output_unavailable`。响应：

```json
{"protocolVersion":1,"status":"ok","executionId":"exec-024","chunks":[{"seq":0,"stream":"stdout","dataBase64":"b2sK"}],"nextCursor":1,"hasMore":false,"outputComplete":true,"outputTruncated":false}
```

每块最多4096原始字节，stdout/stderr带独立 stream标签，seq按CLI接收顺序全局递增，不能承诺跨流真实时间全序。每执行总共保留首4MiB原始字节；超出后继续排空管道但丢弃后续输出，`outputTruncated:true`，避免子进程卡住；最多保留16个执行的缓冲（退出超过30分钟或CLI关闭即丢弃，先清理最早结束项，不驱逐运行中项；16个仍活跃时拒绝新运行 `execution_capacity`，占用前拒绝）。输出是外部不可信数据，可能含秘密，不承诺变形泄漏打码；UI默认不展开，不进入历史/审计/备份，不在自动截图/测试日志输出真实材料。`outputComplete`在管道关闭时true，退出结果未知不能仅由有输出推定成功。

`{"command":"cleanup-use","executionId":"exec-024"}` 只重试已登记材料清理，绝不执行命令。服务与执行器核对同会话/执行身份，返回 `status:ok,executionId,cleanupState`；仍有活动身份或路径不匹配时 `cleanup_busy|cleanup_identity_mismatch`，保留登记并给owner操作指引。没有文件时返回 not_needed。文件owner-only权限（Windows仅当前用户及必要系统主体；Unix0600目录0700），拒绝 symlink/reparse point；相同别名复用同一副本。退出后等待受管进程树确定结束再清理，不把父进程退出等于后代都结束。不能确定后代身份时 needs_check，保留失败事实，禁止盲删用户文件。

CLI stdin EOF：停止接收新命令，保持执行监护和清理直到已启动受管进程树结束；**不结束共享授权会话**，普通CLI退出不等于Codex聊天结束。只有既有可信生命周期适配器明确结束会话才撤销其许可，不把stdout管道关闭等于完成。CLI崩溃/被强杀/服务重启：受信桌面owner/后台在下次启动核查已登记执行和材料，依据服务内登记、路径/文件身份及进程创建时间等事实决定清理；本地无秘密journal不是权限证明，不能据此恢复启动许可。能核实进程树仍活跃则保留，无法核实标 unknown/needs_check；不重放、不将未知标成功。服务重启使未消费能力失效。CLI内存输出丢失返回 output_unavailable，桌面仅显示执行事实。撤销/到期不自动杀进程；用户若需终止已运行进程需用系统工具，本版无“撤销即杀进程”。

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

## 直接验收 seam

D6/D7先经公开核心服务验证批准/组合许可/过期/撤销/并发一次消费与版本失效，再通过真实 CLI 子进程驱动 JSON lines，以受控假程序核对获得的env或文件内容及父环境未变；测试程序只回传布尔比对事实，不打印秘密。核对输出base64、限额、并发输入/输出不混行、启动失败额度消耗、清理身份保护、服务重启/CLI异常后的unknown与残留。gh/SSH/AWS配置用假凭据和隔离本地测试服务做代表验收，缺真实工具条件时记录具体未验证项，不宣称所有工具接入完成。Windows先验收；macOS真实环境按用户指示延期。
