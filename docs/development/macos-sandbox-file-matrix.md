# Mac 普通安装包的真实文件访问矩阵（#44 / #50）

2026-10-22，仅独立 `codex/macos-adaptation`。继续使用已允许的固定普通
`4690e79357bb728da22193d8dadd6dc8a8ce2ce6` 整包、真实 Keychain 与生产沙盒。
没有换包、改应用身份、注入测试数据库密钥或新增主人系统允许。
[74 份原始资料与摘要](evidence/macos-sandbox-file-matrix/verification.json)。

本轮补上实际容器外 cwd、目录访问、文件读写和 OS 不足权限证据，也确认了一个
可用性缺口：当前目录入口只持久化读取，初选时写入成功不能证明重开后还能写。
#44 第 2 项继续开放，不能用本轮部分矩阵代替明确的持久读写流程及最终整包复验。

## 被测程序与范围

- 普通 App51844，正常退出后 App53038，再正常退出后 App53592。两个已完成退出均为 0，
  服务端口关闭；最后一个进程有意保持运行，不声明它已退出。两次重开没有新增主人操作。
- 随包 AWS CLI 2.38.1，入口始终为服务发现的准确 `Contents/Resources/ThirdParty/aws-cli/aws`。
  `ps comm` 实际观察 App53038→worker53193→AWS53195，以及另一组 worker53220→AWS53222；
  App 直接启动的两个 AWS 版本探测单列，不冒充两次凭据操作。
- 本轮客户端是本地编译的 AOT `AgentClient(hostedCredentialExecutions: true)` 驱动，
  仅系统 PATH，不依赖 SDK；App 仍仅 HOME/USER/LOGNAME/LANG/系统 PATH。
  不声称随包通用 `info` CLI 默认选择桌面托管模式。客户端 core/CLI 库与安装源码逐 Git diff 相同。
- 通过真实 NSOpenPanel 导入独立合成 AWS 文件凭据、真实 GUI 批准两份各 15 分钟许可。
  凭据后来停用并隐藏，公开目录再次为空。只有本轮合成目录被选择或改 POSIX 权限。
- 新增 S3 接收夹具只监听随机回环端口，逐请求验证 SigV4；不记录 Authorization 头。
  原文固定 2,009 字节，SHA256
  `6090183a2952a9faea979bf20b3824e1cd5e940dd2baafa6977e7fb2705e3151`。
  10 次已认证 GET 中 2 次是直接 CLI 的夹具自检，8 次来自普通 App 托管目标。
  不能将 HTTP 已发出当作文件已经写入。

## 实际矩阵

表中均为真实随包 AWS；未授予与已授予是系统文件访问，区别于凭据使用授权。
目录均为项目内、应用容器外的中文空格合成目录，容器内目标位于本轮独占子目录。

| 操作 ID | 实际条件与结果 |
| --- | --- |
| `matrix-baseline` | 容器 cwd、容器输出：退出 0，实际 2,009 字节与接收端原文一致。 |
| `matrix-no-scope-read` | 首个 `--cli-input-json` 夹具形式退出 252，提示缺 bucket/key；直接非沙盒同样失败。**不算权限证据**，改用经过独立 CLI 验证的 `--key file://…`。 |
| `matrix-no-scope-cwd` | 未选目录作为 cwd：start_failed/process_start_failed、processStarted=false、无退出码；不推断未捕获的底层 errno。 |
| `matrix-ungranted-file-key` | 容器 cwd、未选外部参数文件：退出 252，实际 stderr 为 Errno 1 / Operation not permitted。 |
| `matrix-granted-read-cwd` | NSOpenPanel 选择目录后，外部 cwd 加外部参数文件：退出 0，容器输出逐字节相同。 |
| `matrix-ungranted-write` | 向另一未选目录输出：退出 255，Errno 1，目标不存在。 |
| `matrix-posix-denied-read` | 已选目录内合成参数文件临时 chmod000：退出 252，Errno 13 / Permission denied。随后恢复600，内容不变。 |
| `matrix-read-scope-denied-write` | 这是原先的预期标签；**实际退出 0、目录内写入成功**。当次 NSOpenPanel 的访问不能视为只读，不因该名称改写成功为拒绝。 |
| `matrix-persisted-read` | 正常退出/重开，未重新选目录；原书签摘要不变、设置显示可访问。外部 cwd/读取退出 0，输出逐字节相同。 |
| `matrix-persisted-write` | 同一重开进程向恢复的目录写新文件：退出 255，Errno 1，目标不存在。 |
| `matrix-explicit-file-write` | 实际 NSSavePanel 先将原普通附件另存为独立输出文件，再明确让工具写这份合成目标：退出 0，目标为正确 2,009 字节。 |
| `matrix-unselected-neighbour-write` | 同目录未选过的另一个新文件：退出 255，Errno 1，未生成文件。选择某个输出不等于允许所有相邻输出。 |
| `matrix-after-forget-read` | 实际设置确认移除保存目录后，容器 cwd 下重新读外部参数文件：退出 252，Errno 1。归档目录列表恢复原空状态。 |

