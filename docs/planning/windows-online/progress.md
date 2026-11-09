# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-10（Asia/Shanghai）。持续目标已恢复为 active。
- 范围：#108–#116，父任务 #104；#105 后置。#108–#112 已完成，#113 进行中。
- 分支：codex/windows-online。基线 ac8960c；环境与九票发布归档提交 35690cf。
- 当前票：#113，Windows 本机凭据使用。#112 实现 fe37707、证据 docs/development/evidence/windows-online/w112.md；#111 完整实现 620bcbe（PDF 初段 871a83f）；#110 实现 c42f7d7；#109 实现 2e86359；#108 实现 f454927。
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
