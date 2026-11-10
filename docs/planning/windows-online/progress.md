# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-10（Asia/Shanghai）。用户已明确批准NAS更新并将goal恢复active；NAS已实际运行a9兼容修补，数据/配置/挂载/旧镜像和回退材料已核对，Windows原flow正在接续。
- 范围：#108–#116，父任务 #104；#105 后置。#108–#112 和 #114 已完成；#113 实际凭据执行中，随后收口 #115/#116。
- 分支：codex/windows-online。基线 ac8960c；环境与九票发布归档提交 35690cf。
- 当前票：#113（实际执行、重启、异常和自然到期）、#115（运行中worker/App联合退出）、#116（可靠Ctrl K与同包连续凭据）。中文鼠标粘贴、保存与取消已有最新完整包真实窗口证据。#112 实现 fe37707、证据 docs/development/evidence/windows-online/w112.md；#111 完整实现 620bcbe（PDF 初段 871a83f）；#110 实现 c42f7d7；#109 实现 2e86359；#108 实现 f454927。
- 最新授权：直接使用现有 NAS；computer-use 必要时可用；可用现有实际资料验证；允许正常重启知予服务。正式安装和需要用户认证的操作仍最后集中。
- 不扩入 WSL、新服务、密码填充、SSH 密码登录或跨电脑审批。保持旧 Windows 库独立；实际资料验证不等于可永久删除或恢复覆盖原库。

## NAS 接入已验证

- Mac 会话「配置 Mac 开发环境」刚准备的当前连接配置，经一次性 RSA-OAEP 加密交接到 Windows，四字段 address/token/serverId/certificate 完整。没有复制 Mac 设备 Token、聊天 association 或数据库密钥。
- 端点 https://192.168.8.132:47126。Windows 正式 Dart OwnerClient 验证私人 CA、管理 Token 和固定服务器身份成功，读取 42 条普通资料、57 项在用记录（15 项凭据），目录与插件可读。
- 本机配置仅以当前用户 DPAPI 保存在被 Git 排除的 local/private/nas-handoff/owner-profile.dpapi。所在目录禁止继承，只允许当前用户和 SYSTEM。
- 接续访问：运行 local/development/check-nas-production-client.ps1。它解封配置并经 stdin 传给正式客户端，输出仅为计数及核验事实。证据 local/development/nas-access-verification.json；不要输出配置或 Token。
- 首次辅助 Python TLS 探测因 Python 3.13 的严格 AKI 扩展要求拒绝旧证书；没有禁用证书验证，已改用产品实际采用的 Dart TLS 栈验证通过。临时 Python 探测脚本已删除。
- Mac 现有 fnos home-fnos 授权只读检查通过，当前不需用户重新登录。chiyo-server 正在运行，镜像 chiyo-server:sync-106-6e4e0ac0-amd64。重启时可联系原 Mac 会话，由其先核对唯一容器再正常重启；本次没有重启或修改 NAS。不要把只读检查当成重启已测。
- 当前没有需要用户在场的登录条件。正式安装和系统认证仍待最后集中。

## 当前代码与下一步