50 次公开命令包含申请、查询和输出读取。共 13 个已登记操作、12 次真正目标启动：
5 次退出 0、4 次退出 252、3 次退出 255，
另 1 次未启动而无退出码。十三项清理均 complete。查询/重复旧操作保留 executionId，
不重跑；移除目录后查询此前成功操作仍是原成功事实。两份许可的固定截止时间
`18:15:38.584Z` / `18:26:47.941Z` 没有续期。没有用已经结束的首许可做自然到期证明。

首次 App 退出后旧客户端的新操作为 session_required / operationClaimed=false；
停用合成凭据后新操作为 credential_disabled / operationClaimed=false。
应用重开与文件访问均不恢复旧凭据授权。

## 普通资料与历史保持

明确授权给 AWS 的输出最初是通过系统面板导出的 1,024 字节普通附件副本，允许工具
覆盖的只有这份本轮拥有的输出。随后从原信息项再次实际另存，仍为原 1,024 字节及
原摘要 `f6c60ea3fc9c95ab55985e490192c191742fcbb5b48189f93faf2ab4dba20b29`；
副本被工具改成 2,009 字节，没有改变资料库中的附件原文。原 `777` 和两条信息保持。

普通界面与最后一次独立重开均核对本轮两份历史的 8/5 条操作、固定版本 2、
截止时间及 0/252/255/启动失败的准确显示；第一份操作列表的两页实际点击核对。
历史总数由 14 变为 16；这不是逐行比较全部旧历史内容的声明。
没有把错误结果归并为成功，也没有给未启动的操作补造退出码。

## 与既有工具证据的关系

重新按旧索引逐 SHA256 和长度核对 6 份原始证据：普通 `4690e79` 的实际 GH 托管
客户端/worker 观察、同包 SSH 的客户端/进程观察，以及更早隔离 QA 的目录选择结果与
sandboxd 拒绝日志。GH 普通包真实 HTTP401/退出1，SSH 已有真实 0/1 与严格主机校验；
当前系统仍为 OpenSSH 10.3p1。保留各自源码/包与运行范围，不把这些写成今天新执行。
更早的外部工具目录证明 GH/AWS 文件可读，但实际 process-exec 拒绝日志针对 GH；
不能扩写成当前普通包逐一验证了任意外部 GH/AWS 安装都能或不能执行。
支持的入口继续是系统 SSH 和准确随包 GH/AWS，目录选择不提供程序执行权。

本轮再次核对固定包 7,971 个原清单条目与 deep/strict 签名保持；额外 GH device-id
仍单列为运行状态。产品应用、worker、KeyStore、存储和 Windows 均没有改动。
QA 只增加 S3 文件接收夹具，复用 SigV4 验签的参数默认仍为 STS/SSM。
实际随包 CLI 回归 STS、SSM 写入/读取退出0，错误秘密标准拒绝254；接收端3有效/1无效，
测试服务器清理退出 -15，不当作产品退出结果。

## 发现的缺口与后续实现

当前 `ToolAccessStore` 保存 `.withSecurityScope + .securityScopeAllowOnlyReadAccess`，
而系统目录面板当次选择可使进程取得写入访问。真实重开后书签只恢复读取；因此当前
界面的泛称“目录文件可访问”不足以让用户判断工作目录重开后还能否写入。
这首先是持久文件访问与说明的缺口，不把当次系统已授予的写入描述为越权。

需要补上主人明确选择的**持久工作目录读写访问**，并区分现有只读工具目录书签：
保留旧条目的读取范围，不静默升级它们；由真实系统面板选择准确目录，显示保存范围，
以实际重开后的读/写、未选相邻目录拒绝、移除与再次重开为验收。Agent 的访问请求
不能代替系统目录选择，也不把书签或本机文件能力送入 Agent 协议。该实现尚未完成，
本轮没有仅改说明就宣称工作目录写入可用，也没有放宽 App Sandbox 或添加执行例外。

## 失败准备与清理

第一份合成凭据误含 region，静态凭据校验拒绝 material_prepare_failed；通过原生面板
替换为仅含静态认证字段的 v2 后才申请。地区仍由完整启动计划声明。原失败保留。
上表 JSON 输入形式的参数失败与权限失败分开。较长 JSON 在 canonical PTY 发生截断，
两次客户端均正常退出0；改用 noncanonical/no-echo 传输及 QA-only qa-close 后继续。
AgentClient 实现未改，私密关联不输出。第一轮进程采样没有命中已结束的目标，
第二轮随实际执行观察到父子关系，不补造第一轮结果。

本轮没有构建第二个 App 或 dSYM。已清理合成凭据源、参数/下载/输出文件、容器内
本轮专用目录、AOT 驱动和其编译副本；回环接收器按准确自有 PID SIGTERM，shell
退出143单列。目录列表恢复空，合成凭据停用且隐藏；原资料及加密版本/历史保留。
最终 App53592 正常可用，项目只有固定 App 一份、生成 dSYM 为零，新旧 ZIP、升级前
私有备份/恢复密钥和工具链保留。

#44 保持 **OPEN、3/6**：第2项已有上述实测，但仍需明确持久读写流程与外部工具位置
范围核对；第3项真实工具版本变化重审、第6项容量/最终变更包影响复验继续开放。
`7edb11c` 新包尚未取得旧 Keychain 访问，当前普通安装仍是 `4690e79`；本轮不替代
#50 最终换包、通知/备份/Codex 闭环或干净用户验收。没有操作 Windows/main/CI。
