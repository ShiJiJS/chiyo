# 服务端首轮开发接续

## 当前范围与任务

持续目标 #91–#102，#103–#105 后置。分支 codex/server-first-stage。当前 #91–#93、#95、#96 已关闭（GitHub刷新确认），#94 目录管理正在开发；随后接 #97/#98 文件与凭据。真实资料、正式 App 与个人钥匙串未操作。

浏览器当前沿用 TaskSpace **5 / p1**；此前3已从工具清单中消失，依用户此前明确允许自动重建的授权恢复。5 仍属于整个持续目标，未 finish，后续先复用。当前页面为#94，正文、评论和关系已读取；#92是已完成前置，#94为#100前置。工单当前文本与活动读取材料在忽略目录 local/server-first-stage/tracker。

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

当前 #91–#93、#95、#96 达到各票首轮条件；#94、#97–#102 未完成，没有统一候选包、正式安装或真实迁移。完整目标保持 active。下文按开发先后保留过程记录，其中旧“尚未完成”和“下一步”只代表当时状态；以本节和最后一节为准。

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
| 目录修改、移动、排序、整理任务 | 未接；显式不可用 | #94 |
| 插件管理、动态模板与 CLI 示例 | 已接并通过 Mac/Linux 和正常 App 自动检查 | #95 |
| 文字录入/修改提案与预览 | 已接并通过整份保存、修正、重开、失败与丢失回复检查 | #96 |
| 附件上传、版本、领取与本机操作 | 未接；显式不可用 | #97 |
| 凭据管理、补填密码及关联 | 未接；显式不可用 | #98 |
| SSH、Token、凭据文件的本机使用 | 未接；显式不可用 | #99 |
| 回收、历史和版本恢复 | 未接；显式不可用 | #100 |
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
