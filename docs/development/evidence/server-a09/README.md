# #99 阶段证据：设备凭据操作及本机执行

**#99 尚未完成。** 长驻JSON-lines CLI的联网申请及本机执行已接通，并实际通过无外部权限的Token/文件接收程序、系统SSH和独立SSH容器检查。逐命令Codex适配器的设备常驻宿主现已接通并经独立可执行文件检查；正常App的SSH信任管理和凭据审批连续试用仍待完成，不能据本阶段关闭本票。服务器只宣告已接通的`credential-device-execution.v1`，尚不宣告旧的`credential-use-reuse.v1`。

## 已实现

- 共用原凭据申请和接收方式校验。`DeviceCredentialLaunch.prepare`在执行电脑探测原生程序和解析工作目录，生成不含材料的快照；服务器只核对它与原申请对应，不探测或执行设备路径。启动参数替换、错误接收程序或错误快照被拒绝。
- `requestDeviceCredentialUse`只供在线Host，设备身份由认证网关传入，不能由Agent正文选择。新增内部`/credential-use/device/request`，正常`status`/`claim`继续沿用原会话及设备绑定。原普通Agent设备不能审批；不同设备即使知道原会话或字段证明，也不能申请或领取。
- 独立服务使用`EncryptedInformationRepository.openOnline`保留运行事实，由`OnlineInformationRuntime`核对私有绑定后才恢复许可。原`open`仍保留旧单机关闭许可行为；没有新增App演示模式或单机/联网开关。
- 私有`textRuntime`升为3，保存请求与原设备/原聊天的对应关系及未确认决定的禁用状态。旧1/2可读取，但没有设备绑定的凭据历史不激活。字段混合申请保留原证明、范围及独立期限；审批事务已提交、快照尚未发布时，只按准确历史恢复该已批范围。
- 观察到的请求/授权到期写成持久事实，校正时钟也不复活。撤销、结束、停用、换材料、备份恢复均不会重开许可；SSH会话内不限时跨普通重启保留，原聊天结束后失效。损坏私有状态拒绝启动且不覆盖原证据。备份替换及历史清理同时移除对应绑定。
- 用户审批详情增加明确的v2路径`/v1/owner/approvals/details/<id>`，完整传递原Workspace凭据及执行元数据，正常App改用它。原v1详情仍拒绝凭据，避免旧客户端静默丢掉接收程序等内容后显示审批。普通资料、原审阅/回执规则继续共用；元数据编解码拒绝私有证明和不完整凭据详情。
- 原生程序探测目录在Mac创建后记规范路径，避免`/var`祖先别名使自己的空探测目录无法回收。

## 实际检查

| 检查 | 实际结果 | 日志（local/server-first-stage） |
|---|---|---|
| 服务包及在线/本机授权、密码、服务器状态存储回归（接请求HTTP前） | Mac52项通过；Linux ARM64 51项通过、Mac文件驱动1项按平台跳过 | a09-mac-server-regression.log / a09-linux-server-regression.log |
| 新在线授权恢复及原在线/本机行为 | 20项通过，含在上一组中 | a09-credential-runtime-tests-expanded.log |
| 设备快照、原凭据使用/复用/SSH会话规则 | 27项通过 | a09-core-credential-regression.log |
| 新真HTTPS设备申请→正常用户审批→字段领取→关闭重开→原许可/证明继续；跨设备拒绝、篡改拒绝、无材料输出；完整凭据/执行元数据编解码及原网关/审批 | Mac和Linux ARM64各5项通过 | a09-device-request-http-tests-complete.log / a09-linux-device-request-http-tests.log |
| 正常联网App资料审批与撤销、丢回复核对 | Mac2个连续场景通过 | a09-approval-ui-regression.log |
| DeviceCredentialLaunch默认原生探测，不注入替代检查器 | 当前Mac的固定版本gh、aws和系统ssh三种探测及快照均通过；未执行凭据任务 | a09-native-device-preflight.log |

本表为前一阶段结果；本轮新增执行检查及静态分析见下文。

