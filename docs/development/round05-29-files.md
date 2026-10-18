# D7 Windows 文件凭据实施进度

2026-10-18，当前主会话单独实施，不使用子Agent；服务器同步已按用户要求排除本轮，先完成Windows。复用已存在且干净的 `codex/round05-29-files` 工作区，从集成6657429及Windows范围修订4be0796接续。

## 首条 AWS 纵向流程

公开核心服务提交固定AWS计划，服务附加可展示的空配置/禁用metadata、pager、自动提示常量；拒绝非静态default文件、其他profile、credential_process、SSO、重复键。普通字面占位符不替换。类型化内部引用只在服务生成的有效计划/存储读取中接受，Agent输入不能提交内部材料。

服务占用后创建具有受限DACL的空目录，路径/目录身份只进入加密仓储的执行私有字段及私有领取DTO，不进入公开执行响应。CLI独占创建空材料文件，经私有能力接口登记真实文件身份，审计成功后才写入凭据；应用会话证明不交给子进程。正常终态的清理核对目录和文件身份，通过打开句柄删除，拒绝重解析点、硬链接、外来文件，不递归遍历删除。

受控真实子进程已验证：接收到准确AWS文件字节、私有空config、字面参数保持原值、没有继承其他认证变量。子进程另用Windows ACL提供程序独立确认文件及目录protected DACL，只允许当前用户和SYSTEM；退出后两个文件和材料目录均不存在，执行状态exited/exit0与cleanup complete分别核对，不能重放。

红/绿记录在工作区 `.d7-aws-plan-*.log`、`.d7-aws-file-policy-*.log`、`.d7-aws-runtime-*.log`；核心16项与CLI11项定向回归及两包fatal-infos分析通过。这包含既有Token测试，不是新增27项。仅虚构材料，没有真实账号/密钥或正式库。Computer Use未使用，没有持久打开的测试应用。

## 尚未完成

SSH对应原型页面、启动时残留核查入口、完整协议负例及schema16升级、备份兼容和全套主集成回归仍待完成。下文记录已验证的异常、重启、真实文件接收流程；未登记进程组的未知执行继续保守保留材料并标needs_check。未合并到主集成，#29保持OPEN，不能将此版本作为正式文件运行或凭据备份交付。

## 真实工具与跨进程增量

真实AWS CLI 2.38.1通过公开AgentClient、受管worker和文件准备运行：身份查询、SSM非秘密参数写入及读回均退出0；本地服务端独立验证完整SigV4签名。相同虚构access key但错误secret得到403/exit254，四次执行的文件清理均complete，没有继承当前账号配置。工具SHA与前次预检相同；本轮是产品执行链，原预检未被拿来冒充完成。原始 `.d7-aws-real.log`，9秒通过。

真实文件被独立进程占用时，任务保留exit7，清理单独failed；释放后cleanup-use只重试清理，退出码不变、启动不能重放。红测试还暴露Windows错误码必须在分配Dart集合/后续原生调用前立即读取，已修正并回归。

实际独立服务和JSON-lines CLI进程使用不同TEMP时，先前把CLI自己的TEMP误当成服务登记目录的权威，导致准备失败。现按服务私密登记的固定路径、真实目录/文件身份及protected DACL核对，同时拒绝非本地路径和非规范父路径；不根据调用方TEMP改写或扩大目录。中文/空格材料目录及工作位置的真实JSON-lines与子进程通过，所有材料清理完毕。独立PowerShell ACL核验器明确以UTF-8读取JSON，避免中文路径被测试工具误解码。

## 失败与恢复增量

受控事务失败验证：材料登记提交时文件仍为空；失败后不写秘密、不启动程序，尝试保留已消耗，准备失败及audit_unavailable回执明确，空目录清理完成。补正了原执行报告未接受该错误码而遗留preparing的问题。

身份替换验证：把原材料保存在测试目录之外、在登记路径放入不同文件并独立设置同样受限ACL，清理仍因真实文件身份不同而拒绝。替代文件和原材料都保留，exit7与needs_check不互相覆盖；只在测试结束恢复原身份后清理该合成fixture。

实际SQLCipher重开验证：执行私有登记身份保留，未确认的文件执行立即标unknown/needs_check；原会话不能使用，秘密不在公开响应或库文件明文中。未登记到进程组的未知执行保持保守，不盲删。另以真实独立Windows进程组验证：活跃时清理busy且材料保留，组结束后可安全清理，执行结果仍unknown、不能重放。进程组名称仅由私有执行报告登记，核对实际成员及进程身份，登记后不能换组；观察失败不视为进程组已结束。

