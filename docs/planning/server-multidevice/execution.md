# 服务端首轮开发接续

## 当前范围与任务

持续目标 #91–#102，#103–#105 后置，独立分支 codex/server-first-stage。#91–#101 已完成并关闭。#102 本机开发、同源候选、自动完整流程、第二次fork-none Agent试用及清理均完成，正在同步最终记录和GitHub关闭状态。最终候选f0f9e24a；App/CLI/worker与Linux ARM64编译服务匹配。Agent独立11项入库、20字段和2附件读回，用户侧核对关联与旧附件。全量检查中发现的失败已定位，修正测试夹具并定向复验，原失败及跳过如实保留。完整证据见evidence/server-a12/completion-audit.md与final-facts.json。没有正式安装或真实迁移；后文旧阶段仅是过程记录，以本节和末节为准。

当前GitHub工作页23/p1。原22/p1已确认不存在，库存只余用户空间0，依用户已有“此类直接新建”的授权重建同名任务空间23，不操作用户空间。#102正文、ready-for-agent标签、前置#101 Completed及评论已重读；回填最终完成评论与关闭状态后再结束此任务空间。产品实现f0f9e24a已推送，后续只有测试与证据变动，不为此反复改交付程序。

所有开发与检查仅使用隔离合成资料、私有测试密钥和TLS；未替换日常App、读取个人钥匙串或启动Windows CI。

## #91 已有实现

- apps/server/bin/server.dart：独立启动、正常关闭、一次性密钥/身份初始化；配置路径相对配置文件，秘密不写镜像/日志。
- HTTPS 管理接口复用现有 Owner 保存、版本检查及持久回执；新增/修改、操作查询、响应丢失后去重、服务器身份均实际验证。尚未提供 Agent 协议；#93 接续受限接入，不能给 CLI 管理 Token。
- Linux 与 Mac 只读挂载密钥，缺失/错误时拒绝并保持原库。TLS 由独立合成 CA 签发证书，正常校验及未信任时拒绝均通过；未改全局信任。
- 为 Linux 补 renameat2 的 no-replace 文件发布；不覆盖已有文件、符号链接和空目录，不支持时拒绝。原 Windows/Mac 分支不变。
- 最小备份通过现有单机 App 同一加密备份接口产生，在另一密钥的新库恢复；新服务接入 Token/身份独立。完整备份界面及全部类型仍属 #101。

## 证据与实际范围

- Mac 服务包 7 项通过，新增进程修改场景单项复验通过；服务 bin/lib/test 静态分析无问题。
- Linux ARM64 容器服务包最终 7 项通过；核心文件发布专项另 1 项通过。Mac 同项专项 1 项与其静态分析通过。
- scripts/qa/check-server-container.py 实际删除首个容器，用原持久目录创建另一个容器：资料、服务器身份、回执保持，同一写入重试仍只有一条，TLS 验证开启。脚本正常结束，所属容器与临时目录已回收。
- 独立服务进程实际经历启动、保存、退出、重新启动、查询及修改；不是仅在同进程重新建对象。
- 初次 Linux 备份失败真实发现平台缺口，已修复 no-replace 发布并复验通过，不把首次结果写作全绿。
- 初次 TLS 合成证书在 Mac 上失败，改为独立 CA 与服务证书后通过，未放宽证书校验。

日志在 local/server-first-stage 下的 macos-tests.log、process-tests.log、linux-tests.log、linux-publication.log、container-recreation.log、docker-build.log、analyze.log。仅用合成资料；没有真实资料或生产密钥。Dockerfile 目前是验收镜像，不是 #102 最终发布。

## 下一步

1. 从 #92 正常 App 的 WorkspaceSource 接口接远程数据、连接配置及空白客户端拉取。当前 OwnerWorkspaceSource 直接持有 OwnerAccess；WorkspaceSource 已有稳定界面边界，应新增远程实现并保持现有展示/编辑器。main.dart 当前仍创建本地 DesktopBootstrap，需要在测试隔离的新入口接入，最终 #102 统一为服务器模式。
2. 接入方式与核心规则见 apps/server/README.md；App 必须保持正常界面和模板逻辑，不先做新的演示界面。新版最终只走服务器，开发期间不替换日常安装。
3. 按真实依赖推进 #93 与 #94；新 Agent 无上下文试用按 #93/#102 安排。后置事项不得变成首轮阻塞，也不能将首轮功能缺陷任意后移。

## 整体状态

当前 #91–#96 达到各票首轮自动验收条件；#97–#102 未完成，没有统一候选包、正式安装或真实迁移。完整目标保持 active。下文按开发先后保留过程记录，其中旧“尚未完成”和“下一步”只代表当时状态；以本节和最后一节为准。

## #92 接续：远程客户端已补，界面未接

新增 packages/info_remote（生产仅依赖 info_core），提供 TLS 用户连接、服务器身份核对、文字资料读取与保存回执查询。每次请求校验服务器身份，服务器在处理写入之前检查预期身份；客户端禁止把管理 Token 发送到其他 origin。关闭客户端只关闭自己的连接，不停止服务。

新增核心普通资料传输解析，沿用既有 InformationDraftInput、InformationLayout、InformationRecordCommand；保留模板快照、字段身份、字段种类和目录标签，未知格式明确拒绝，文件继续等待 #97 的专用传输。服务器返回现有核心完整序列化结果，避免模板/布局在传输中丢失。

当前证据：Mac 与 Linux ARM64 远程客户端各 1 个集成场景通过（实际 HTTPS + SQLCipher），覆盖新客户端重连、类型/格式保留、操作去重、错误身份/另一服务拒绝、断线失败、不向外部 origin 传 Token。协议变化后的服务包 7 项在 Mac 和 Linux 均通过，相关静态分析无问题。日志 remote-client-tests.log、linux-remote-client-tests.log。

**#92 仍未完成。** 还没有把 OwnerClient 接到现有 WorkspaceApp，也没有地址/Token 配置界面和配置存储。下一步新增 RemoteWorkspaceSource，复用 WorkspaceInformationCodec 的展示/编辑转换，以及现有 WorkspaceApp、LibraryPage、LibraryEditDialog；补正常连接页面与隔离配置。不要用本地 MemoryInformationRepository 缓存冒充服务器数据源。

现有 builtinWorkspaceDefinitions 是纯 Dart 声明，仅依赖 workspaceImmutableMap；后续可把定义放入共享纯 Dart 模块并保留原 App re-export，使服务器与 UI 使用相同定义。完整动态插件管理仍由 #95 接续。工作区每种未迁移入口需显式失败并记录，逐票接通，#102 前收口，不能直接照搬旧本地 bootstrap 当作联网完成。

## #92 正常界面接入（当前新增）

- main.dart 的正常入口现在使用 OnlineDesktopLauncher，先配置地址/Token/可选私人 CA 证书；连接后仍是原 WorkspaceApp、LibraryPage、LibraryEditor。没有启动本机资料库或单机 HTTP，也没有替换日常安装。
- RemoteWorkspaceSource 复用原 WorkspaceInformationCodec；目录树/标签/模板定义从正常服务查询，列表用不含正文字段的摘要，打开资料才领取详细内容。搜索、分组、新增、编辑与回执查询经 HTTPS，所有写入保持原操作编号。
- builtinWorkspaceDefinitions 移入 info_core 的纯 Dart 模块，App 原路径保留 re-export；不是给测试另装插件。尚未接动态插件的管理操作，仍由 #95 处理。
- 用户连接配置和 Token 在专用私有目录保存：POSIX 目录 700、文件 600、原子替换，不进入普通偏好或日志。当前实现支持 Mac/Linux，Windows 身份保管留 L02，不声称 Windows 已验证；没有调用个人钥匙串。
- Token 更换和服务器身份变化走真实连接校验；重新绑定另一服务器须由连接页面明确选择。每次请求均核对服务器身份，跨 origin 请求被拒绝。
- 自动探测连接状态，离线时遮挡资料、禁止其操作，保留当前表单和待核对操作以便连回后处理。遇到不确定写入结果必须先核对回执，不改用新编号重做。
- 已通过初版完整 Widget + HTTPS + SQLCipher 场景：连接、新增、编辑、搜索、嵌套目录、新配置拉取、独立 Dart 客户端进程内容摘要核对、Token 更换和服务器重新绑定。保存配置自动重开、断线遮挡/恢复的完整 Widget 场景也已通过；真实 HTTPS + SQLCipher，含独立客户端进程摘要核对。丢失响应的专项通过：实际保存后断开网络响应，查询原回执得到同一资料，失败查询不会误报未保存。#92 已达到本票自动验收条件，已回填 GitHub 并关闭（页面刷新后确认）。

### 首轮入口对照

| 入口 | 当前状态 | 接续工单 |
|---|---|---|
| 地址、Token、私人证书与连接设置 | 已通过自动验收 | #92 |
| 文字资料列表、详情、搜索、新增、编辑、操作回执 | 已通过自动验收 | #92 |
| 目录、标签、资料归属和模板身份查询 | 接入 | #92 |
| AI 文字请求、同机审批、会话及主/子 Agent | 已接并通过自动及独立 Agent 试用；文件/凭据后续接续 | #93 |
| 目录修改、移动、排序、整理任务 | 已接并通过 Mac/Linux 与正常 App 自动验收 | #94 |
| 插件管理、动态模板与 CLI 示例 | 已接并通过 Mac/Linux 和正常 App 自动检查 | #95 |
| 文字录入/修改提案与预览 | 已接并通过整份保存、修正、重开、失败与丢失回复检查 | #96 |
| 附件上传、版本、领取与本机操作 | 已接并通过正常App及独立CLI实际文件检查 | #97 |
| 凭据管理、补填密码及关联 | 已接并通过正常App、CLI、整份事务及断线恢复检查 | #98 |
| SSH、Token、凭据文件的本机使用 | 已接实际执行、正常App审批及原审批结果不明的重开结算；本票自动验收通过 | #99 |
| 回收、历史和版本恢复 | 已接正常远程入口及控件，实际HTTP/断线/批次故障/重开自动验收通过 | #100 |
| 完整备份恢复与设置界面 | 宿主最小恢复已验；界面未接 | #101 |
| 最终单一候选、运行程序和全流程自动试用 | 未开始 | #102 |

后续不得把未接入口当空结果或已完成，需逐票接通并更新本表。

### #92 最终本轮检查

- 正常连接和完整编辑 Widget 场景 1 项通过，约 68 秒，包含多个用户操作；它不是原生系统弹窗/物理输入验收。
- 丢失保存响应、回执核对和断线查询专项 1 项通过。
- 原工作区及共享定义回归 7 项通过；Mac 服务包 7 项通过；Mac 与 Linux 连接/配置检查各 2 项通过；Linux 服务包 7 项通过。
- 新增/修改的 App 文件和相关测试静态分析通过。原模板定义搬到核心共享，原本机入口的兼容测试保留；正式主入口现在采用联网连接界面。
- 几次早期失败来自测试夹具的框架依赖、假时钟调度及读取已关闭端口，已修正，未将首次运行说成全绿。曾验证过的场景在后续补充后复跑，最终以日志中的单次场景通过为准，不累计重复执行次数。
- 日志：online-ui-tests.log、remote-recovery-tests.log、owner-ui-regression.log、linux-tests-a02.log、linux-remote-tests-a02.log。没有安装新 App、没有个人钥匙串请求、没有真实资料读写。

## 当前下一任务 #93

实现提交 eab2b046 已推送，#92 的结果评论及关闭状态已从 GitHub 刷新确认。不要重新开发或重复关闭 #91/#92。

#93 需要接通正式 CLI 与受限设备/聊天身份、正常审批界面，以及文字授权的服务重启恢复。当前 AgentServer 仍是仅本机回环的 HTTP，AgentClient 仍固定 127.0.0.1；不要直接取消原端口的 Host/Origin 校验来公开接口。应复用现有命令处理和业务规则，通过认证的远程通道接入，与用户管理 Token 分开。

InformationService 当前授权与会话仍在内存，close() 清除并记录 applicationClosed；_recoverAudit 会按旧单机规则恢复历史而非活跃许可。服务端需新增明确的持久会话能力，不改变旧单机兼容测试的关闭规则。真正的普通重启延续、撤销/结束/到期不复活、备份恢复不恢复旧许可必须分别验证。先做文字，文件和凭据按后续票再接。

本轮没有创建统一预览包；这仍是自动开发阶段。#103–#105 保持后置，目标 active。

## #93 已开始：共用 Agent 命令处理

AgentServer 已继承拆出的 AgentProtocol。旧回环 HTTP 的 Host/Origin/大小校验原样保留；AgentProtocol 只接收 AgentAccess，可由后续认证后的 HTTPS 入口使用，不接受 OwnerAccess。没有为此开放旧端口或增加管理路由。

45 项相关旧传输/会话/录入/模板/附件/凭据/文件交付回归通过；新增 1 项独立协议检查通过：不监听端口也能完成目录查看、申请、批准后的限定读取和聊天结束失效，且不能调用 /approve 管理路由。相关静态分析通过。首次误用了不存在的测试文件名，随后按实际七个传输测试文件执行，当前有效结果是 45 项通过。

此时 #93 仍未完成：尚未把协议挂到认证的远程 Agent 通道，尚未配置 CLI 远程身份、接审批界面或持久化有效授权。接下来先实现受限设备身份与会话/领取 token 的绑定，再为服务端核心增加可恢复文字会话的存储；不能单靠内存 Map，也不能直接导出普通备份中的历史作为可用授权。