- #108：管理/Agent 配置、控制事实、SQLCipher 设备库已接入 Windows ACL + DPAPI；四包 fatal-infos 分析、定向检查、AOT 并发及 NAS 独立进程重开通过。
- 正式产品配置已另存到 local/private/windows-appdata/Chiyo/online/，含独立 Windows Agent 设备、设置及注册原操作记录；全部是生产存储格式。不要重新登记设备或抹除原事实。交接用配置仍保留在 nas-handoff/owner-profile.dpapi；一次性交接密文、公私钥已清理。
- #108 对 NAS 只读及正常登记 Windows 设备，没有改资料正文、NAS 设置或重启服务。全包/原生 UI 未由本票声明完成。
- 当前 #109：正式 Windows Release 已在工作目录隔离 APPDATA 下打开并自动连接 NAS，正常界面显示原 57 项、真实目录和资料详情。进程 15320 已经同包控制协议正常退出，未强杀。
- 发现并修复：Windows 搜索仍绑定/显示 Mac Cmd K；阅读模式移除原焦点后快捷键丢失。现在按平台使用 Ctrl K / Cmd K，并在阅读切换后恢复工作区焦点。macOS/Windows、保存/取消的四个快捷键场景和其余同文件回归共 7 项通过；桌面 fatal-infos 分析通过。
- CU 输入诊断：普通按键可进入输入法候选，sky.type_text 未产生可确认的完整文字；Flutter UIA SetValue 返回 E_FAIL。未据此断言软件不能输入，也未把真实表单保存算通过。未保存诊断表单已正常关闭，无 NAS 资料变化。
- #109 已完成：仅新增并修改《Windows 知予接入说明》，原资料未改。当前 43 条普通资料和 15 项凭据，共 58 项。真实 NAS 中文表单/搜索/目录标签关联/重开/丢失回执原编号查询两次通过；串行检查 28 项通过，提案和顺序 3 项通过（Mac 原生排序 3 项跳过），扩充已连接 App 断网/恢复检查单独通过。
- #109 恢复修补：原回执查询未刷新内存资料投影，已补与正常保存相同的只读同步；查询失败继续保留未知结果，不重放保存。连接页错误 Token、陌生 CA、错误固定服务器身份、不可达端点及改回原地址重连已通过一次。新增显式真实 NAS 检查不在默认测试中自动接入私人资料。
- #109 修复版构建通过；原生主入口 PID 17736 显示真实 58 项和新文档/关联，控制 CLI 正常退出，登记状态 exited。Sky 原生 Ctrl K/文字注入结果未确认，已明确加入 #116 的同版本桌面条件，不能当成通过。
- 下一步 #110：按 Windows manifest 识别同包 CLI/Skill，补齐引用并构建最新 AOT 工具；使用新建、隔离的验证聊天身份对现有 NAS 检查申请/审批/限定读取及失效，不搜索本聊天丢失的 association、不改全局 hooks。
- #110 当前：Windows 同包观察器与四份引用打包已实现，6 项包检查和两包分析通过；真实 AOT 会话/hook 9 项、桌面观察/状态回归 27 项通过。当前 App 已退出。
- #110 真实 NAS：全新隔离验证身份完成申请、等待原编号、仅批准字段读取、未批准字段/无关聊天拒绝、子身份共享范围、主人能力隔离；原 NAS 正常重启一次后根/子继续读取且截止时间不变；撤销与根结束后拒绝。首次结束未及时确认，只沿原 end-only 凭证接续，最终 completed。见 docs/development/evidence/windows-online/w110.md。
- #110 已完成：干净 c42f7d7 重建的实际 App/CLI 运行载荷共 40 个文件，目录 build/development/w110-matched-c42f7d7；生产观察器识别、实际引用损坏/缺 hook 拒绝及恢复检查通过；由该载荷正常生成的最新审查材料再次通过 9 项 AOT 检查。此运行载荷不是 #116 完整发行 ZIP。旧两份临时接入材料、准备目录和已结束的本票私有验证引用已清理；保留最新匹配载荷、审查材料和摘要。未改全局 hooks 或本聊天 association。
- 下一步 #111：补 Windows ownerFileOutput、templatePackageInput、owner_file_open 及 PDF 通道；沿用正式文件协调器与受管副本规则。先读现有原生实现/相关 ADR，再针对文件发布、历史原文与预览边界检查，必要时用真实文件面板验证。
- #111 已接 PDF 原生通道：Windows.Data.Pdf 内存渲染、共享 15 秒期限、UI 线程回送，修复真实通道发现的 DIP/物理像素差异；原生两页颜色/真实 PNG 尺寸/越界/损坏/密码文件检查通过，28 项适配器检查、实际 Windows Flutter 通道与正式翻页控件检查通过，桌面分析通过。见 docs/development/evidence/windows-online/w111.md。本票仍开放。
- #111 新定位：正式另存流程仍依赖 MacBackupPublicationFiles，Windows prepareStaging 返回 null，不能只补文件面板就宣称可另存。接下来实现 Windows 身份绑定/同卷/拒绝覆盖发布与回执恢复，补原生系统打开，再核对 NAS 文件与版本。
- 过程清理限制：删除 PDF 样本生成依赖目录及旧 Release 内原生检查 exe/pdb 的命令被自动审批以 blocked by policy 拒绝，未执行，不重试/绕过。新检查目标已移至 runner/owner-pdf-check，旧文件仍保留；最终包不得混入旧检查程序。
- 辅助测试尝试：现有 remote_settings_test 的本机服务器夹具受 POSIX secrets 和 /bin/chmod 限制。临时 Windows 测试夹具改动已撤回；没有修改生产服务平台边界，失败不计通过。测试失败时创建的隔离 Temp 合成夹具未做宽泛前缀清理。
- 旧 POSIX 权限用例在 Windows 按平台跳过；未冒充已在 Mac/Linux 机器重跑其原生检查。此前 UI 服务器集成夹具依赖 POSIX 服务密钥，后续要适配测试装配而不放宽生产服务密钥边界。
- #111 已完成：Windows 同卷、拒绝覆盖、保留原件发布，SQLCipher 结果和重开恢复；Windows 系统打开接收器核对身份/ACL/哈希，同编号不重复启动。实际原生面板发现 NTFS 同名缓存会改变创建时间，先复现失败，再改用仍有原件链接的稳定文件 ID，回归通过；普通配置/材料仍拒绝硬链接。真实 NAS 文件上传/替换/历史/恢复/丢失回执/另存重开/副本清理最终通过，原有记录版本未变；只新增《Windows 知予附件说明》，当前共 59 项。实际另存/模板面板、生产解析器、真实系统记事本原文与副本清理通过。6 项 core、20 项 storage、43 项桌面检查、分析及最终 Release/worker 构建通过。完整包/主入口连续验收仍 #116。
- #111 过程限制：另一次删除旧失败面板夹具 build/development/w111-native-files-20261110 也被自动审批以 blocked by policy 拒绝，保留，不重试。最新通过目录为 w111-native-files-fixed-20261110。自动化可访问性焦点/元素坐标不可靠，需激活面板 Raise 并按最新截图确认；本票未据此冒认 #116 原生表单输入/Ctrl K 已通过。
- 下一步 #112：先修正 DeviceInformationFiles.maintain 的 POSIX 斜杠日志过滤，核对 Windows worker/锁/进程身份；从实际 AOT CLI 在 App 关闭时领取现有 NAS 上本轮文件，验证并发、失效、占用、异常退出和仅凭清理能力恢复。使用全新隔离验证身份，不搜索本聊天丢失的 association，不改全局 hooks。
- #112 已完成并推送 fe37707：修正 Windows 私有日志扫描和周期/显式清理队列导致已确认状态回退的竞态，保留未知与占用事实；完整 CLI/core 分析、桌面分析、7 项定向检查（包括实际 AOT worker 竞态）和实际 AOT 旧协议组合检查通过。现有 NAS/五个新编译 AOT 组件在 App 完全关闭时验证同编号并发副本、原文/哈希、响应丢失、释放和异常退出恢复；同一 NAS 正常重启一次后原交付 ID/原截止不变，未改配置/镜像/四挂载或其他 11 个容器。原短期许可自然到期不延长，撤销另设明确验证许可；撤销、到期与结束拒绝新领取，真实 Windows 占用时保留副本/登记，解除后只凭清理能力确认终态。流程 local/private/w112-file-check/flow.dpapi 已 completed；只读盘点无 w112-aot CLI/worker 存活，不重放已完成流程。
- #112 结束限制：实际两秒 hook 未确认，原请求仍 approved、原副本 ready，保留 end_pending；随后使用原 CodexEndIndex end-only 索引，在回调外以显式 20 秒预算恢复，并重核原副本/占用、结束状态与新领取拒绝。没有按聊天 ID 恢复读取关联、没有修改 hook 时限，也未把回调外恢复冒认为真实宿主结束事件两秒成功；#116 连续流程仍需核对。
- 下一步 #113：修正 DeviceCredentialJournal 的同类斜杠过滤及本机 host 的 Windows 环境，复用 Job/原 worker/私有材料/输出过滤；接 Windows 当前设备的 gh/SSH/AWS 观察与身份版本要求，缺工具准确报告并在工作目录准备必要工具。使用明确验证凭据/接收器或已获准目标，不做 SSH 密码登录或前台密码填充。
- 九张工单父关系和 13 条前置的发布核对见 publication.json；SDK/C++ 与开发入口见 windows-local-setup.md。#104 和 #113–#116 仍开放。
- #113 阶段进度：本机 host 显式 Windows 环境、DPAPI 清理日志扫描、Windows 随包 GH/AWS + 系统 SSH 发现、准备 CLI 的匹配包公开指针及固定官方工具组装已实现。15 项 CLI 定向检查（含三种实际工具版本/身份）、2 项 Core、1 项设置控件、2 项 MSI/CAB 负例和相应分析通过。官方 AWS MSI 仅只读提取 7,566 文件；没有系统安装、全局 PATH 或全局 hooks 改动。证据 docs/development/evidence/windows-online/w113.md。
- #113 实际 NAS 阻点：新建隔离验证聊天和三份本轮开发凭据后，Windows C:\... 启动计划被当前 NAS invalid_plan 拒绝。已定位 device 接口误用服务端本机平台的路径解析；修补限定在已认证 device transport 显式 portable-path，普通本机默认不变。尚未批准或实际执行，不冒认 GH/AWS/SSH AOT 流程通过。原 local/private/w113-credential-check/flow.dpapi 保留，不重新创建聊天/凭据；原资料及 SSH 信任不变。
- #113 下一步：Mac 先只读核对当前镜像/现有检查流程；扩展的跨平台真实服务请求/操作/加密重开检查需在 Mac/Linux 验证。NAS 运行版本未替换，正常重启授权不等于替换镜像授权；服务端修补/构建准备可审阅后再集中说明具体所需动作。该等待期间继续 #114/#115 的独立实现与检查，九票不提前报完成。
- #113 服务候选已准备：固定 a9eccb3c5746e8aaa932debdfa2e1af27e86d90e，Mac 核心 68 通过/1 Windows 专用跳过、服务端全套 81 通过；Linux AMD64 核心 2、服务选定 21 通过；实际 AOT 的合成升级/重开/旧副本回退和增量接续通过。Mac 候选目录 build/macos-adaptation/windows-device-path-a9eccb3c-amd64/，镜像 chiyo-server:windows-path-a9eccb3c-amd64；tar.gz 36,520,334 字节，SHA256 05441a43115d63b84853a1553b33e5740d2ec09c1eaf2d4e114f70dc8f656847。只准备候选，NAS 原镜像/StartedAt 未变。已向用户发出具体换版本问题，答复前不替换，不把正常重启授权当成更新授权。
- #114 独立完成并关闭，提交 c75b96424fc430579b79ef0e1c0162b0757b2002，GitHub 回读 CLOSED。Windows 暂存路径边界先红后绿；设备备份日志/占用/大文件/重开、发布、完整备份/凭据/恢复、目录顺序/回收及恢复进程中断共 44 项定向检查通过。真实 NAS 导出/独立新 DPAPI 空目标恢复最终 48 秒通过；丢失确认并断线后重开原操作，实际仅导出一次。44 条资料、30 个含回收凭据对象、37 个附件版本及历史恢复，原 NAS 资料/SSH 信任不变，没有调用 NAS 恢复接口。最终私人证据 local/private/w114-backup-check/w114-backup-9384c1c8/result.json；公开证据 docs/development/evidence/windows-online/w114.md。最终完整包/原生连续核对仍 #116。
- #115 当前：发现 Windows 原生窗口未转发唤醒事件。真实 native integration 向自身窗口发送受控 WM_POWERBROADCAST/PBT_APMRESUMEAUTOMATIC，先复现回调 0 次；修补后触发在线重连回调 1 次，后续用户活动消息不重复触发，不退出或实际休眠电脑。待补 NAS 桌面生命周期与本机设置/通知路由、同包 Release 和最后原生连续检查。
- #115 独立检查已通过：真实 NAS + Windows 私有本机偏好/正式在线 runtime 的生命周期检查 39 秒通过；两次通知分别路由原申请，模态阻止迟到跳页，断线/唤醒不重放，错误 serverId 拒绝，App 关闭/退出失败重试不结束独立聊天，最终新 QA 聊天 end-only 确认结束。18 项旧桌面回归、实际 native 唤醒红绿、C++ 通知队列通过，完整 desktop 分析与 41.8 秒 Release 构建通过。证据 docs/development/evidence/windows-online/w115.md；本票仍开放，待 #113 正在执行 worker 与最终 App 退出联合核对以及 #116 同包原生连续验收。当前 info_desktop 进程数 0。