文件权限与清理集中在受管材料模块；实现核查依据：[CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)、[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)、[SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)。真实DACL检查与子进程行为作为验证，不以“调用过权限函数”代替结果。

## SSH 主机信任与真实文件接收

所有者明确导入并确认known_hosts，形成不可变ID和SHA256；相同内容重新确认也会产生新ID，旧的未启动SSH申请失效。配置保存在SQLCipher schema16，重开保留、清除可持久化。输入在排队前复制，后续修改调用方字节不会改变已确认内容。既有用户known_hosts、ssh_config及ssh-agent不被读取作为认证回退。

申请只含类型化私钥引用、明确user@host/端口、非交互参数和字面远程参数。有效计划附加严格主机检查、唯一identity、禁用agent/密码/键盘交互、私有空config/global hosts，并绑定主机快照哈希；参数及这些附加配置均需在审批展示。远程参数逐个按POSIX引用后形成固定命令，不把分号解释成额外远程命令；不启动本机shell。known_hosts仅在私有领取通道交付；CLI核对批准哈希再准备材料。四个空文件真实身份全部登记后才写私钥。私有响应上限4MiB覆盖两个各1MiB材料的base64与计划，公开请求仍限262144字节。

实际Windows OpenSSH 9.5p2通过产品申请、worker、受限文件与Windows进程组执行：匹配的临时密钥及已确认主机成功exit0；错误密钥、未知主机、主机公钥改变均exit255，每次cleanup complete且不能重放；远程分号字面参数保持原文。仅临时localhost Docker SSH服务，所有密钥均本轮生成，结束后核对标签并移除容器。可复现入口 `scripts/qa/ssh-fixture/run.py`，首次真实工具红记录 `.d7-ssh-native-red.log`，绿记录 `.d7-ssh-native-green.log`；受控接收端另检查四个材料内容和无环境认证回退。

## 审批、设置与清理入口

沿用Round05现有控件和分栏，审批页/确认弹窗/执行回执按接收方式显示Token秘密值、AWS文件环境变量、SSH文件参数；文件引用按原型展示 `{{file:alias}}`。主页面保留简明的申请命令，附加隔离设置和主机快照明确可见；展开的固定计划及确认弹窗展示完整有效argv/env、程序身份、主机快照ID/hash。原始申请与有效计划分别持久化，申请明细的JSON不混入仅服务生成的内部引用。重复合法文件引用复用同一路径，普通占位符文本保持字面值。

SSH主机信任设置采用选择文件→核对主机与文件哈希→明确确认的流程；取消不改变当前记录，替换/清除说明旧的未启动申请会失效。Windows原生文件选择器使用独立known_hosts标题，不依赖用户原有配置。schema15→16实际加密升级保留已有资料，主机设置重开/清除已验证。格式4暂明确拒绝遗漏主机信任的导出；完整格式5归#31，未据此声称备份已完成。

执行回执可核查并只重试清理，退出码/消耗状态不变。应用启动与维护会核查已登记的终态材料，未知执行须能确认已登记Windows进程组结束才清理；无法确认时保留并给出提示。“设置→应用运行”列出待核查记录，按5条分页，提供回执入口；不依赖历史横向tab。当前无完整凭据历史聚合，仍由#30继续。

最近完整组合检查：Core124、Storage55、CLI41（AWS/SSH/编译CLI条件全部启用，零跳过）、Desktop101，共321通过；之后增加公开协议负例和真实硬链接保护两条回归，通过。四包分析无问题，Windows debug构建通过。离屏界面证据 `evidence/29-files/r3` 共60张，覆盖四主题、1440/1280、文件注入tips/明细/批准、主机设置及200%字号；捕获脚本8组通过，不将这些渲染组重复算入321功能测试。Round05文件/文件环境变量页面使用同视口比较，新增主机信任设置为沿用既有设置控件的扩展。按用户约束由主会话自查，**未做独立评审**。

真实Windows runner已通过一轮界面批准→编译CLI/worker→真实OpenSSH，四场景退出[0,255,255,255]、四次材料清理、独立连接字段读取及SQLCipher/DPAPI重开均通过。最初原生与CLI组合失败记录保留：WSL在无存活进程时结束导致临时容器丢失；Dart SDK在中文TEMP编译测试辅助CLI失败。fixture现持有仅本轮的WSL输入进程，finally核对标签停止容器并结束keepalive；完整CLI组合使用ASCII编译TEMP，另保留中文文件交付与原生执行验收。原生成功日志 `.d7-ssh-ui-native-r2.log`。这些未替代最终冻结源码后的复跑、受管文件CLI异常恢复及打包验收。