注意旧 /read 使用 grant token，没有 sessionSecret；设备门禁必须同时绑定会话、endCapability 和领取的 grant token，不能只检查带 sessionSecret 的请求，否则另一设备得到 token 后可能绕过设备归属。目录/模板等默认可发现元数据仍只需受限接入身份，不要求内容授权。

## #93 私有状态与设备凭证（当前新增）

- 新增 ServerStateRepository 可信宿主接口和同一 SQLCipher 中的私有状态表。状态代际与递增修订共同防止旧进程/恢复前的写入覆盖新状态；并发旧修订只能一个成功。载荷深度不可变，不进入目录、普通设置、Agent 结果或便携备份。
- 只在启用服务器状态时标记库格式53。旧单机读者应拒绝；普通旧库不会因打开而升级到53。格式53要求相应状态表，伪造新格式而缺表仍拒绝。此前两处旧测试以53作为未知格式的情况仍因缺少必需结构被拒绝，没有放宽校验来迁就测试。
- 正常重开保留状态；成功恢复在同一事务清掉目标旧状态，下次打开产生新代际。失败恢复保留原状态。源设备状态和目标旧状态均不会从备份恢复成有效接入。
- AgentDeviceRegistry 提供设备登记、验证、只含元数据的清单和撤销。用户登记操作有稳定编号，重复返回同一结果，冲突不重复创建设备；撤销后重开仍拒绝旧凭证。管理 Token 不是设备凭证，设备凭证不能调用用户管理接口。
- 所有 HTTPS 宿主现在显式注入同一真实仓库的设备注册能力，正式入口与测试装配一致。新增用户认证后的 /v1/owner/devices 查询/登记及 /v1/owner/devices/{id}/revoke；返回设备接入凭证仅限用户登记回复，不在清单中出现。普通 Agent 协议仍未挂到网络，尚不能使用远程资料。

### 本轮证据

Mac 服务包10项通过；Linux ARM64服务包10项通过。私有状态专项在Mac/Linux各2项通过；Mac状态/目录顺序/回收/备份相关回归16项通过、原有Windows条件跳过1项。设备登记/角色隔离/撤销/恢复专项均实际使用加密仓库和HTTPS。App相关修改仅是显式注入同一设备注册器，静态分析通过；未重新安装App。没有个人资料或真实密钥。

日志：server-device-suite.log、agent-device-focused.log、server-state-tests.log、server-state-regression.log、linux-server-device-tests.log、linux-server-state-tests.log。曾误用不存在的 backups_test.dart 文件名，实际改用 backup_test.dart 后相关回归完成，不把该次失败计作通过。

**#93 仍未完成。** 当前设备凭证只是连接身份，未授予资料访问。下一步：在共享HTTPS入口中先认证设备，再绑定 sessionSecret、endCapability、领取的grant token；私有状态的代际必须在操作前后核对。随后接正常审批界面，并实现文字会话/授权的真实重启恢复及对应独立Agent试用。不能把本轮状态表重开测试当成授权重启已经通过。

## #93 已接认证的远程 Agent 通道

新增 AgentGateway，复用 AgentProtocol，旧回环 HTTP 的 Host/Origin 防护保持不变。远程路径为 POST /v1/agent/...，正文在认证设备后按既有受限 JSON 解析；用户 Token 不能进入 Agent 通道，设备 Token 不能访问管理接口。当前仅接文字目录/会话/申请/状态/领取/读取，capabilities 明确不宣称尚未接通的模板、提案、文件或凭据能力。

会话、结束凭证及获批读取 token 均保存原设备绑定（索引仅存摘要）。每次操作前后重新核对设备撤销、状态代际和绑定；读取期间撤销设备时，不向调用方交付已取得的值。核心仍控制批准范围、结束和期限，不用设备身份代替用户审批。绑定在加密库普通重开后保留，便携备份不携带这些绑定。

Mac 服务包12项通过，Linux ARM64服务包12项通过；包含真实HTTPS的两设备隔离、用户/Agent角色隔离、无授权不能领取、重复申请和批准、仅获批字段读取、结束后拒绝及读取过程中撤销的专项。静态分析通过。日志 agent-gateway-tests.log、server-gateway-suite.log、linux-gateway-tests.log；Docker仅更新验证镜像，没有安装日常App或触发钥匙串。

**仍未完成 #93。** 本轮正常审批使用现有可信 OwnerAccess 的持久决定接口做合成驱动；App的远程审批适配、CLI连接配置及真正的核心会话/授权重启恢复仍需接续。设备索引的重开不等同授权重启，不关闭本票。

## #93 文字会话与有效许可的普通重启恢复

新增可信宿主 OnlineInformationRuntime，作为联网模式业务命令入口。它在回复内容、新会话凭证或审批结果之前，保存加密的会话、待办、领取凭证、原批准范围与固定到期时间。普通关闭先保存再释放内存，不写入旧单机的 applicationClosed 撤销事实；原 InformationService 的本机默认关闭规则保持。正式 server 入口与所有 HTTPS 测试装配均显式使用相同在线生命周期，不提供仅测试使用的恢复开关。

启动时将私有状态与原持久审批事实核对。撤销和结束的事实优先于旧快照；原批准事务已提交但快照仍是待办时，仅恢复原批准范围和原期限，不重复授权。已过期或终止的不复活；普通历史或备份本身不创建许可。成功备份恢复清掉私有代际，旧运行对象随后拒绝操作且不能写回旧身份。损坏状态拒绝启动，不默默改成空状态。写入失败不返回暂存内容，后续命令停止；CAS重试保留设备登记等其他私有状态，不覆盖并发命名空间。

HTTP处理现先认证并有界解析正文，再进入串行核心操作；回复先暂存，待在线状态保存成功后才真正发送。没有在持有业务队列时等待客户端传输正文。AgentGateway测试整体关闭并重建SQLCipher仓库、核心、设备注册、HTTPS宿主和通道，原session及read token仍可完成原批准读取，然后结束/撤销仍生效。

### 本轮检查

- Mac在线授权6项：待办/有效许可/原期限重开，结束/撤销/到期不恢复，审批与快照之间中断恢复，备份代际清除，损坏拒绝。
- Linux ARM64在线授权与私有状态合计8项通过；Mac私有状态/审批事务相关回归21项通过。
- Mac故障注入2项通过：保存失败不交付值且停止后续命令；并发状态CAS重试不丢其他状态。
- 原本机传输/结束/审批/历史回归35项通过；原默认关闭规则没有改为保存许可。曾误写一个不存在的回归文件名，按实际transport_test.dart等文件重跑后35项通过。
- Mac和Linux服务包各12项通过，含HTTPS宿主真实重建后原凭证复用；远程客户端2项通过；App正常联网编辑/重新连接及响应丢失恢复2项通过（68秒，Widget+真实HTTPS+SQLCipher，不称为实机系统面板验收）。相关改动静态分析通过。

日志：online-runtime-tests.log、linux-runtime-storage-tests.log、online-runtime-failure-tests.log、storage-runtime-regression.log、local-auth-runtime-regression.log、server-runtime-suite.log、linux-runtime-server-tests.log、remote-runtime-regression.log、online-ui-runtime-regression.log。

**#93 尚未完成。** 下一步接用户审批HTTP接口与原App审批适配，再接正式CLI远程配置及无开发上下文Agent试用。当前协议未接远程文件/凭据，在线持久化也尚未宣称这些能力完成。没有正式候选包、安装或真实迁移。#103–#105不动，目标保持active。

## #93 正常 App 远程审批已接通

从原桌面 workspace 中抽出26个纯Dart契约和可信审批适配文件到 packages/info_workspace；旧路径保留re-export，原字段选择、复核标识、版本检查、操作摘要和持久审批规则没有在HTTP层复制。共享包不依赖Flutter，Docker验证镜像已纳入。提交 ebaee723 为该模块抽取。

新增用户认证后的审批查询、详情、决定和原操作回执接口；设备身份不能访问。RemoteWorkspaceApprovals 接入原 WorkspaceApp/ApprovalsController/ApprovalsPage。回复丢失时保留原操作并冻结再次提交，只查询原回执；查询失败不会当作没保存。当前协议只交付元数据和范围，不交付正文、会话证明或读取token；凭据/执行结果尚未接通时明确拒绝，不默默丢字段。

GET /v1/server 增加稳定元数据观察摘要，原App的连接检查据此刷新待办和处理结果。连接时保存首个观察摘要，避免首次轮询制造无变化刷新。集成回归发现了首轮刷新与目录选择、保存后定位的相互影响，已补初始基线；工作区load在被后台刷新替代时现在等待最新读取，避免过早显示“资料暂不可用”。网络UI验收按实际编辑控件出现等待，保留了目录归属、正文、类型、版本及独立客户端核对，不以固定等待结束冒充读完。

### 当前实际检查

- Mac服务包13项、Linux ARM64服务包13项通过。新增真实HTTPS用正常用户接口核对旧reviewToken冲突、仅选定字段批准、重复决定与原回执、拒绝和撤销；Agent身份无法审批，详情不含字段值或私密证明。
- 原审批/文件审批/执行投影/OwnerSource回归36项通过，共享模块纯Dart分析和App全lib/test分析通过。
- 新App审批与丢失回复恢复合计2项通过。正常OnlineDesktopLauncher已验证：App打开后新申请自动出现、字段减选、批准后受限读取、撤销、随后新申请刷新并拒绝、App关闭时继续提交以及重开后看到待办。另用实际HTTPS反向代理丢掉已提交的审批回复，原控制器核对原操作且不再发起第二次授权。
- 原完整联网编辑/重连/换Token/换服务器/离线遮挡回归1项重新通过（74秒）；原保存丢失回复恢复此前独立通过，未把中途的失败算作最终通过。
- 资料列表/选择/排序/录入/OwnerSource及刷新等待回归31项通过；新增可控并发刷新场景验证导航等待最新详情而非过早结束。
- 远程OwnerClient2项通过。没有正式安装、个人钥匙串提示或真实资料改动。

日志：server-approval-suite.log、owner-approval-http-tests.log、linux-owner-approval-tests.log、shared-workspace-regression.log、online-approval-final-tests.log、online-ui-approval-isolated.log、workspace-refresh-tests.log、library-refresh-regression.log、remote-owner-approval-regression.log、desktop-shared-analysis.log。online-ui-approval-regression.log保留了早期失败诊断，不用它充当全绿证据；以修复后的专项日志为准。

### 下一步

#93仍不关闭。接正式CLI远程配置与独立Agent试用；现有 packages/info_cli/lib/agent_client.dart 的 _call 仍固定回环HTTP。正常入口在bin/info.dart、bin/codex_info.dart、bin/codex_hook.dart，关联文件在lib/codex_association.dart（v2只存port与会话证明），结束索引在lib/codex_end_index.dart（仍向本机发结束请求）。必须一起处理HTTPS服务身份、受限设备配置、主/子聊天关联与根聊天结束，不能仅加一个旁路示例CLI或把用户Token交给Agent。开发配置和hook试用继续限定独立合成目录，不改全局安装/信任。

当前目标active；#94–#102继续按依赖推进，#103–#105保持后置。尚无统一候选包，不进行正式安装或真实迁移。

## #93 完成：正式 CLI、App 接入配置和独立 Agent 试用

正常 App 的“AI 接入”通过用户接口生成受限设备配置，重复打开复用，不保存用户管理 Token。CLI、Codex 关联与根结束索引使用同一 HTTPS 身份；关联持有原设备配置，重连不悄悄更换服务器，结束时即使初始配置已移除仍能关闭原根聊天。原本机兼容流程保留，远程未实现的凭据原文通道明确拒绝。配置目录700、文件600，服务身份、TLS和路径检查生效；不登记全局hook或访问个人钥匙串。

正式 Skill 和配套说明已更新。两个 fork_turns=none 的 Agent 仅收到运行包、合成资料目标及允许文件范围，自行查目录、申请最小字段、等待、领取和读取。第一轮发现 Node REPL 的 process 全局差异，修正为正常环境继承后，第二轮按修订说明直接完成。根结束后停止服务并独立查加密持久审计：两次仅批准“访问地址”、各一次成功读取、其他字段读取0、有效授权0。合成私有库、私密配置及重复二进制已清理，详见 [试用证据](../../development/evidence/server-a03/README.md)。

最终有效检查：Mac与Linux ARM64服务包各14项；原本机CLI/关联/结束/去重回归11项；Mac私有配置/OwnerClient4项、Linux配置2项；SDK-free准备/登记6项（含特殊字符路径）；正常App设备配置生成复用和完整文字审批Widget+真实HTTPS/SQLCipher通过。CLI、远程包、服务、App分析通过。日志：server-final-a03-tests.log、linux-remote-cli-suite.log、legacy-cli-remote-regression.log、remote-device-regression.log、linux-agent-profile-tests.log、remote-bundle-preparation-tests.log、online-agent-setup-widget-tests.log、desktop-cli-setup-analysis.log。

本票只完成文字范围，不将文件、凭据、本机执行或另一台电脑算作已验。保留一份cli-a03开发验证组件；它不是#102统一候选。优先继续#95动态模板以解开#96提案前置，#94也可推进。#103–#105不动。

## #95 完成：正常 App 管理服务器模板，CLI 动态查询