- #116 阶段：修复 Windows 整体检查的 POSIX 路径/权限/字体夹具、CRLF JSON 围栏、独立崩溃进程依赖锁；不可变示例附件按原字节检出，修复 Git CRLF 导致的哈希失败。CLI 120/27跳过、core 443/26、storage 379/47、remote 2/2、desktop 1118/64 全部非 hidden 用例通过，POSIX 整文件排除不计通过；相应分析通过。更新当前 NAS 随包说明，准备干净固定提交 -PackageOnly 归档。证据 docs/development/evidence/windows-online/w116.md；工单仍开放。
- #116 原生输入定位：最小无 NAS 窗口记录到 Sky 的 Ctrl K 在 K 到达时 ctrl=false，type_text 的 V 同样 ctrl=false，解释组合键/粘贴未成立；普通按键及 IME 候选能出现。未据此改产品快捷键、未冒认真实物理输入已过；正常主入口与诊断 App 已分别正常退出。最终连续检查及 NAS 版本授权仍待接续。

- #116 第一完整候选 1351a74 已经全部产包/解包/SDK-free/加密存储检查通过，ZIP 123278838 字节、7699项载荷，SHA256 3ea59f8a86d84e489b7b4dd8064795dd11fa54de076563a8d56605d48d02771f。实际 AOT 能力查询证实同包 GH/AWS 与系统 SSH；原生主入口连接62项、同包CLI正常退出。原生页面另发现Mac专用说明与当前联网Agent页遗漏工具状态组件，已修补并通过四文件回归/桌面分析，准备新提交重建。第一包是故障定位候选，不冒认为最终完成。原w113只读核对仍requesting-gh/3凭据/0申请，原关联保留，NAS更新授权未取得。