服务器授权/持久化测试中的设备快照明确为合成元数据，验证服务器不访问设备路径；它不代表执行电脑已真实启动SSH。上述原生探测只验证工具预检；本轮另有实际执行、工作目录、进程生命周期与临时材料清理检查，见下文。正常App回归目前验证普通字段审批；凭据专用界面的完整连续试用随执行链补齐，不用HTTP审批替代该最终验收。

早期检查发现存储层原有启动逻辑会先取消凭据申请/作废授权，已为独立Host分开事实加载策略，原本机行为仍有回归证明。新HTTP申请先发现旧元数据编解码明确拒绝凭据，现通过完整v2详情接通，没有丢弃凭据部分绕过。初始失败日志保留，未将它们计为通过。

## 后续必须完成

设备宿主已按下文检查接通。继续接正常App的SSH信任设置与凭据审批连续试用；补设备断线、撤销/材料变化、私有执行状态损坏等剩余组合。系统SSH和合成接收程序已有本轮实际证据，但未替代这些剩余验收。未确认审批目前持久保持禁用，重新开进程后的准确原回执处理也需随原审批恢复场景核对，不因本阶段安全拒绝就宣称完整恢复已交付。

没有操作真实资料、个人凭据或钥匙串，没有替换日常App；#103–#105未动。没有#102统一候选。


## 本轮设备执行

- 新增设备私有逐次操作、状态、材料/worker登记、执行报告及清理确认；每项绑定原认证设备和原操作证明。首次私有回复可交付材料，重试只返回原操作元数据；相同编号换计划拒绝。设备证明先持久保存再发布回复，SQL已记操作但私有快照尚未保存的崩溃窗口恢复为原操作未知，不发第二份材料。
- 私有credentialRuntime升为2（外层textRuntime仍为3），保存执行证明、设备绑定、文件身份摘要和worker事实。原inner1可读；旧宿主不静默丢弃inner2。便携备份不带这些能力；清理和历史裁剪沿用原规则，服务端不读取设备文件或核查设备PID为本机PID。
- CLI复用原执行器、原生进程组、先登记后启动、程序摘要复核和有界输出过滤。设备自己创建并保管受保护文件；服务器没有明文临时文件及其可操作路径。准备及报告经私有设备路径，不把材料或证明返回普通CLI结果。
- 新DeviceCredentialJournal先保存清理/控制证明再写材料或允许worker启动，记录真实文件和进程身份，不含可读聊天证明、凭据字节或输出。复用文件领取的700/600与原子替换工具。CLI死去仍须确认原进程组结束后才物理清理；无退出回执时记录未知，不猜退出码。最后一个终态报告保留，避免丢回复后被后续错误报告覆盖。物理清理不依赖服务器在线，确认失败继续留私有登记供后续维护。
- 原单机报告仍核对本机进程；新增设备报告仅复用业务状态机，原设备执行不会进入服务器本机清理或本机PID检查。

| 本轮检查 | 实际结果 | 日志（local/server-first-stage） |
|---|---|---|
| HTTPS设备操作、丢首次材料回复、提交与私有快照之间崩溃、重启去重及原网关/审批 | Mac/Linux ARM64各8项通过 | a09-device-operation-regression-fixed.log / a09-linux-device-operations.log |
| 正常远程AgentClient、本机原生worker与Token/文件合成接收程序；CLI被kill后保留运行材料再清理；丢私有领取回复不执行 | Mac4项通过，包含随后服务包回归 | a09-native-device-cli-loss-tests.log |
| 系统/usr/bin/ssh连接独立Docker SSH账号，原许可跨服务重开；撤销及聊天结束阻止新命令但不结束原命令，材料清理 | Mac2项通过 | a09-native-device-ssh-tests-fixed.log |
| 上述Token/文件/崩溃/丢回复与真实SSH，补严格登记校验后联合复验 | Mac6项通过 | a09-native-device-execution-final.log |
| 服务包整组回归（新增SSH测试前） | Mac37项通过；新增SSH随后2项另验，不冒充同次全套 | a09-device-execution-server-suite.log |
| 原快照/凭据使用/复用/SSH期限规则 | 27项通过 | a09-device-execution-core-regression.log |
| 在线恢复和原单机存储 | 20项通过 | a09-device-execution-storage-regression.log |
| 文件领取、输出过滤、原生复用及原宿主 | 21项通过，9项按原平台条件跳过 | a09-device-execution-cli-regression.log |