原 OwnerWorkspacePlugins 的领域投影、声明式校验与变更规则抽到 info_workspace/OwnerWorkspaceTemplatePackages；本机只保留选择器。正常联网 App 的原插件页面接远程安装预览、启停、更新、移除及操作回执。服务器观察摘要纳入模板版本。CLI 的三个既有发现命令接同一动态目录，仅声明模板发现能力，不提前宣称 #96 的远程提案保存。旧资料保持冻结类型、字段和布局，未知字段/操作拒绝，设备身份不能管理插件。

Mac与Linux服务包各15项通过；最新模板专项在两平台各1项通过，含真实内置文件、合成插件、普通资料/应用/配置/凭据例子进入共享校验、重启保持模板与回执。正常App安装到新建、Markdown显示及停用/更新/移除保留旧资料场景通过。原模板插件回归6项、审批/预览/录入回归13项通过；编辑全流程在改为等待实际可用按钮后专项67秒通过。相关静态分析通过。完整范围和日志索引见 [#95证据](../../development/evidence/server-a05/README.md)。没有正式安装、个人钥匙串操作或真实资料读写。

下一任务 #96（正文、评论及前置关系已重新读取）：复用原整份提案的预览、前后对比、修正、整体提交与持久回执，把正式CLI和正常App接到服务器。目录基本查询已经可用，不等待#94完整移动排序。#97/#98随后补文件和待填密码，不忽略这些必填条件。共享提案适配目前1816行，包含依赖原生文件预览的部分；抽取时以回调保留原能力，不把原生渲染搬到服务器或另写一份业务逻辑。

## #96 已开始：共享原提案规则和资料转换

WorkspaceInformationCodec、OwnerWorkspaceProposals 及凭据类型说明从桌面抽到 info_workspace，保留原审批摘要、逐项阅读、完整核对、一次整体保存和回执逻辑。新增最小 WorkspaceProposalLibrary 读取接口，服务器无需实现无关的桌面设置或操作系统能力。文件原文和PDF/图像渲染以 OwnerProposalFiles 接口注入；原桌面入口仍接原阅读器，不移除文件预览。服务器尚未接原文适配，明确不可用，不拿空内容冒充预览。

Mac 现有提案、整份密码、资料转换、模板录入和共用预览回归36项通过；原文件提案预览 Widget1项通过。新增无Flutter的服务包专项1项，用SQLCipher和相同共享适配验证双条互相引用的模板提案：不完整核对不入库或创建目录、完整一次保存、重复操作仍是原结果、实际值和预览一致。Linux ARM64共享提案与模板专项合计2项通过，使用当前共享源码和真实加密库。共享包、服务和App分析通过。日志 shared-proposal-regression.log、shared-proposal-original-ui-tests.log、shared-proposals-pure-tests.log、linux-shared-proposals-tests.log、desktop-proposal-share-analysis.log、server-proposal-share-analysis.log。

**#96 未完成。** 下一步：补用户提案查询/详情/修改对比/整体确认/回执的传输契约与服务器接口，接 RemoteWorkspaceSource.proposals；为正式Agent通道启用真实新增/修改和原操作状态查询，保持设备与聊天绑定。不提前声明文件或凭据录入能力。然后用正常App、CLI及独立客户端核对完整保存、重连、失效和失败不部分入库。当前没有统一候选、正式安装或真实迁移。

## #96 完成：正式 CLI 与正常 App 远程提案

服务器增加用户提案查询、完整预览、目录、整份决定、原操作回执、关联预览和准确快照接口，调用原共享提案适配；远程 App 的 ProposalsController/ProposalsPage 已接通。传输保留完整类型、模板快照、字段身份、改动、目录、关联和修正内容，拒绝不兼容版本或核对摘要不符的数据。关联候选规则抽为共用模块，原本机入口仍使用原排序。填写错误通过真实用户接口传回 App；材料不进入普通工作区数据。

AgentGateway 经原设备和聊天绑定接通 import/submit、revise、status 及 update/submit、revise、status，并仅声明已经接通的文字能力。带文件或凭据的提案整体拒绝，#97/#98继续接，不去掉必填材料冒充成功。普通服务重启和 App 关闭仍按已确认的生命周期处理。

Mac/Linux ARM64服务包各17项通过。正式CLI独立进程场景完成查询、互相引用、修正入库、原操作重试、真实SQL事务失败后不部分保存、整库重开、修改冲突和修订后再保存；独立用户客户端核对内容、关联和版本。最新Mac专项还核对了无效格式的实际填写错误。正常App三种模板标签预览、Markdown、关联切换、修正文后整份保存以及关闭重开后的修改对比通过；真实丢失回复及失败查询专项通过，原控制器不会重复保存。原规则回归33项、正常联网编辑/审批/插件回归3项通过，相关分析通过。详见 [#96证据](../../development/evidence/server-a06/README.md) 及其日志索引。

下一任务为 #94：通过现有目录、标签、多选和拖动入口连接服务器，复用原分类和移动规则；整理申请/任务同步接通。目录删除和整批恢复仍由#100接续，不假设当前已可用。当前没有统一候选、正式安装或真实迁移，#103–#105不动。

## #94 已开始：共用分类规则

OwnerWorkspaceClassification 抽到 info_workspace，只依赖元数据和当前模板的最小接口；原桌面入口保留re-export。OwnerWorkspaceInformation和服务器OnlineOwnerLibrary均满足该读取接口，没有将原生文件选择或数据库对象放进传输。原目录/标签变更、版本核查、回执及后代目录计数规则保持。

Mac原分类、资料与OwnerSource回归18项通过，纯Dart共享包及服务分析通过；本轮还没有接通远程分类写入或移动，因此#94保持打开。日志shared-classification-regression.log。下一步将本共用分类投影用于服务器目录及标签接口，保留文件/凭据创建入口是否已接通的区分；抽出LibraryMove及目录树纯逻辑，传输整份选择、前后位置、核对凭据和原回执，再接现有菜单/多选/拖动及手动视图偏好。

整理任务本身已在加密仓库保存，OrganizationTask使用sessionBinding和原expiresAt；OnlineInformationRuntime已经保存所有会话的原binding，不能另建可绕过会话的新身份。仍需接AgentGateway的organization命令、审批投影及观察摘要，并实际验证批准范围、任务重开与根结束失效。目录发现不授予整理能力。#100删除/恢复及#103–#105保持后置。


## #94 完成自动验收：远程分类、移动、顺序和整理任务

OwnerWorkspaceLibraryMove、目录树与选择转换抽为共享纯 Dart 模块，原 App 保留 re-export；共享模块依赖原 info_storage 的失败类型，未引入 Flutter。服务器与正常 App 使用原目录、标签、范围预览、整批移动和前后位置规则。完整选择、原核对摘要及持久回执经 HTTPS 传递，失去回复时保留原操作，失败查询不能当作未提交。原操作恢复成功后清除已解决的不确定状态。手动顺序及视图方式由服务器保存，关闭重开仍保持。

AgentGateway 经原设备及聊天身份接通 organization 系列命令；正常审批复用原限定范围适配，Agent只能读取获批元数据并调整范围内分类及标签。整理结果回到原提案只读界面，目录发现无写权限。OnlineInformationRuntime 的私有状态升到 v2，兼容读取 v1，持久保留已观察到期的整理任务，避免时间回拨加重启让授权复活。普通重启保留原范围及期限，结束聊天不恢复。

Mac/Linux ARM64 服务包各18项通过；最新关联保留加强场景在Mac和Linux各1项通过。真实HTTPS及SQLCipher验证分类、版本冲突、重名、嵌套整批移动、循环拒绝、前后排序、重开/回执、获批子集、范围外拒绝、正文不泄露、整理到期及根结束。加密运行时7项通过。正常App Widget全流程1项、真实丢回复恢复1项通过；原移动/拖动加正常审批、提案与新流程组合回归31项通过，另原移动/排序/分类回归36项通过。测试曾在新目标预览读取完成前提前点击保存，现等待真实预览与可操作状态；拖动也等待原操作结束，不调用业务方法代替正常控件。静态分析无问题。

完整证据见 [#94证据](../../development/evidence/server-a04/README.md)。目录删除/整批恢复仍由#100接续；文件与凭据创建分别由#97/#98开放，不声称这些已完成。下一任务#97。未替换日常App、未操作真实资料、个人钥匙串或全局hooks；没有最终统一候选，#103–#105不动。


## #97 开始：复用原文件暂存，尚未开放联网文件能力

已重新读取#97正文、评论及关系，#96前置已完成。先为OwnerAccess补stageInformationBytes，让受认证的服务器上传直接进入原InformationFileDraft与加密暂存；原路径选择同样调用内部暂存实现，不增加明文临时文件，也不把客户端文件路径传给服务器。入队前冻结上传字节，保留10MiB上限、元数据校验、草稿/库代际及取消、关闭规则。

Mac核心暂存11项、真实SQLCipher暂存9项通过；新检查覆盖调用者修改内存、其他Owner或过期草稿、坏文件名、超限及空文件，SQLCipher实际保管原字节，库文件中无合成明文，取消后清理。Linux ARM64同两组合计20项通过，原App文件历史、预览及另存规则回归14项通过，相关分析无问题。代码已推送e3c31b48。当前还没有HTTP上传、App文件选择/预览/替换/另存接入，也未接Agent下载及本机受管副本，#97保持打开。

Linux两次启动因SQLCipher依赖下载结果哈希不符而拒绝，测试没有运行；官方原地址的宿主下载也返回504。为同一官方发布地址添加本轮查询参数后重新下载，SHA256准确匹配依赖源码固定值266af998cb9e119ef4f61414e7ae0b77c10144a8e45ba27eff3fc3cb9eb60e41，随后只读挂入hooks缓存，由原校验再次确认后运行通过；未改校验值或关闭TLS。日志owner-byte-intake-core-tests.log、owner-byte-intake-storage-tests.log、linux-owner-byte-intake-tests.log、linux-owner-byte-intake-retry.log、linux-owner-byte-intake-verified-cache.log、owner-byte-intake-ui-regression.log。临时依赖文件在忽略目录local/server-first-stage/sqlcipher-linux-arm64.download，最终清理时可移除，后续容器复验可继续使用已校验缓存。

接续：上传与原文需要独立的受认证传输和容量限制，不能复用2MiB普通JSON限制冒充10MiB文件支持；Agent已有import-file/submit/status及加密上传去重可复用，必须绑定原设备及聊天。文件领取要在CLI所在设备用真实NativeInformationDeliveryFiles生成并跟踪副本，不返回服务器路径。服务器需要持久核对原文件许可，普通重启不取消有效许可、已结束或撤销不恢复。不要简单在服务器启用原本机文件驱动再把其路径交给CLI。


## #97 文件上传、原文预览与版本写入已接通；领取和本机动作仍待完成

OwnerWorkspaceFileStages、原文件导入/替换/恢复、历史原文读取及提案原文读取抽到 info_workspace；原桌面路径保留 re-export 或薄包装。提案仍按原版本、阅读确认及整份保存规则处理，原预览改用共享字节读取和桌面渲染，没有另造入库规则。新增用户专用文件上传/读取/版本接口，10MiB原文件有独立容量入口，其他请求仍保留2MiB限制。原文传输包含长度与SHA256核对；App使用本机文件选择和原渲染器，服务器路径不作为客户端路径。

AgentGateway开放原import-file上传、查询及普通附件新增/修改，不开放凭据材料或下载能力。CLI保留服务器返回的字段填写错误。原文由受认证用户提案接口返回，普通提案DTO只有文件说明、版本和关联。正常App已连接文件导入、Markdown预览、替换、选旧版恢复和关闭重开；真实CLI提交带两版原文的提案后，正常App直接预览并整份保存。这里的CLI为正式AgentClient.remote调用，还不能代替最终匹配候选的独立可执行进程文件领取验收。

另外复用原多附件表单事务和旧模板投影：服务器核对原模板身份/版本、附件选择和关联，多份原文与文字一起保存。RemoteWorkspaceSource接旧模板读取及转换预览；原不支持文件字段转换成声明插件的限制保留，未为了测试虚构插件文件字段。错误模板版本或重复使用同一附件选择都不产生半条资料，成功后重开可核对各原文字节。原保存回执在附件暂存消费后仍可查询、重试，不能靠重新暂存来声称原保存成功。

用户上传暂存按既有Agent未提交上传的30分钟窗口回收，仅影响未保存上传，不影响正式文件、已提交提案、持久操作回执或任何访问许可。用单调计时避免系统时间回拨拖延清理；服务器每分钟在原串行队列清理过期暂存，正常请求也先清理。App关闭时一次批量释放已选择及结果未知的上传，失联则由服务清理。不再让上传/取消记录永久累积到512后错误提示重连。真实SQL删除失败曾暴露临时选择先被忘记、无法重试的问题，现保留不可再次使用但可重试清理的选择，清理成功才释放；故障注入已复验。

本轮证据见 [#97阶段记录](../../development/evidence/server-a07/README.md)。当前#97没有完成：App另存、本机打开及其本机持久操作记录、Agent获批下载、受管副本回收和文件许可重启恢复仍待接通。不能直接启用服务器本机文件驱动后将服务器路径交给CLI。后续应复用原_fileRequest授权校验和真实NativeInformationDeliveryFiles；服务器记录交付与原授权，本机才持有复制路径/清理证明。现有InformationFileOutputs/Opens与加密库私有操作日志耦合，需要抽出可供客户端使用的私有操作记录接口，不能在客户端建一份资料库冒充联网模式，也不要用假lease骗原交付状态。

当前#91–#96已关闭，#97保持打开，#98–#102未完成；无统一候选、正式安装或真实迁移。#103–#105不动。本轮所有测试进程结束后临时目录/容器按各自teardown回收；开发日志及已校验SQLCipher缓存仍在忽略目录local/server-first-stage，最终统一清理。


## #97 本机另存、打开和独立操作日志已接通

InformationFileOutputs / Opens 抽出私有日志最小依赖，旧资料库适配保留原表和跨操作检查；DeviceFileOperations只建本机操作与服务器身份两张表，以独立密钥SQLCipher加密，不建立客户端资料库。默认密钥为本机私有目录700/文件600，不调用个人钥匙串，与服务器资料密钥和Token分开。锁、服务器身份、密钥丢失、宽权限和符号链接检查已验；不能把失效记录当作空白重置。

原另存/打开协调器通过WorkspaceFileActionContext复用：旧Owner保持原屏障，远程客户端取实际原文、核对字段/版本，在本机使用原生发布与受管副本驱动。RemoteWorkspaceSource和正常OnlineDesktopLauncher接原菜单及恢复/清理入口，按服务器身份隔离本机日志；关闭Future可重复等待，清理打开副本但不删除用户另存文件。当前本机操作检查服务器文件和普通资料操作回执；#100接生命周期操作时仍需补相同操作编号的冲突核对。

Mac设备日志2项、原动作加远程流程21项、加强服务器变更/面板竞态1项、正常联网界面完整流程1项通过；Linux ARM64服务两个文件场景加设备日志加密/锁/身份场景3项通过（Mac原生动作未在Linux运行）。相关静态分析通过。证据见[#97阶段记录](../../development/evidence/server-a07/README.md)。测试驱动曾在假时钟内直接等待关闭，定点终止后改为持续推进时钟观察真实退出，未跳过断言；具体合成残留已清理。所有本轮测试进程均已结束。

下一步仍为#97的Agent获批文件领取和本机持久受管副本：复用原_fileRequest、字段版本、不可扩大的授权与原NativeInformationDeliveryFiles，不用服务器假路径或dummy lease。OnlineInformationRuntime目前仅恢复文字/原会话授权；原本机InformationFileDelivery模型把ready和本机lease绑定，需要显式区分远程准备、原文交付和本机完成结果，保留原操作编号及状态核对，不让网络重试或普通重启重复生成副本或复活已结束/撤销授权。CLI需跨进程保存私有本机交付/清理记录；不能仅修改servercapabilities声称已支持。

#97仍未完成，#98–#102继续保留；没有统一候选包、日常安装或真实迁移。#103–#105不动。浏览器仍先复用11/p1。


## #97 服务端设备交付和重启授权已接通，CLI本机桥接待完成

InformationFileDelivery增加可选deviceDelivery=true，仅服务端记录使用，lease始终为空；本机模式仍要求真实lease。服务器先保存preparing及固定附件版本，专用download复用原授权检查和与本机共享的原文验证；设备complete核对长度/摘要后ready。release/撤销/结束/到期进入cleanup_pending，设备cleanup确认后才终止。cleanup允许原已结束会话确认自身清理，但不授予原文读取能力；AgentGateway仍按原设备绑定会话证明核对，另一设备或聊天不能确认/读取。普通回复无服务器路径或原文，专用下载可返回10MiB原始字节。

普通重启保留原操作、准备/成功状态、批准字段和原期限；OnlineRuntime关闭前排完现有文件核对队列，不在关闭时把远程副本标成已清理。设备记录写入时把真实服务库标记升到54，旧读者拒绝；已有server_runtime_state存在才能写设备记录。原便携历史白名单不带设备标记或证明，恢复后runtime=false。没有新增服务器本机文件驱动或dummy lease。

Mac在线存储10项、原交付/审批29项、真实HTTPS设备场景1项、完整服务22项通过；Linux ARM64完整服务+在线存储32项通过，相关分析通过。HTTP场景真实走用户审批接口，明确协议2及文件版本选择。一次新增当前字段版本检查破坏了原“旧操作保留旧字节，新操作读取获批字段当前版本”规则，已修正并新增远程替换/重开测试，未放宽原测试。证据见[#97阶段记录](../../development/evidence/server-a07/README.md)。

下一步具体入口：packages/info_cli/lib/information_file_client.dart目前直接返回服务回复，缺实际本机文件桥接；info.dart --connection和codex_info.dart需提供隔离持久本机状态目录。不能因服务端metadata说ready就输出路径。需真实NativeInformationDeliveryFiles、按服务器/设备/原会话及操作记录的私有副本登记、跨CLI进程核对、只有校验完成且原许可仍有效时返回本机路径。JSON-lines进程退出及一次命令的Codex封装退出不应立即删除仍在聊天中使用的副本；CLI之外的到期/撤销/根结束清理需要本机执行程序看护，App不必开着。可研究复用runtime_worker和原本机材料看护，不靠只在下一次命令才清理来声称自动回收完成。

CodexEndIndex的现有安全约定必须保持：end-only索引不能保存可读会话证明、grant或association定位；不能按公开聊天ID恢复读取能力。现有cleanup接口需要原sessionSecret，活着的执行程序可在内存中持有它核对和清理；若根结束/崩溃恢复需要独立清理确认，应使用仅能结束/清理的证明或经原endCapability的专用清理路径，不把sessionSecret偷偷写进end-only索引。关联文件只通过原准确私有引用读取。#102还需SDK-free候选和无上下文Agent真实试用。

当前#91–#96已关闭；#97仍打开；#98–#102未完成，#103–#105不动。最新统一候选尚不存在，未动真实资料、个人钥匙串、日常App或Windows CI。浏览器先复用13/p1。

本轮设备交付后端代码已推送d279e8d5，#97进度评论已回读确认，保持打开。浏览器11确已不存在，清单只有用户空间0；依既有授权重建同名工作空间13/p1，后续先复用13，不借用户页面操作。

## #97 完成自动验收，#98接续

已推送7a8698dd。正式CLI现用原NativeInformationDeliveryFiles实际生成副本：空文件身份登记在写入前落盘，校验原字节、服务器complete及最终许可后才返回本机路径。现有runtime-worker内部看护模式在CLI退出后独立运行，不要求App打开；释放、撤销、结束、到期或网络状态不明时先物理清理再确认。仅清理证明留在私有设备登记，不保存可读聊天证明，不修改CodexEndIndex或按公开聊天ID查关联。观察超时不重复启动或下载；已确认看护死亡后，下一次普通CLI维护可按原身份补清，原聊天结束也可完成。

服务端watch/discard仅核对原设备及该副本证明，不能获取原文/恢复会话/扩大范围，普通状态/历史/备份不含证明；正常fetch及内部download/complete才交付。格式55对54的既有非终态设备记录一次补入证明，不改操作、版本及期限，禁止轮换。新增领域说明见ADR0027。

Mac完整服务23项、Linux ARM64服务加在线存储33项通过（Mac本机场景1项平台跳过）；Mac在线存储11项、真HTTPS证明场景1项、原交付/混合审批25项、原CLI及Worker专项8项通过（10项原平台条件跳过），相关分析通过。最终加强后的独立CLI场景47秒通过，实际核对跨进程/同客户端并发返回同一副本、服务重启原字节/路径保持、释放/撤销/结束/到期后文件消失、看护崩溃且聊天结束后的补清、篡改拒绝与错误身份不误删且无关查询可用。全部已返回路径最终不存在，无遗留看护或测试容器。完整证据见#97记录。

#97完成评论已发布并回读，关闭状态及Reopen issue入口已观察确认。当前#91–#97已完成并关闭；#98正文、评论与关系已读取（前置#96已完成，后续#99/#100），下一步接凭据录入。未生成统一候选、未替换日常App、未动真实资料/个人钥匙串/Windows CI，#103–#105不动。浏览器仍13/p1，当前停在#98，不finish整个工作空间。

#98现状：共享OwnerWorkspaceProposals已保留原凭据预览/原子入库规则，但OwnerProposalRoutes缺内联密码补填路由，AgentGateway仍整体拒绝含credential提案。现有OwnerWorkspaceCredentials/OwnerCredentialStaging还在apps/desktop，除SelectedCredentialFile输入类型外主体为纯Dart，应抽到info_workspace并保留桌面包装，复用原OwnerAccess.saveCredentialRecord及幂等回执；服务端不启用本机执行或系统钥匙串。RemoteWorkspaceSource目前无凭据管理适配。需先接共享保存规则、受认证材料暂存/管理、提案内联密码及原UI，实际使用仍由#99接续。

## #98已抽取原凭据管理/暂存，联网入口仍待接

OwnerWorkspaceCredentials和OwnerCredentialStaging已抽到info_workspace，桌面原路径重新导出；SelectedCredentialFile成为共享纯输入，原生picker/readCredentialFile仍留桌面。原Unavailable继承中的4个不支持入口在共享适配中明确保持不支持，未新增演示或Owner申请功能。原保存、编辑、更换、停用、分类关联、回执和材料清理规则保持同一实现。

原桌面凭据工作区26项通过；共享适配在真实OnlineRuntime/SQLCipher中Mac和Linux ARM64各1连续场景通过，核对原材料、重复原操作、说明编辑不改材料/代际、更换及停用、分类关联重开、取消和加密文件无明文。共享包和相关入口分析通过。详见#98阶段证据docs/development/evidence/server-a08/README.md。本轮所有测试终止、无遗留容器或看护。

下一步应在Owner专用认证路由接共享source的材料暂存/管理及元数据编解码，复用原16份/1MiB文件/64KiB字符串限制和未知回执规则，处理上传去重、关闭/过期清理；临时材料只在私有内存及原SQLCipher，不给普通Workspace DTO加正文。OnlineServer的普通管理正文上限2MiB已经足够1MiB文件Base64，无需放宽普通上限。后接RemoteWorkspaceSource.credentials与Host输入，打开正常创建能力。随后接Agent凭据提案及提案内联密码，继续原整份入库事务，不先关闭#98。

内联密码当前在apps/desktop/lib/workspace/owner_proposal_password_input.dart：OwnerProposalPasswords以私有TextEditingController保留输入、显示/隐藏，store调用OwnerAccess.fillImportCredentials一次修订整批密码，然后Controller重新核对整份提案保存。ProposalPasswords是Flutter Host接口，不是Workspace DTO。联网改造应复用同一输入组件并注入保存/初始输入边界，而非复制UI；保留失败输入、版本变化和密码不进入普通提案/目录/回执的约定。

## #98 用户凭据保存及正常App已接通，AI提案待续

OwnerCredentialRoutes已在OnlineServer原Owner认证及运行队列中接inputs上传/原操作查询/取消、candidate释放、save/enabled、详情/材料历史和持久回执，普通Agent设备凭证不能管理。共用原OwnerWorkspaceCredentials；暂存限制16份/16MiB、输入元数据512份，单调30分钟释放、早于上传的取消和Host关闭清零。候选/详情/回执不含材料，字符串64KiB/文件1MiB，普通2MiB请求上限不变。Host周期清理现同时顾及文件和凭据暂存，文件关闭失败仍清除凭据暂存。

新增CredentialInputStaging Host接口，原生/远程共用原密码/文件输入组件；异步输入关闭时取消准确操作，迟到结果释放。RemoteWorkspaceCredentials保持原上传/保存编号，未知结果先核对原回执，查询失败不重做。正常OnlineDesktopLauncher已接“添加凭据”、更换、编辑和停用，分类创建能力已开启；摘要补凭据元数据，原生/远程/服务器的凭据WorkspaceDetail共用投影。实际使用授权仍未接，AgentGateway继续拒绝尚未完成的凭据提案。

Mac受认证HTTPS、共享保存、暂存清理3项通过；完整服务Mac26项、Linux ARM64 25项通过（Mac真实文件驱动1项平台跳过）。正常联网App加原凭据工作区及真TLS丢回复恢复28项通过；相关静态分析通过。UI场景从正常入口保存、替换、停用、文件保存、关闭重开并核对列表/版本/原字节；系统密码编辑和文件面板仅替代其合成边界，留#103原生验收。测试曾过早输入空名称、在假时钟里等待真实Future而停滞，均修正测试驱动而非放宽产品校验；两个定点中断进程已确认退出，合成目录已核对清理，生产临时诊断已移除。详见server-a08证据与日志。

下一步#98剩余：接Agent字符串/Token/凭据文件提案（现有CLI credential_import_client已有1MiB文件读取及contextExposed规则，但Gateway未宣告credential-import.v1），保持生产动态模板；复用原整份保存和预览。内联密码应复用OwnerProposalPasswords的输入组件，将私有初始化/保存边界适配到Owner认证接口；不要把密码放进普通提案DTO、状态或Agent回执。特别处理fillImportCredentials会产生新提案修订：丢回复不能简单拿旧版本重填或猜已完成，需要按实际持久结果核对；必填缺少仍整份不入库。随后验证Agent提案→App补填/整体保存→加密重开→准确关联，才关闭#98。#99–#102未完成，#103–#105保持后置，无统一候选、正式安装或真实迁移。

本阶段代码已推送16a714fe，GitHub#98阶段评论已发布并回读，保持打开。原浏览器13已确认不存在（库存仅用户空间0），按用户既有授权重建同名工作空间15/p1并读取最新#98正文、评论及关系；后续先复用15，不询问重建页面，不操作用户空间。当前没有活跃测试/看护进程或测试容器。


## #98整份凭据提案完成自动验收

正式AgentCLI现使用当前动态模板提交字符串、Token与文件凭据及同份服务关联，contextExposed和owner占位规则保留。正常App复用同一OwnerProposalPasswords与内联输入、显示隐藏；专用受认证Owner通道保存输入，Agent设备Token不能读取。整批密码修订和私有回执共用SQLCipher事务，失败回滚；普通提案DTO、目录、Agent输出及便携备份没有原文/私有回执。普通重启保留原操作；备份继续不包含待处理提案输入。

丢填写回复先查原操作；查询失败保持原输入，不重复写。Controller可核对私有填写未知，成功只恢复整份审阅，确认不存在才允许明确修正/重试，不自动入库。正常App连续场景已完成手动管理及AI服务+两个待填密码+Token提案，一次保存后准确关联并重开取回；缺任何密码此前均零入库。

Mac完整服务和密码/状态存储32项通过；Linux ARM64同组31项通过，Mac原生驱动场景1项按平台跳过。正常联网UI、原整份密码规则、Mac输入边界和真TLS丢回复恢复5个连续场景通过；原核心11项通过。另有文件释放关闭竞争确定性专项1项通过：原已确认清理才接受原结果，未知/不同身份不猜成功。相关静态分析通过，详见server-a08证据。系统原生密码输入和文件面板仍为合成边界，未声称#103通过。

本次回归修正两个旧“credential未接通”的测试预期，原缺模板快照仍拒绝；文件重启测试区分原许可有效与网络未知时副本先清理。进一步发现并修复已清理后台关闭控制端口与CLI释放的竞争，最终完整服务32项通过。此前失败日志保留作为过程证据，不记全绿。

下一步#99应先处理服务端许可持久性与设备端执行边界，不能直接开放旧本机协议：当前OnlineInformationRuntime明确跳过credential请求；旧Core会在服务器核对本机路径、PID、进程组并为文件创建本机lease，CredentialExecutionHost只连接loopback App。应复用原申请/批准/失效/逐次操作规则，将执行、路径核查、材料准备、受管文件清理留AI设备端；服务端不得代执行或相信远程PID为服务器PID。需同时持久绑定原聊天/原设备和操作结果，普通重启不延长授权，未知启动不重复执行。随后接#100回收/历史、#101完整备份、#102统一匹配候选与无上下文Agent试用。


## #98回填完成，#99接续事实

2d58379b与5cd1c379已推送。GitHub #98完成评论已回读，Closed及Reopen issue入口已观察；不是只在本地标完成。所有本轮测试进程和容器已结束，无临时文件看护；两份构造失败遗留的空device-release-race目录已按准确路径rmdir。分支仍独立，尚无统一匹配候选。

#99正文、标签、评论和关系已读取；前置#98完成，后续#101依赖它。本机执行仍未接通，不能关闭#99。接续需先解决以下实际耦合，再开放能力：

- 接续前OnlineInformationRuntime._encode的version2明确省略_credentialUseSessions对应请求，也不保存该私有绑定及执行证明；credential混合普通字段的已批范围同样被跳过。需要恢复原聊天/设备/有效范围与原期限，不能只凭历史生成授权。恢复的备份记录有restoredAt，不能当活动许可。未知审批的_inactiveCredentialApprovals也不能因重开消失而复活。
- CredentialRuntimeAgentAccess._resolveCredentialPlan在服务进程里检查可执行文件和cwd，begin/register检查服务器本机PID/组；_claimUseExecutionMaterial对file在服务器创建ManagedCredentialFiles。联网模式必须把这些身份、路径和物理文件核查移到AI设备，服务器只核对原授权与逐次操作，不能将远程PID当本机PID。
- CLI _claimCredentialOperation及_consumeCredentialMaterial对_remote直接拒绝；CredentialExecutionHost只能创建loopback AgentClient，Codex逐次调用依赖旧App宿主。需要复用同一执行器、进程组/先登记后启动和有界输出，实现App退出也可工作的设备宿主；仅清理/控制登记不能保存可读聊天证明或按公开聊天ID恢复。
- 所有后续操作与私有材料交付都要绑定原Agent设备及原聊天，重试先查原操作，未知不能第二次启动。服务重启、设备断线、聊天结束必须区分；普通重启保留有效许可，撤销/停用/材料变化阻止后续使用。原已执行外部结果不承诺收回。

下一步先实现和验证在线凭据许可的持久绑定与可信设备执行边界，再接App统一审批、正式CLI和独立合成接收程序/SSH服务；不要直接把旧AgentProtocol的credential-use路径全部加入Gateway白名单。Mac焦点填充仍按#51，其他平台/跨电脑实测仍后置，不扩大后置范围掩盖本轮所需SSH/Token/文件使用。


## #99设备申请及持久绑定已接，实际执行仍待续

新增DeviceCredentialLaunch私有Host快照及requestDeviceCredentialUse，共用原申请与接收方式规则，服务器不再为该入口检查设备路径/cwd。原认证网关从原设备身份进入内部credential-use/device/request，正文不能选择deviceId；不同设备不能借原会话或字段证明接入。正常status/claim及用户审批接口仍复用。未宣告credential-use-reuse.v1，正式CLI联网run-use仍未接，不关闭#99。

独立服务和服务夹具改用EncryptedInformationRepository.openOnline保留事实，默认open保持旧本机行为。私有textRuntime3保存原设备/聊天绑定与未确认决定禁用状态；完整混合字段范围、原证明和期限可重开恢复；事务已提交而快照未发布时仅恢复准确已批范围。到期观察持久，时钟回调不复活，撤销/结束/停用/更换不恢复；SSH会话内不限时可跨天及普通重启，真实结束后失效。便携恢复不带绑定；损坏状态拒绝且不覆盖证据。历史清理/备份替换同时清绑定。

审批元数据补完整v2 codec（凭据接收程序、工作目录、参数、方式、版本、聊天、期限及执行观察）。正常RemoteWorkspaceApprovals改用显式Owner details/<id>路径；旧v1继续拒绝凭据，避免旧客户端默默丢掉说明。版本未知、不完整或夹带私有证明拒绝，不把Core私有运行对象直接序列化。当前HTTP合成审批通过，凭据UI完整验收仍随执行链完成。

阶段证据见docs/development/evidence/server-a09/README.md：设备申请HTTP前的服务/状态回归Mac52、Linux51通过（Mac驱动1项跳过）；新设备HTTPS、元数据及原网关/审批Mac/Linux各5通过；原正常App审批/丢回复2通过；核心27通过。原生默认DeviceCredentialLaunch.prepare实际对本Mac固定gh/aws及系统ssh三种预检通过，仅验证预检，不是实际凭据任务。相关静态分析通过。原探测目录规范路径清理已修正，全部测试/容器/看护结束，无真实资料、钥匙串或日常App操作。

下一步#99剩余：设备常驻执行宿主（App关闭也工作）、逐次操作/私有材料交付、SSH信任设置、进程/文件身份留客户端、实际合成SSH/Token/文件接收与清理、原操作不重放、凭据UI连续试用，以及未确认审批重开后的原回执处理。当前device_credential_access只覆盖请求和绑定维护，不能把老credential-use/operation/material/register路径直接放行。执行证明/设备清理登记仍需设计/实现，不能将其写入CodexEndIndex或按公开聊天ID恢复能力。

本轮GitHub工作空间已恢复为17/p1，#99最新正文、评论、标签及关系再次读过，前置#98已关闭；原15确认不存在，未操作用户空间0。所有本轮进程/容器/看护均已结束，阶段代码635a71c4已推送；#99阶段评论已发布并回读，Open/Close issue入口确认，不能结束整体目标。


### 下一阶段的准确入口

CLI当前packages/info_cli/lib/credential_runtime_client.dart的_claimCredentialOperation与_consumeCredentialMaterial仍对_remote直接拒绝，CredentialExecutionHost只创建loopback AgentClient；不要把本次申请接口当作执行接通。现有CredentialExecutionMaterial.file要求本机lease，Core旧_claimUseExecutionMaterial在服务机创建它，registerCredentialMaterials/report/cleanup及worker登记核查本机PID/组。设备执行实现应复用进程组、先登记后启动、原输出过滤和有界输出，明确把材料准备与进程身份检查留设备；服务端只核对逐操作许可与原设备，绝不能用旧server路径/本机PID验证远程设备。

本机已验证可用预检工具在.tools/gh-2.102.0/gh_2.102.0_macOS_arm64/bin/gh、.tools/aws-cli-2.38.1-package/aws-cli.pkg/Payload/aws-cli/aws和/usr/bin/ssh；不表示它们已经用于真实凭据任务。Native预检默认实现三项通过记录在a09-native-device-preflight.log，脚本为忽略目录local/server-first-stage/device-preflight-probe.dart。后续实际使用仍只用合成接收程序/SSH服务和测试凭据。

当前同一浏览器工作空间17/p1停在#99，未finish整体目标。工作树已提交，无测试容器、看护或活跃测试句柄；#99–#102未完成，无匹配候选、正式安装或真实迁移，#103–#105不动。


## #99设备操作与长驻CLI实际执行已接

本轮新增设备私有操作/材料/worker/报告/清理路由和credentialRuntime2执行证明，服务器不创建明文临时文件、不查设备PID。首次材料只经Host私有回复交付，后续原编号返回元数据；丢回复、存储事实与私有快照之间崩溃不会重发材料或第二次启动。CLI复用原原生执行器和输出过滤，DeviceCredentialJournal只持久保存原操作清理/控制能力及OS身份，不含sessionSecret、材料或输出；公共聊天ID和CodexEndIndex不承担恢复读取能力。

Mac长驻CLI已用真实原生worker执行Token和文件合成接收程序，工作目录及输出过滤检查通过；杀死独立CLI进程后保留仍运行的材料，进程组结束后清理并如实记录未知。真实系统ssh连接新建Docker测试账号，不使用本机个人SSH文件/账号shell；原会话SSH许可跨服务重开，撤销/聊天结束阻止新操作、原操作正常退出并清理。所有材料仅合成。

实际检查：设备HTTPS专项Mac/Linux各8通过；Mac原生Token/文件/崩溃/丢回复4通过，真实SSH2通过，严格登记校验后联合复验6通过；服务整组回归37通过（SSH测试新增前），核心27、存储20、CLI21通过（9项原平台条件跳过）。本轮服务端/CLI相关分析无问题，Core全lib只有未改builtin_information_definitions.dart:7旧提示。准确范围和日志见docs/development/evidence/server-a09/README.md。

**#99仍未完成。** 下一步复用CredentialExecutionHost接逐命令Codex的独立设备宿主（目前hosted=true仍向旧服务路径请求，在线拒绝，没有本机fallback），保留全局16执行/30分钟已结束输出限制。通过私有loopback控制和内存bootstrap传session，不能写可读聊天证明进磁盘。随后接正常App的SSH信任管理、完整凭据审批连续试用及未确认审批重开原回执恢复。再接#100–#102；#103–#105不动。没有统一候选、正式安装或真实资料迁移。

本轮实现及证据已提交并推送902ab7f3。GitHub #99阶段评论已发布并回读，页面仍提供Close issue且本票Open；没有关闭。浏览器仍为17/p1，不结束整个持续目标。原生联合6项最后复验通过，所属所有测试进程、原生worker和SSH容器均已退出，无个人资料或日常App变更。下一轮从上段设备后台宿主接续，不重做已通过的私有操作层。


## #99逐命令Codex后台已接

DeviceCredentialHost复用CredentialExecutionHost，独立CLI通过原聊天证明和私有回环控制共享执行/有界输出。后台记录不含sessionSecret、材料、输出，原16条/30分钟限制不变，命令在AI设备执行。独立启动锁和生命周期锁阻止超时、状态丢失时重复启动；原配置摘要和进程身份均核对。共享RuntimeWorkerCommand同时服务凭据worker和普通文件看护，SDK与独立可执行文件正确选择。

实际检查：Token及文件2个真实多进程Codex场景通过，包含竞争、共享输出、跨聊天拒绝、服务重开、丢接受回复和丢记录不重放、回环门禁与活动执行停止保护。相同场景用编译的info-codex/info-runtime-worker再次2项通过；后台ps核实为独立worker而非Dart SDK。原CLI18项通过（6项平台跳过），直接原生Token/文件/SSH6项通过，正式普通文件CLI及文字Codex2项通过。相关CLI与新增测试静态分析无问题。证据详见server-a09 README。

**#99仍未完成。** 下一步提取原OwnerWorkspaceHosts的纯Dart信任/导入/版本和回执逻辑到info_workspace，App保留薄文件选择封装，服务端复用同一投影接Owner接口；RemoteWorkspaceSource接原主机设置和预览界面，避免另造最小信任界面或在服务器探测网络。随后完成凭据审批连续试用、未确认审批重开回执处理，再推进#100–#102。#103–#105未动。隔离二进制不是统一候选，尚无正式安装或真实迁移。


后台实现及证据已推送5391519e，GitHub #99阶段评论已发布并回读，仍Open/Close issue。补用同一独立客户端/worker验证文件命令完成时服务完全关闭：设备先物理清理并保留准确终态，原服务重开后正常状态查询补交原回执和清理确认，2个Codex场景通过且无重跑。日志a09-device-host-offline-standalone-tests.log。独立验证包manifest已记录源码提交与两文件摘要；没有替换日常App。所有本轮测试进程/后台/容器已结束，下一步仍为SSH信任管理和凭据App连续验收；#99–#102未完成，#103–#105不动。


## #99正常App主机信任及SSH/Token审批连续流程已接

原OwnerWorkspaceHosts共享到info_workspace，App仅负责原生文件选择/稳定读取，OwnerHostRoutes和RemoteWorkspaceHosts复用指纹、版本、确认/撤销及持久回执，原主机设置/导入界面接正常OnlineDesktopLauncher。预览与客户端本次所选文件的摘要/长度/名称对应，服务端重新核对完整预览；暂存32份、固定30分钟，不在服务器操作设备路径，不给Agent管理权限。普通HostFile导入/撤销丢回复经准确原回执恢复，未知不重复提交。

真实界面测试发现server workspaceObservation遗漏凭据申请，App开着时看不到AI新申请；现将凭据元数据、申请/授权状态、执行和SSH信任事实加入原变化标记，正常App自动刷新。SSH材料显示为凭据文件、-i注入位置，主机指纹不误称只支持ED25519；导入提示和重启授权提示均改为准确描述。窗口销毁释放网络异常有处理，暂存仍按原期限清理。

实际：正常App导入/预览/确认信任，撤销与再确认，AI的SSH申请出现在待办，选择会话内不限时并批准，关闭App后由当前源码编译的独立worker启动真实系统ssh连接独立Docker账号；重开App审批Token30分钟再关闭，接收程序实际执行、输出过滤与材料清理均通过。相关App/丢回复/原主机和插件回归35项通过；服务包Mac43项通过，Linux34通过9项Mac条件跳过；相关静态分析无问题。证据见server-a09 README，完整日志a09-owner-host-app-final-tests.log、a09-owner-host-mac-server-suite-fixed.log、a09-linux-owner-hosts-full.log。初次Mac整组2项默认30秒超时，明确连续场景3分钟后通过，逐步等待/原操作核对未放宽，不把首次失败算通过。

**#99仍未完成。** 下一步处理原决定结果不明跨进程恢复：Core的_inactiveCredentialApprovals已持久，_uncertainCredentialDecisions闭包没有原operationId→request的持久结算对应；确认提交的旧批准仍禁用，混合撤销也要核对。建议在线模式记录准确原InformationApprovalReceipt命令意图，核对原回执而不是历史或新操作，验证原设备/聊天、批准范围、固定期限/会话状态及材料代际后结算，不改变旧单机诊断行为。approve未提交/已提交、混合字段、revoke、重开损坏状态分别检查；现有旧版无意图的inactive记录不能激活。完成后核对capabilities（当前仅credential-device-execution.v1，旧reuse及SSH期限能力尚未宣告）和当前平台说明，再关闭#99并推进#100–#102。没有统一候选、正式安装或真实资料迁移；#103–#105不动。


## #99最终审批恢复及首次后台竞争收尾

2026-11-09。credentialRuntime3持久保留原AdditionalApproval命令，只按准确回执和SQL事实结算；失败查询保留禁止使用状态而不影响无关操作。批准/撤销的已提交与未提交、混合字段、原范围/期限、聊天结束/过期后再次重开、停用/材料更换、坏命令和矛盾缺失回执均验证。旧单机规则及无原意图的旧禁用记录不激活。App的真实TLS丢批准/撤销回复经整套服务重开后只核对原决定，不重复提交。正式能力宣告device-execution/reuse/SSH-session，Mac焦点填充仍不宣告。

整组发现并修复真实首次竞争：privateDeviceFile的exclusive create只在errno17且另一方留下普通文件时接受，仍拒绝链接和其他I/O错误，不截断锁。32并发专项先在旧代码复现，再通过；原两个独立Codex进程竞争的Token/文件场景保持原严格断言并通过。扩展混合撤销期间结束聊天还发现历史可能被旧闭包覆盖，在线结算现按持久事实并保留已发生终态。

最终Mac服务/核心/存储76项通过；Linux ARM64同组67通过9项Mac条件跳过；正常App SSH/Token及丢回复等5场景通过，最后结算修正后审批恢复4场景复验通过（重叠不累加）；CLI私有锁与原执行/过滤19通过6条件跳过；旧核心30通过1条件跳过。相关分析无问题；全Core仅原builtin定义文件大括号提示。详情与日志见server-a09 README，初次并发/历史失败日志保留。所属测试/worker/看护和容器均已结束。

#99本票实现和自动验收完成并已关闭，当前接#100：复用OwnerWorkspaceHistory、OwnerWorkspaceLibraryRecycle和原GrantHistory投影。当前这些App实现仍在Flutter目录，需移入纯Dart共享模块、保留薄re-export和正常UI，再接Owner受认证接口、严格DTO与RemoteWorkspaceSource，避免另造简化回收站。#100还需资料/文件版本、整批目录和凭据、审批/提案/管理历史、原操作回执及正常控件到独立客户端实际验证。已读ADR17/22，不改变长期文件版本保留或整批回收/恢复规则。#101–#102待续；#103–#105不动。没有统一候选、正式安装、真实迁移或个人钥匙串变更。

本轮a027defe已推送origin/codex/server-first-stage；GitHub #99完成评论实际发布并回读，Closed和Reopen issue入口确认，未动后三票。工作树回填当前任务为#100；正常浏览器继续复用18/p1，不finish整体目标。最终各测试句柄均已终结，Docker无运行测试容器，ps无本轮worker/看护/Flutter测试进程。

## #100已开始：复用原历史与整批回收

OwnerWorkspaceHistory、OwnerWorkspaceLibraryRecycle、OwnerWorkspaceGrantHistory及其additional part已移入纯Dart info_workspace。App保留薄构造/重导出；OwnerWorkspaceHistory注入原Owner和现有WorkspaceClassificationInformation。授权历史共享准确文件范围解析，App注入原OwnerWorkspaceAttachmentPreview，原库作用域覆盖解析及渲染；不在服务器执行原生PDF或直接读客户端路径。没有另造回收/历史规则。

原App历史/整批回收/授权/凭据/文件及控件回归30通过；新增纯Dart真实SQLCipher连续场景在Mac及Linux ARM64各1通过：正常用户审批和读取、历史事件、旧版本恢复、目录+资料+凭据批次回收、加密重开原回执去重、整体恢复、凭据停用及旧读取证明拒绝、再重开保持。相关共享/App/服务测试分析无问题。证据server-a10 README。初次语法/测试调用错误日志保留未计通过。

#100仍未完成，下一步OwnerHistoryRoutes及严格DTO：资料/版本/回收批次/回执和GrantHistory查询/快照/历史文件。接RemoteWorkspaceSource当前未重写的历史/回收接口及grantHistory；recordOperationReceipt当前只查询普通资料保存回执（文件和凭据另有专用入口），需要补原InformationLifecycle回执并保持多个存储查找失败不作缺失的旧规则。服务器统一在runtime.run内调用共享模块，用户接口不得放给Agent设备。历史文件只按共享resolveFile核对出的准确原附件读取，参考现有OwnerFileRoutes将字节交客户端原渲染器，不替换为当前文件。补正常UI、真实TLS丢回复、整套服务重开/独立客户端、失败批次及版本/关联核对后才关票。#101–#102待续，后三票不动。

共享抽取及证据已推送01173dc1；GitHub #100阶段评论已发布并回读，仍Open/Close issue，未关闭。继续复用18/p1。当前无本轮运行测试、worker、看护或容器。下一步按上段接真实历史/回收接口和RemoteWorkspaceSource，不重做已通过的纯Dart抽取。


## #100联网回收/版本/历史已达到本票验收

正常OwnerHistoryRoutes接共享历史/回收规则，RemoteWorkspaceSource、RemoteWorkspaceGrantHistory及原凭据changes/recycled入口接通。明确wireVersion1，严格DTO保留类型/目录/关联/版本，旧历史0版本与分页外选择不丢失；设备Token不能访问Owner路径。历史文件按共享resolveFile核对原范围，校验旧交付元数据再交准确原字节，设备仍用原Renderer，不换成当前文件。普通保存及生命周期回执必须各自成功查询，失败不当作没有提交。

真实HTTPS连续验证动态模板/原表单建立关联、文件两个版本、查看原授权文件和快照、恢复旧内容生成新资料版本、单独凭据回收/停用恢复、目录+两资料+凭据整批回收/恢复、整套服务重开及新OwnerClient核对原字节/目录/关联/旧回执。真实SQL触发器中断批次回收/恢复，整组回滚；旧预览后增加资料拒绝。正常控制器实际丢回收、恢复及版本回复，再令查回执失败，保持冻结不重提，服务重开只查原决定。

正常OnlineDesktopLauncher控件完整跑通版本比较/恢复、目录菜单整批回收、回收站整体恢复、授权历史。发现广义延迟刷新使刚加载的恢复预览失效：仅批次控制器重新读取后核对完全相同token才保留预览，变化/失败仍要求核对，绝不自动提交。原目录Widget回归退出时显式等待异步source.dispose，以原SSH测试相同方式清掉真实HTTP假时钟，不删业务断言。

Mac服务整组48通过；Linux ARM64 39通过9项Mac条件跳过。最后补动态模板/关联及事务故障强化检查的5项在Mac/Linux各通过（与整组重叠）。正常App/断线/历史文件/旧批次及目录移动排序整理/表单文件凭据回执联合16通过。相关分析无问题；详情server-a10 README。早期夹具/假时钟/预览实际失败日志保留未计通过。#100实现和本票自动验收收尾，待推送并回填关闭；当前所有测试句柄、worker和容器终结。

浏览器18已确认丢失，按用户授权重建同名19/p1；已重读#100正文/评论/标签/前置关系、核对#99仍Closed，并读#101正文/标签/关系（前置99/100，阻塞102）。随后复用19，不操作用户空间0或finish整体目标。下一步#101需沿原Backup恢复事务，把原生文件选择/输出留设备、服务端只保管加密备份传输和恢复。OwnerWorkspaceBackups当前仍耦合App的InformationBackups/OwnerWorkspaceBackupFiles/NativeBackupFilePicker，先读原规则、完整备份格式与ServerState/身份清理，不能把便携备份当运行许可恢复或绕开原Owner恢复屏障。必须涵盖资料/全部文件版本/凭据/关联/分类/排序/回收/插件/历史、坏包与错误钥匙、非空目标不静默合并、完整合成旧版迁入、容器升级/密钥恢复说明及正常App进度/错误。#102最终统一候选/无上下文Agent及全入口核对仍未完成；后三票不动，未操作真实资料或日常App。


## #100已关闭，继续#101

683ef9fa已推送；GitHub #100最终评论及Closed/Reopen issue已现场回读。#101、#102仍Open。#101先沿原备份格式、恢复事务和正常App控件接联网备份，不把最小恢复测试作为完整迁入完成。#103–#105未动。

## #101 服务器恢复与在线身份接续

新增OwnerBackupRoutes：受认证用户分块上传加密备份、检查原预览、通过原Owner恢复屏障与存储事务恢复，并查询原操作回执。256MiB总暂存、4份上传、16预览、固定30分钟；密钥仅在请求及原预览内存中，不写入暂存或checkpoint。分块重复只有相同字节才接受，校验完整摘要，非空目标不合并。正式server入口已传入原InformationBackups和独立backup-transfers目录；App尚未接。

修复真实在线恢复后原runtime代次不一致而永久不可用的问题：只在原Owner屏障成功使内存代次增加一次、存储产生全新空状态时接续；外部换库/相同代次/非初始或非空状态继续拒绝。恢复后原Owner投影重新绑定，旧设备/聊天许可不能恢复，重复原恢复回执不能清掉新身份。失败恢复保留原库和身份。

Mac最终新恢复/传输4项、原runtime7项通过；相关Mac用户回归9项通过（与最终4项重叠，补强断言前）；Linux ARM64最新源码同组9项通过，无跳过。实际HTTPS+SQLCipher验证单机旧格式、不同密钥、精确资料/目录/标签、两附件原字节、密码及关联、旧授权拒绝、服务重开、真实SQL事务中断与恢复后新设备。详情见server-a11 README。最初Agent未授权应返回状态而非抛异常、待办原始键名断言写错，修正为正式解码器后通过，不算产品通过前的失败。

**#101仍未完成**：下一步服务器加密导出与设备独立另存密钥，接正常App备份控件和原操作恢复；再覆盖全量类型/历史执行/插件/排列/回收及实际进程中断、升级和回退。Linux不能调用Mac专用出版器；设备本机输出应复用原无覆盖发布与私有原操作记录。#102候选/独立Agent及全正式入口还待续；#103–#105未动，无个人资料/钥匙串/日常包变化。

479498c3及前一笔状态记录78ad8d95已推送origin/codex/server-first-stage；#101阶段评论6724815251已发布并回读，仍Open/Close issue。浏览器19/p1持续复用，未finish整个目标。评论等待因GitHub短号由八位转七位而超时，已现场回读实际结果，没有重复发评论。Mac/Linux测试句柄均已终结，Docker无本轮运行容器。

## #101 服务器导出与设备保存确认

复用原InformationBackups加密快照，新增私有remoteOutput回执（不改变便携内容/格式）：密钥在设备独立保存后确认，导出先保存原清单和准确加密原件，分块交付，设备确认后才产生完成回执。已生成与已另存明确分开，结果未知只查原清单；已明确未提交的旧确认不能再提交，已放弃导出不能改成成功。密钥只在明确Owner请求返回，既不写服务端明文临时文件也不放运行state；服务端Linux不用Mac出版驱动。

正常Owner输出接口及status/receipt已接；普通备份操作扫描认识remoteOutput且不误作Mac输出。服务器最多一份待确认导出，上传256MiB、单份导出256MiB有界。重启清理没有存活预览的旧输入，重试新导出前回收无清单输出，终态输出物理清理和回执分离；登记待确认快照跨重启保留。

真实TLS丢生成/确认回复、查询失败及整服务重开后清单不变；生成后修改原资料，再下载并用独立恢复密钥迁入另一数据库密钥的空库，核对两个文件版本原字节、旧资料值、密码及关联。真SQL分别中断密钥确认和导出清单事务，版本和保存标记回滚；明确查询后旧操作不重做；放弃、截断、坏摘要、遗留目录均检查。当前Mac/Linux最新同组各13通过无跳过；原备份存储37通过；相关分析无问题。详情server-a11 README。

**#101仍未完成，下一步App原生另存/恢复适配。** 当前客户端测试仅在隔离目录做普通文件IO，不能代表App正常文件发布：必须复用原Mac无覆盖发布器、私有原操作记录/书签和原BackupController及控件，持久记住设备端已保存而服务确认未明的操作；不能把服务器准备完成显示为本机已保存。输入路径和原生选择留设备，备份输入分块上传、密钥仅请求/预览内存。随后全类型联合、执行历史、实际进程中断及容器升级/回退；再接#102全部入口/统一候选/无上下文Agent。#103–#105未动。

导出实现e8617d72已推送；GitHub #101阶段评论6725114684已发布、重新加载回读，仍Open。所有本轮测试/推送句柄终结，Docker无chiyo-a11运行容器。继续复用19/p1，未finish持续目标。客户端接续时先读DeviceFileOperations、InformationFileOutputs、WorkspaceFileActions及OwnerWorkspaceBackupFiles，避免将256MiB备份伪装为10MiB普通附件或另建本机资料库；本机只保留必要操作/发布记录，不把恢复密钥放偏好或日志。

## #101 App 原备份控件与原生发布已接入

RemoteWorkspaceBackups接原WorkspaceBackupSource、BackupController/Page与输入选择器。原OwnerWorkspaceBackupFiles共用选择登记，RemoteSource及OnlineDesktopLauncher正式入口已连好。输入文件留设备，分块上传；App不持有本机资料库。

新增DeviceBackupOperations元数据记录：共用DeviceFileOperations的SQLCipher、锁、服务器绑定及私有密钥，新增版本2的backup_operation_state/device_backup_intents两张操作表，旧文件回执保留且绑定在迁移前核对。InformationBackups的操作/暂存函数改用同一db字段；完整资料功能仍要求真实Repository，设备上下文明确不支持。原prepare/publish/reconcile/书签/cleanup状态机全部复用，设备钩子只核对已固定的远程摘要/长度/统计；操作记录不保存恢复密钥或原文字节。服务器命令版本与设备原生版本分开。原生写入新增同一私有写入器的备份256MiB入口，普通附件10MiB不变，已实际验证18MiB发布。

发现并修复原控制器source事件与写入最终刷新竞争，合并在途load并等待最新状态。实际正常App设置界面完成创建/另存密钥、导出、再接空服务器预览/恢复/回库；真HTTPS+SQLCipher+原Mac发布运行，文件面板替换为合成路径，没有computer use。丢恢复回复/失败查询/App及服务重开只查同一次原恢复；已发布密钥确认未知只补发确认，不重复写；已有输出、书签丢失、取消重选、原inode核对均通过。

最终App相关34项通过（新控制器4+UI1+原检查29）；存储/原操作/原Mac发布62通过（含新7）；Linux服务/设备元数据14通过6项Mac原生跳过。相关分析无问题，详见server-a11 README及a11-app-backup-final-regression.log、a11-device-backup-shared-final-fixed.log、a11-device-journal-linux.log。早期import/非const测试构造与实际10MiB边界/刷新竞争失败未算通过。

**#101仍未完成**：接续完整同一合成库逐项核对全部资料/文件及凭据版本、关联、目录标签排序、回收批次、插件/示例及#99真实执行历史；实际进程中断/合成回退；容器升级和数据/运行密钥恢复说明。现有workspace_backups_test有原始完整场景可参考，但不能把它单独当联网联合完成。正常App原生面板本体及人工项目留#103集中检查；#102候选/全入口/独立Agent仍待续，#103–#105未动。

521b7843已推送origin/codex/server-first-stage；#101 App阶段评论6725688772已发布并回读，仍Open/Close issue。19实际丢失后按既有授权重建20/p1，tickets.json已同步。当前测试/推送句柄终结，Docker无本轮运行容器。下一步完整联合应包含超过10MiB的真实加密备份（当前18MiB是发布边界检查），不能降低备份容量以绕开重型导出/检查或OwnerClient默认15秒等待；如实际复现超时，修正长操作等待与原结果恢复后再验。


## #101 完整联合与关闭，转入 #102

实现 5be20a10 已推送：完整合成库经正常 App 备份/恢复，独立只读核对 17 张内容和设置表，并逐字节比较 14 MiB 的两版附件；真实本机程序使用历史保留，恢复许可保持失效。Mac 服务进程和 Linux ARM64 进程均在实际未提交 80 MiB 恢复写入中被 SIGKILL，重开回退并以明确新操作成功恢复。a05→a11 不同镜像升级、停止后持久目录及对应密钥在新目录恢复、旧镜像打开未改旧副本回退均实际通过。维护说明在 apps/server/OPERATIONS.md。

最终 App 35 项、Mac 服务 14 项、Linux 服务 14 项均通过；相关分析、Python 语法及 diff 检查通过，全部工具会话结束且所属容器已清理。日志见 evidence/server-a11。#101 完成评论 6726014563 已回读，Closed/Completed 已经重新加载核实；#102 前置显示 Completed。

#102 开始核对当前 RemoteWorkspaceSource 与原 WorkspaceSource：资料、关联、分类移动排序、插件、提案、文件、凭据、主机信任、回收版本历史和备份均已有远程实现。仍发现 settings、runtime、agents 以及资料模板转换 previewAdoption/releaseAdoption/applyAdoption 沿用 UnavailableWorkspaceSource；这些是已有正式入口，不能临时后置来完成 #102。需要接通设置（本机外观/后台/通知与服务器请求期限/保留策略分别保存）、App 窗口和退出（退出不停止独立服务、不结束其他设备聊天）、Agent 当前设备接入/会话观测。应复用现有控制器和原有安全规则，不把服务端的进程信息当成当前电脑的实际进程。

下一步先读 owner_workspace_settings.dart、owner_workspace_runtime.dart、owner_workspace_agents.dart、settings_page.dart、runtime_workspace_desktop.dart 和 OnlineDesktopLauncher 的现有接线；确定正式入口未接项的准确范围，补服务与设备适配及相应自动检查。随后才建立同源 Linux 服务、Mac App、CLI/native worker 的统一候选，用同一套候选连续试用；最后启动获准的 fork-none 独立 Agent，不透露分类/数量/关联/命令答案。#103–#105 不动，日常 App/资料/个人钥匙串不变。

#102 的初始全入口核对已记录在 docs/development/evidence/server-a12/entry-audit.md，确认缺项包括资料切换模板；它与已接通的旧模板转插件不是同一入口。该记录只是实际缺项与交付计划，不宣称已实现。下一步按依赖补齐设置、运行/桌面、接入观察和模板转换。


## #102 模板转换入口已接

原 OwnerWorkspaceAdoption 和应用写入逻辑移入 info_workspace，App 原路径 re-export，共用相同字段、附件、关联和计划规则。OnlineOwnerLibrary 与 OwnerWorkspaceInformation 实现只读输入接口；原 Source changed 回调保留。新增严格 adoption_transport、OwnerAdoptionRoutes 及 RemoteWorkspaceSource 的三个正式方法。Owner 保存仍用原事务/持久命令，不增加资料表。

修复远程 recordOperationReceipt 漏 adoptionPlanId/类型（原误标编辑）及写入失去回复时需保留 unknown_outcome 的接线。实际代理丢回复及失败查询，再重开整套服务，只查原回执，POST 仍一次。正文和关联不变、附件不兼容被拒、修正后保留原文件身份/版本和原文；取消与并发修改冲突均检查。正常 OnlineDesktopLauncher 的菜单/原转换对话框已真实跑通。

最新相关 App 31 项通过，Mac 服务 6 项、Linux ARM64 同组 6 项通过且无跳过，相关分析无问题。所有测试会话结束。详见 docs/development/evidence/server-a12/adoption.md。新 server integration 组可用 local/server-first-stage/run-a12-adoption-linux.py 重跑；挂载当前 lib/test 到现有 a05 验证镜像及固定真实 SQLCipher，这不是最终候选镜像。

下一步接设置：先读 core 的 desktop_preferences.dart、owner_workspace_settings.dart、settings_controller.dart 及原设置页面；复用原请求期限、历史保留和清理逻辑，但本机外观/通知/后台偏好不写入共享服务器。当前原 DesktopPreferences 把这些值放一个版本/保存事务里，联网需要明确的设备适配及原操作核对；不要用第二份本机资料库或只提供固定默认值。之后接运行/窗口/退出与设备/会话只读状态，不能把独立服务停掉或操作别台设备的进程。最后才做统一候选和获准的 fork-none Agent。

模板转换阶段实现 7243f555 已推送；GitHub #102 评论 6726223028 已发布并重新加载核实正文/提交/持久评论锚点，#102 仍为 Open。工作页 20/p1 保持在 #102，未结束整个目标。测试/分析会话都已结束；当前没有等待用户或外部进程的阻塞。

## #102 服务器设置已接，App 设置仍未接

实现 121883ae 已推送。OwnerPolicyRoutes 接原 Owner.saveDesktopPreferences，只传请求分钟数、保留天数；服务器原外观/通知/后台字段原样保留。正式 bin/server.dart 和 DeviceCredentialFixture 已传入 policyState: repository。其他最小测试宿主可不配置，但不配置时明确拒绝，不回固定假数据。服务观察包含 desktopPreferences.version。

settings_transport 提供 WorkspaceServerPolicy/Change/Receipt 及原清理预览。公开 generation 是私有 ServerStateSnapshot.generation 经带域前缀 SHA256/Base64URL 派生的比较标记，不是原私有代次/能力。恢复换库后，旧同版本命令也拒绝。GET 原操作不存在时，在原私有状态 ownerPolicyAbsences CAS 持久登记（上限10000），防止迟到旧POST；便携恢复不带走。

Core DesktopPreferences 保留旧库有效非预设期限（如47分钟），不允许新设另一非预设值，旧准确回执仍可返回。读取范围保留旧有效分钟数；后续App不得静默改成30或60。实际保留默认90天，不能拿WorkspacePreferences旧UI默认180当服务器真实值。

最终Mac服务12项、存储5项、Linux相同组17项无跳过，原App设置/运行/UI回归32项均通过。相关分析及diff检查通过。所有测试会话结束、所属Docker容器已移除。详情与日志名在 docs/development/evidence/server-a12/settings.md。早期默认期限测试前置错误已修正，原失败不计通过。

下一步直接实现 RemoteWorkspaceSettings，接原 WorkspaceSettingsSource/Controller/Page。可复用 info_cli/private_device_state.dart 的 Mac私有目录700、文件600和同卷原子JSON写入，单文件128KiB。不存资料、Token或凭据，不另开本机资料库。建议状态文件只存已保存偏好、服务器策略快照及一个待核对原命令；每个操作各一份独立回执，避免历史塞满单个128KiB文件。需同目录进程锁+本进程队列，缺失或坏状态不得静默重置。

保存前先登记准确原命令，再只发一次服务修改；结果不明时保留，重开通过窄 pendingChange 恢复口还原原控制器的命令/草稿/待核对状态。服务已保存但本机尚未保存，也不能说整个设置成功。若先写回执文件再提交最终偏好状态，回执查询必须确保该本机状态也已发布；下一操作只能在前操作完整结束后开始。明确未提交后清理该待核对，迟到原命令不能再写入。

本机主题/通知/后台仅设备保存；请求期限/历史策略用新服务接口。合并结果继续按原 WorkspacePreferences 全值和版本核对。库替换时保留已保存本机外观，停止旧命令并提示重新读取，不能说“旧操作从未提交”。当前有效旧分钟数须在原选择控件可显示，不断言或默改；新选择仍给原预设。正常UI的OS通知/后台行为随后由设备运行适配连接，不能让服务器执行桌面操作。

之后仍需运行/原生桌面（退出不停止服务或CLI）、Agent会话/当前包只读观察、正式同源候选、连续试用及获准的fork-none独立Agent。#103–#105不动。

服务器设置实现121883ae、恢复私有状态补强6688d367均已推送。#102设置阶段评论6726533674已发布并重新加载回读（持久锚点/短号/Open），工作页仍20/p1。初次长Python说明更新遇到stdin编码错误，没有修改目标说明；随后已用apply_patch完整更新本节和入口核对。所有测试、push会话已结束，没有待等的进程或用户批准。下一安全动作仍是实现RemoteWorkspaceSettings及设备偏好/待核对恢复，不是重新开发已完成的服务接口。


## #102 App 设置适配与故障恢复已接通

RemoteWorkspaceSettings 复用 CLI 私有原子文件写入，仅保存非秘密本机偏好及原操作身份。服务器持有请求/保留策略；主题、通知和后台选择保持设备独立。原控制器可在重开后恢复未完成命令与草稿，先核对原结果，不重复提交；服务器已存、本机写入失败也不能假报成功。旧库恢复使未发布旧操作失效，已保存外观保留。当前状态文件丢失拒绝重置；操作记录丢失拒绝推测没有保存。原页面兼容已有非预设等待时间。

最新 App 相关48项一次通过（联网设置10、原设置/运行/界面32、转换5、备份界面1）；Mac服务策略/转换6项通过。真实TLS/SQLCipher，含正常启动器原设置页面、丢回复和查失败后重开、本机原子发布失败及恢复、同设备旧草稿冲突、跨设备共享策略、准确清理确认失效与新确认。相关静态分析和diff检查通过。早期缺扩展导入及测试未等菜单回调的失败均保留、不计通过。

#102仍Open。下一步必须补运行/桌面与Agent观察，随后同源候选和无上下文Agent完整试用。通知/后台选项已保存不等于其原生效果已验证。未替换日常App或访问个人钥匙串，未改真实资料或推进#103–#105。

设置实现 c3b73660 已推送。GitHub评论6726776390已发布、刷新回读，#102仍Open，前置#101显示Completed。工作页20/p1继续保留，不逐阶段结束整个目标。运行适配应复用DesktopPlatform、原WorkspaceRuntimeController/Page和WorkspaceDesktop导航契约；旧DesktopRuntime/OwnerWorkspaceRuntime直接依赖本机InformationService并在退出停止服务，不能直接用于独立服务器模式或创建假本机库来适配。


## #102 联网接入观察已接通

原会话/申请统计移到共享OwnerAgentSessions，单机与服务端共用；受用户认证的agent-sessions只提供会话与申请摘要。RemoteWorkspaceAgents与单机共用原观察、诊断和选中会话规则，配套文件只在当前Mac核对，不推断Skill已安装或hooks已信任。资料恢复重绑观察，不复活旧许可。服务器变化标记补入零申请会话建立/结束，正常轮询可刷新原页面。

本次App相关45项通过，Mac服务11、Linux相同11通过，无平台跳过；静态分析无问题。含正常启动器原接入页面选择会话/诊断、新空聊天自动出现、查询失败与原详情失效、同名聊天、审批/到期/结束/重开、凭据历史恢复及实际文件清单篡改拒绝。详见evidence/server-a12/agents.md。初期导入/枚举/参数编译失败与非空接收库拒绝均如实保留，不计通过。

#102保持Open。应用运行/窗口、通知和退出仍未接；旧DesktopRuntime本机会话结束和停服务行为不能照搬，须独立设备生命周期，仍用DesktopPlatform与原运行页面/控制器。然后统一候选与无上下文Agent完整试用。日常App/真实资料/个人钥匙串未动，#103–#105未推进。

接入观察实现79f77da3已推送；GitHub评论6726944844已发布并刷新回读，#102仍Open。工作页继续20/p1。当前无未收尾测试或运行容器，下一步设备生命周期与运行适配。


## #102 正常启动器窗口/通知/退出已接，运行页面仍待接

OnlineDesktopRuntime 使用原DesktopPlatform与WorkspaceDesktop，正常main启动器已接：按本机后台选项关闭、菜单可达才隐藏、原导航和通知路由、模态/异步激活导航隔离、原待办新申请提醒与去重。只有用户明确从通知关闭改为开启时请求尚未决定的系统权限，启动/轮询/恢复/回执不触发。退出只关闭当前App观察、协调器和HTTP，再系统终止；没有服务器停止或聊天结束能力。真实Agent在App退出后继续用原许可读实际合成字段，重开同一配置拉回资料和待办。

相关App23项通过，后续慢通知不阻塞健康探测补强后的生命周期8+原连接界面1=9项通过，重叠不累加。最新静态分析、diff检查通过。真实TLS/SQLCipher及原页面，系统边界用测试平台夹具，不冒称Cocoa真实点击/通知/睡眠。早期类型/辅助测试编译问题及关闭时未排空观察导致计时器遗留已修正，失败保留不计通过。详细证据evidence/server-a12/lifetime.md。

#102仍Open。RemoteWorkspaceSource.runtime仍未接：下一步原运行/维护页面需区分服务器状态、当前App资源和CLI独立worker；CLI状态目录在正式连接/association相邻，不能当全在App私有目录或在服务器探测其PID。继续之后同源候选、连续完整试用与无上下文Agent。日常App/真实资料/个人钥匙串未改，#103–#105未推进。

生命周期阶段实现e8f668ea已推送；GitHub评论6729034290刷新回读确认，#102保持Open。后续使用任务空间21/p1（20已丢失且库存确认后重建）。下一步仍是运行/维护页面，不是正式打包完成或真实迁移。

## #102 原运行页面与 App 临时文件维护已接通

RemoteWorkspaceSource 直接实现 WorkspaceSource，正式端口不能再从 unavailable 基类静默继承。正常启动器提供实际桌面宿主；运行页面复用原控制器和控件，明确服务器设备报告、当前 App 临时文件与窗口退出。用户 runtime 接口复用原会话/凭据执行/文件交付投影，只返回元数据，Agent 不能调用；不检查或清理远端 PID、路径。App 文件维护复用原协调器，仅清理自己登记的临时对象，保留使用中副本及用户另存输出。自动维护不穿过编辑/模态锁。

原生操作保留准确意图和私有原子回执，丢失结果不能重做；本机发布失败恢复同一结果。新 App 生命周期保留旧未知记录，明确新操作不因此被永久阻断。退出排空观察，关闭后只展示标明的旧快照；服务器与 CLI 不受 App 退出影响。

最终相关 App51项通过；最后文案调整后的新运行5项单独通过，重叠不累加。Mac服务14、Linux纯服务13项通过，无跳过，相关15文件分析无问题。实际Mac worker运行合成凭据文件程序、退出及物理回收均验证；Linux仅承担服务及合成设备报告协议，不冒称Linux设备执行。正常App页面使用测试原生边界，不冒称真实Cocoa点击。完整证据与日志见 evidence/server-a12/runtime.md。

#102仍Open，下一步同源候选、同一候选连续全流程、新客户端拉取、无上下文Agent试用及清理。不改日常App、真实资料、个人钥匙串或Windows CI；#103–#105仍不推进。

运行实现3c58fd5b已推送；GitHub评论6729571608已发布并刷新回读，原评论锚点、实现短号和Open均确认。任务空间21已消失且库存核对后，按已有授权重建22/p1。最终文案组5项日志已确认结束通过，当前没有仍运行的测试进程。

## #102 统一候选打包已开始

已补默认AOT服务运行镜像，保留verify测试阶段；实际Linux ARM64临时验证镜像已完成初始化/重复拒绝、TLS保存、退出0、容器删除重建及资料/回执保持。新增正常App命名连接配置，隔离最终候选而不读日常配置，路径测试1项及相关分析通过。更新Mac随包说明为服务器版，移除旧本机库/端口/退出失效说明。新增固定源码打包脚本，要求同提交Mac App、CLI、worker、Linux镜像、说明及源码归档；清单分开构建成功和完整试用。详见evidence/server-a12/packaging.md。

下一步实际运行配套打包，不将当前临时AOT验证镜像算作最终候选。最终仍需同一候选完整流程、新配置拉取、无上下文Agent及清理；#102保持Open，#103–#105不动。

## #102 首个同源包已构建，补齐发现的 CLI App 控制缺口

第一次打包因隔离检出漏apps/server而在依赖解析失败，已修正。第二次a0d16a13同源包构建成功：Mac签名/字节/提取CLI和worker/存储诊断/DMG、Linux AOT服务镜像及容器初始化/重建均通过；清单仍标记完整验收未通过。

核对正式CLI App状态/退出发现联网启动器未安装原控制宿主，已补接原MacDesktopControlHost、同包进程约束及退出提交。命名配置使用单独控制登记，CLI明确同名配置，避免控制日常实例；不可用的登记不阻止正常连接或菜单退出。补强App19、CLI2通过，原Mac控制真实进程9通过，原“其他平台unsupported”1项在Mac跳过并如实记录；相关分析无问题。具体日志与首个包位置见evidence/server-a12/packaging.md。

下一步以修复后的固定源码重建配套候选，实际启动独立配置并核对正常退出，再继续连续业务、新配置、无上下文Agent及清理。先前a0d16a13包只算构建通过，不能当最终验收完成。没有读取日常连接、个人钥匙串或真实库，#103–#105仍不动。

## #102 实际候选启动/退出通过，修正接入工具和说明

12bc8785同源包已构建通过，并以新的命名空配置实际启动真实签名App；同包CLI观察准确进程running后正常退出，真实进程结束已确认，未触发钥匙串、未连接服务器或日常配置。此项不是联网界面业务整体验收。

正式参考中还发现旧App重启失效、Agent不能上传文件的说明，已按实际服务器能力改正。Mac远程CLI补上当前设备工具观察及准备目录的同源App公开引用，不把服务器路径当客户端路径，不复制大工具。原材料核对已支持并核对清单内所有合法参考，未声明/错版/篡改仍拒绝。CLI21、Mac与Linux服务各3通过，相关分析无问题；实际12bc8785包材料/工具用新逻辑核对通过。详细范围及日志在evidence/server-a12/packaging.md。

下一步以当前修正源码再次构建统一候选，提取包实测准备目录工具引用，再进行连续完整业务和新Agent试用。不能将旧包当含有新修复；完整目标仍active，#102仍Open，#103–#105不动。

## #102 连续业务与首次无上下文试用已执行，修复发现问题

7a056395配套候选完整构建成功。实际Linux AOT容器、提取AOT CLI/worker、真实随包AWS本机合成端点、原App数据源及正常启动器完成连续业务：保存修改、批准读取、服务重开原许可、整份提案、附件版本/另存/领取、凭据执行去重、目录标签移动排序、目录回收恢复、完整加密备份至新密钥空服务及全新客户端拉取。最终两组一次通过，十项事实记录均true；早期辅助审批未选附件版本、Widget fake-zone等待及保存后辅助读取刷新中的detail等失败均保留，未计通过，未改产品规则来过测试。详见evidence/server-a12/candidate-workflow.md。

获准的fork-none Agent只拿正式Skill和合成来源，独立提交一整份10项，未给分类/数量/关系/版本/命令答案。协调者以正常Owner接口补合成密码并整份批准。Agent自行读回16字段、3附件逐字节一致，副本全部released；用户侧另核对了实际关联与一月旧简历字节。未触碰个人Skill安装/信任、真实数据、个人钥匙串或日常App。

试用发现两处实际缺口：模板例子缺候选key，网关漏credential-catalog只读元数据入口。已修正动态说明/所有普通与凭据例子、受设备认证的公开凭据目录，并验证不泄露材料/私有备注/隐藏凭据及撤销后的拒绝。Mac和Linux服务各4、核心模板1通过。首次trial Agent已结束，无新的待审批；服务器暂保留合成现场待归档。

下一步提交这些修复和显式候选QA工具，再构建新同源候选，跑版本化连续检查、新无上下文Agent试用、最终原生启动/退出及产物清理。#102仍Open，目标active；#103–#105不推进。


## #102 最终本机验收和清理完成，待远端关闭回读

f0f9e24a配套候选已完整构建、同一候选连续业务两组通过、十二项事实均true；同一真实App新空配置启动/正常退出已观察准确PID结束。第二个fork-none Agent按正式说明和私有委托接入，11项整份保存，20字段与2附件读回一致并释放；用户接口另核对关联与旧附件。未再出现模板key与凭据目录缺口。

核心457通过/6跳过，CLI103/40，存储421/19，远程4/0。服务整组70通过，3项并发失败保持原断言与时限单独复跑全通过。App整组1258通过/6跳过/10失败；示例操作编号、候选key及异步退出清理等测试夹具已修正，所有10项定向复验通过。凭据UI原测试单独通过；模板及用户提案两个文件23项最终通过。全包分析无error/warning，有3条写法info，Flutter分析因此退出1；修改的测试文件分析无问题，不冒称全包零诊断。全部原失败和跳过保留，不累加重叠检查。

最终交付8个声明文件摘要、字节数与镜像ID/源码标签再次一致。仅保留f0f9e24a一套候选，一个App、零dSYM，一个当前镜像；本任务零运行容器及App/worker。两套试用的库、密钥、关联与复制程序已移除；旧候选释放约2.3GB，测试构建约300MB及旧工具和镜像也已清理，无全局Docker清理。完整核对与结构化证据在evidence/server-a12/completion-audit.md、final-facts.json。

当前功能代码仍固定f0f9e24a，后续仅测试/记录；构建归档准确对应原提交，未将旧归档测试冒称更新。下一步只同步验证提交、更新GitHub并回读关闭。#103–#105不动，正式安装、真实数据、个人钥匙串、Windows CI、个人Skill/hooks均未操作。