- #116 335445f再通过全包检查，实际页面工具三项/Windows通知/系统托盘说明已确认，关窗后running及同包CLI正常退出。对比发现增量Release根多带Flutter test专用native_assets.json（绝对构建路径），正式NativeAssetsManifest原本正确。已修打包只排除此测试缓存，补正式SQLCipher映射及解包拒绝检查；335445f作为负例，不作为最终交付，待新提交再产包。Mac在22:29Z只读确认NAS原镜像/StartedAt/四挂载/其他11容器均未变，a9候选SHA复核一致，换版本仍未授权。

- #116 最新完整候选55d83404998492fd46a21816a9791a72c8419189已通过完整 -Offline -PackageOnly 和新解包守卫；build/development/w116-package-55d8340/，ZIP123298669字节、7699项，SHA256 de934ca5a129dcb42c391d75c18ad1e84bd001af97a679b60d682e48a58cd599。默认2062项非hidden适用测试通过，另有明确平台跳过和POSIX整文件排除；实际解包CLI/hooks16项、混合生命周期7项及SQLCipher/DPAPI通过。受限PATH的实际App显示62项并正常退出；三工具当前设备观察通过。旧两份w116完整包及旧QA已清理，保留日志/manifest/摘要，原策略拒绝项未动。启动脚本local/development/start-windows-online-candidate.ps1已备妥，正式安装/hooks未改。
- 接续位置：build/development/w116-qa-55d8340，原私人local/private/w113-credential-check/flow.dpapi仍requesting-gh/3凭据/0申请，不重建；NAS兼容修补a9候选在Mac保留。只有用户明确同意换版本后才部署并接续#113真实执行、#115正在运行worker/App联合退出，再完成#116同包连续核对。Ctrl K/中文保存取消需可靠原生输入，最小窗口已证明Sky组合键到达时Ctrl不在按下状态，不改业务代码掩盖。
- 外部阻点审计1：当前唯一连续目标turn 01a1c116-0552-72a2-a858-5df2c7d60729，独立工作在本turn末才耗尽；换版本问题尚未答复。goal保持active、不提前complete或blocked。后续不同自动续作turn如仍无新授权/可靠输入，记录同一阻点审计2、3；达到三次且无独立工作再按goal工具置blocked，避免重复全量检查或重复询问。新授权到达时立即接续其允许范围。