服务端本轮lib与新增测试、CLI lib静态分析无问题。Core全lib分析仅有未修改的builtin_information_definitions.dart:7原有大括号提示；本轮修改的设备/运行文件没有新增诊断。早期测试发现夹具重复读取已关闭端口、误写测试文件名和SSH测试缺少扩展方法导入，已修正并保留失败日志，不计作通过。原生执行只证明当前Mac，不冒充Linux/Windows设备执行或日常App安装。测试SSH镜像chiyo-synthetic-ssh:a09可从scripts/qa/ssh-fixture重建，非最终发布镜像。


## 逐命令Codex的设备后台执行程序

- DeviceCredentialHost按原服务/设备保存一份700/600的私有连接记录，通过独立OS启动锁及后台生命周期锁协调多个CLI进程。记录含连接端口、随机控制证明、真实进程身份及配置摘要，不含聊天读取凭证、密码、密钥或输出。后台存活或状态不明时不因等待超时另开一个；即使连接记录被移除，生命周期锁仍阻止替换。配置摘要变化拒绝沿用另一连接。
- 原CredentialExecutionHost增加远程客户端装配，沿用全局16条执行/输出和完成后30分钟输出保存。正常info-codex逐命令调用通过仅回环、精确Host、拒绝Origin且有私有证明的控制接口进入它。原聊天证明只在调用与内存中传递，输出每次仍向服务器核对原聊天。不同聊天不能读已有缓冲；不在磁盘或公开聊天ID索引里存读取能力。
- 后台按原执行记录维护清理，闲置且无保留输出时退出；有活动执行时拒绝停止。停止和执行调用共用串行入口，已接受的命令不因调用CLI退出而取消。后台不要求App打开。共享RuntimeWorkerCommand正确选择SDK下的VM+dart文件或交付包中的独立worker，普通凭据与普通文件看护共用解析，不通过shell解释。
- 首次两个独立info-codex进程竞争启动同一命令，实际只建一个后台和一个操作；同一授权在服务重开后可执行第二条不同命令。丢后台接受回复后只查询同一操作，计数仍为两次。移除活跃后台的连接记录后，尝试第三条命令被拒绝且没有新操作；恢复准确原记录后原程序仍可查询。

| 本轮检查 | 实际结果 | 日志（local/server-first-stage） |
|---|---|---|
| 两个真实Codex适配器进程竞争、共享输出、跨聊天拒绝、原许可跨重开、丢连接记录与丢接受回复不重放、回环门禁、停止保护 | Token和文件两场景通过；SDK模式 | a09-device-host-lost-ack-tests.log |
| 相同完整场景使用本轮编译的info-codex和info-runtime-worker，ps核实后台程序是独立二进制 | 2项通过，不依赖开发SDK启动客户端或worker | a09-device-host-standalone-tests.log |
| 原CLI凭据复用、原生执行与文件看护回归 | 18项通过，6项按原平台条件跳过 | a09-device-host-existing-cli-tests.log |
| 直接远程CLI原生Token/文件/崩溃/丢材料回复与真实SSH回归 | 6项通过 | a09-device-host-direct-native-regression.log |
| 正式文件CLI及普通文字Codex接入回归 | 2个连续场景通过 | a09-device-host-file-text-cli-regression.log |

CLI lib和新增服务端测试静态分析无问题。本轮客户端二进制仅为隔离验证产物，尚非#102统一匹配的最终候选；未安装日常App、未启动真实资料服务或个人钥匙串。SSH信任设置、凭据App连续试用和未确认审批重开处理仍需接续，#99不关闭。


### 独立包断线补验

用同一5391519e客户端/worker二进制再运行正常Codex场景：文件操作正在运行时关闭原服务，随后让原命令结束；两份私有登记均证明已物理清理、文件路径不存在，准确exited回执仍保留。用原端口重开服务后，正常execution-status调用补交这两个原回执与清理确认，原退出结果、输出和两次操作计数保持，没有重跑。Token与文件两场景通过（文件场景实际经历离线），日志a09-device-host-offline-standalone-tests.log；新增测试静态分析通过。二进制摘要在local/server-first-stage/a09-standalone-host-candidate/manifest.json，尚非统一候选。