- 本次续作新增实际证据：Control_R+k同样在K到达时ctrl=false；改用自有记事本样本的鼠标复制/Flutter右键Paste，55d8340真实App完成中文名称/正文输入、保存与取消。仅新增一条明确开发文档，正常回收后界面恢复62项/回收站40；44条原资料SHA和原w113信息基线一致，App正常退出。首次GET超时仅重试读取，没有重复保存。事实local/private/w116-native-record-check/facts.dpapi已completed，本机辅助代码local/development/w116_native_record_check.dart；详见w116证据最后一节。包与源码未变，无须重跑已通过整套检查。
- 外部阻点审计2（turn 01a1c28a-d9be-7352-b4be-665c98d289e7）：上一goal turn属于progress，本turn也新增了中文真实窗口证据，原先“中文保存需用户回来”的范围已收窄；Ctrl K仍无法由Sky可靠发送，NAS换版本问题仍未答。现在已做完当前可执行独立工作，goal继续active；下一不同续作turn若仍无新授权/可靠输入且无安全独立动作，按第三次同阻点审计置blocked，不重复整套测试或重复询问。

- 外部阻点审计3（turn 01a1c29d-213b-7691-bf99-7e8fcef2e079）：已重读三票剩余条件、当前GitHub状态、完整候选验证和先前两次审计。上一goal turn是progress（新增真实中文粘贴/保存/取消证据）；本turn是no progress，不是verified wait：没有活跃构建或App进程，Mac任务已completed/idle，不能把静止会话当运行任务。NAS升级同意仍未收到，仍不能部署a9；Sky左右Ctrl均在K到达前丢失状态，可靠Ctrl K仍需外部输入/工具变化。当前无可执行的独立产品改动或必要检查，满足三次同阻点条件，接下来调用goal置blocked，#113/#115/#116保留OPEN，目标范围不缩小、不提前complete。
- 恢复首步：用户明确同意既有NAS升级到a9eccb3后，协调原Mac会话保留现有数据/配置/挂载/旧镜像更新唯一知予服务；沿build/development/w116-qa-55d8340和原w113 flow接续，不新建重复聊天/凭据。完成真实凭据/进程树/到期/重启/退出联合检查后，收口#115/#116；中文鼠标粘贴/保存取消已通过，Ctrl K仍独立核对。用户恢复受阻目标后，若再遇阻按新一轮审计计数。

- 2026-11-10用户明确授权：“行，那就把 NAS 上的知予服务更新到这个修补版吧，保留好数据、配置，更新后继续按 goal 推进剩下的工作。”goal已由用户恢复active。已交原Mac会话执行此前已验证a9eccb3候选，保留数据/配置/四挂载/旧镜像及回退能力，仅更新知予；当前等待实际部署结果，尚不宣称完成。部署确认后运行匹配55d8340 QA探针沿原w113 flow继续，不重建身份或凭据。此前blocked审计结束，今后若新一轮阻点需重新计数。

- 2026-11-10 NAS升级完成及Windows接续：a9实际revision、原证书/身份/配置/四挂载/44资料/18凭据和其他11容器核对通过，旧镜像/停机快照/加密备份保留。匹配55d8340 AOT原flow通过GH/AWS/SSH、唯一正常重启后原许可/截止、自然15分钟到期、撤销/结束拒绝、同操作/丢回执、App退出、worker异常/活子进程保留/未知不重放/最终材料清理；原资料/SSH信任不变，flow已completed，自身host正常停止。#113与#115完成，待提交及GitHub回填；#116剩可靠原生Ctrl K和最终同包审计，goal保持active。
