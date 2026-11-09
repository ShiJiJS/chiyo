# #102：配套候选连续业务与独立 Agent 试用

2026-11-09。最终有效候选为f0f9e24a，其连续流程、第二次独立试用和清理已完成，见文末及 [最终核对](completion-audit.md)。前文保留旧候选及修复过程，不把旧包当最终交付。正式安装及真实迁移仍留 #103。

## 7a056395 候选的连续流程

实际完整构建产物：`build/macos-adaptation/server-first-stage-7a056395`。Mac App、CLI、worker、随包说明与 Linux ARM64 AOT 服务来自同一提交。提取包签名、清单、SQLCipher、真实准备程序的工具引用、worker、DMG及编译服务初始化/重建均已通过；候选清单仍标记完整验收未完成。

连续业务使用该镜像的实际容器、TLS、加密持久库、提取后的 AOT Codex CLI 与实际 worker，不以内存服务或 Dart 解释器替代交付程序。实际经过：

1. 原远程 App 数据源保存、修改，正常CLI申请并经用户接口批准后读取；容器正常停止并重开后，原许可继续读取原内容。
2. CLI查询实际动态模板、提交两项提案，批准前未入库，原提案控制器一次保存后两项一起出现。
3. 普通附件上传、替换为第二版、查看第一版和第二版、实际Mac另存字节一致；AOT CLI获批领取当前版本并释放。
4. 上传合成AWS凭据文件，批准后用候选App内的真实AWS CLI与同包worker执行 `sts get-caller-identity`。仅连接测试自建的本机HTTP端点；端点观察到合成AccessKey的签名请求，真实程序退出0，同操作重查不产生第二次请求。这不是对真实AWS账号的验证。
5. 目录、标签、移动、手动排序、目录及其资料整体回收与恢复。
6. App原备份控制器导出完整加密备份，在使用另一密钥的空编译服务容器恢复，核对计数、旧附件原文和凭据元数据。
7. 新客户端私有配置重新取得同一资料；正常 `OnlineDesktopLauncher` 连接该编译服务，真实列表显示资料，再核对摘要、卸载界面和关闭数据源。

最终两项连续检查通过：`local/server-first-stage/a12-candidate-workflow-ui-pumped.log`，结果 `a12-candidate-workflow-facts.json` 的十项检查均为true。这里的两项包含完整业务和正常启动器两组，不把之前重跑次数累加。正常界面是Flutter自动控件验证，系统文件面板和桌面接口使用原测试边界；Mac文件实际发布、TLS、服务容器、CLI、AWS与worker均实际运行，未冒称真实Cocoa交互或系统面板点击。

初次连续检查的审批辅助没有选择附件当前版本，被原规则正确拒绝，随后改用原 `ApprovalDraft`；未放宽产品核查。Widget辅助直接等待旧fake-zone中的HTTP/关闭Future会阻塞，改为启动原操作并持续pump至真实完成，保留同一摘要查询及关闭断言。两次已确认失败/停滞的测试VM由本任务停止，所属容器正常停机移除、自己的执行宿主正常停止、合成目录清理。失败日志保留，不计通过。Drift不同隔离库的调试提示未屏蔽。

可复用的最终候选检查已整理到 `apps/desktop/tool/qa/server_candidate_workflow_test.dart`。它要求显式候选与新证据目录，核对镜像ID和当前产品源码；不读日常配置，不在普通单元测试中暗中启动Docker。命令在 `apps/desktop` 执行：

```sh
CHIYO_TEST_CANDIDATE="<候选绝对目录>" \
CHIYO_TEST_EVIDENCE="<新的证据绝对目录>" \
../../.tools/flutter/bin/flutter test tool/qa/server_candidate_workflow_test.dart --reporter expanded
```

正式版本进一步核对领取副本的实际移除和凭据cleanup报告；该加强版必须在下一最终候选实际执行后才能算通过。

## 第一次无上下文试用

独立 Agent `a12_fresh_usage_trial` 使用 fork-none，任务只给候选生成的正式Skill及合成来源目录，没有开发历史、分类、数量、关系、版本或命令答案。未给用户管理Token、未安装或信任个人hooks。来源包含环境导出、两份有明确日期的同方向简历、合成证明与新生成的SSH密钥对；所有地址及人员均虚构，不执行服务器运维。

Agent独立提交一整份10项提案：主机、应用、独立Mac配置、个人档案、单条两版本简历、证明、公钥及三项凭据。没有另存环境汇总或临时导出过程。私钥通过CLI提交、未展开原文；已有字符串Token标记已接触；未提供的网页密码留用户补填。协调者通过正常Owner私有输入及整份提案控制器填写合成密码并保存，未向子Agent提供该密码。确认后回读整份completed、10条已入库。

Agent再自行申请并获批读取：16个普通字段与来源一致；当前简历为十月第二版，证明和公钥为第一版，三个文件逐字节相同，均已释放并查询released。凭据只确认入库，不读取材料或声称真实有效。

Agent如实指出公开接口不能独立查全部关联和旧附件历史；这没有被当作它已验证。协调者另外通过正常用户详情及文件历史接口核对：应用与主机、Mac配置、个人档案与原件的关系正确；三项凭据关联目标正确；简历确有两版，当前第二版，一月第一版原文字节与来源一致。记录在 `local/server-first-stage/a12-independent-trial-1/owner-relations-history-result.json`。

第一次Owner自动辅助在保存后的异步刷新期间误读了已清空的控制器detail，断言失败；未重填或重提，改为直接回读原服务器提案，确认实际已完成。无匹配测试名的一次运行没有执行测试，未计通过。真实确认日志为 `a12-independent-owner-admission-verified-second.log`；读取审批与关系历史分别见 `a12-independent-read-approval.log`、`a12-independent-owner-relations.log`。

### 试用实际发现并修复的两项

- 动态模板例子没有候选自身的 `key`，Agent把引用用的 `itemKey` 写在候选上。已在CLI返回的模板说明区分两种位置，并给普通及凭据所有提交例子补稳定key和operationId；具体格式仍由服务动态提供。
- 服务器网关漏了 `/credentials/catalog` 默认可见元数据入口，正式CLI因此返回unsupported_capability。已补为受设备认证的只读元数据路由；仍只显示用户允许发现的凭据，不返回材料、私有备注或隐藏凭据，撤销设备后不能继续查询。

补丁的Mac和Linux服务相关各4项通过，无跳过；核心模板传输1项通过。初期测试漏导入核心扩展导致编译失败，已修正，失败未计通过。日志 `a12-trial-discovery-final.log`、`a12-trial-discovery-linux.log`、`a12-trial-candidate-key.log`。

下一步必须以补丁后的同一最终候选再做连续检查及新的无上下文试用，不能以第一次试用的部分成功或旧候选代替修复后的验证。

## 修复后最终候选 f0f9e24a 的实际结果

配套候选 `build/macos-adaptation/server-first-stage-f0f9e24a` 已完整构建，源码为 `f0f9e24a8f99d2e8a46b3cc7a6710da575e2627a`，Linux ARM64 镜像 `chiyo-server:candidate-f0f9e24a8f99`，镜像 ID `sha256:fbfc6a264637199858b1d88c0cc4331740d0b84b7f4f4bf049b523a72796af43`，Mac 版本 `0.4.4+18-mac-dev.f0f9e24a8f99`。Mac签名、提取字节/权限/链接、诊断、实际准备程序和worker、DMG，以及同源编译服务的初始化与容器重建全部通过。

版本化 QA 工具在这套候选上实际运行，两组均通过，日志 `local/server-first-stage/a12-final-candidate-workflow-f0.log`，事实 `a12-final-candidate-workflow-f0/workflow-facts.json`。十二项检查全部为true，包含上述完整业务、全新客户端、正常联网启动器，以及新增的领取副本物理移除和凭据执行cleanupState=complete核对。实际随包AWS只向隔离合成HTTP端点发出一次签名请求，未连接真实AWS账号。工具同时检查候选镜像ID和当前产品源码与该提交相同。

同一套真实签名App又以新空配置 `a12-native-f0f9e24a` 实际启动，同包CLI观察同一PID进入running，正常quit后确认进程结束。未配置服务器或读取日常配置，未访问个人钥匙串。日志及结果 `a12-native-package-f0.log`、`a12-native-package-f0-result.json`。退出后再次确认not_running，只删除这个测试配置的控制登记，记录 `a12-native-f0-cleanup.json`。这不替代原生文件面板、通知点击或睡眠唤醒验收。

## 第二次无上下文试用：最终候选

`a12_final_fresh_usage_trial` 使用 fork-none，实际子聊天 `01a1be04-e6e1-79d1-ba22-fa01cd166a96`。只给最终候选生成的正式Skill、隔离接入位置和合成来源，没有给分类、条数、关联、版本或命令答案。子Agent按正式说明要求父聊天先办理委托；协调者用自己的既有证明调用正式delegate，将准确子聊天私有关联交接给它，没有把用户管理Token或父聊天证明给它，也没有修改个人hooks。

Agent独立提交整份11项：主机、应用、两份独立配置、三个凭据、个人档案、技能项目正文、同一简历两版本和证明。不同于第一次的组织方式，但内容与来源相符；没有保留环境汇总原件或临时导出说明。协调者只通过正常用户私有输入补一项合成网页密码，再由原提案控制器整份保存；原提案回读completed、11条admitted。密码没有返回子Agent。

Agent自行申请22个范围，批准后实际核对20个文字或结构字段；简历当前附件为第二版、213字节，证明为第一版、177字节，均与来源逐字节一致。两份副本均file-release并回读released，没有待批申请。修复后的凭据目录入口可用，没有再遇到提交key或unsupported_capability问题；未申请凭据材料、未执行服务器操作。

Agent明确没有声称公开目录能核对关联或读取历史附件。协调者另用正常用户接口核对应用/主机、Mac配置、个人资料/原件及三项凭据关联；简历确有两版，当前第二版，一月旧原文与来源逐字节一致。这些是用户侧验证，不冒称由Agent独立读取。独立结果、审批与关系日志：`a12-final-independent-owner-admission.log`、`a12-final-independent-read-approval.log`、`a12-final-independent-owner-relations.log`；结构化事实在 `a12-independent-trial-2/owner-admission-result.json` 和 `owner-relations-history-result.json`。

试用结束通过同包SessionEnd结束原合成根会话；所属编译服务容器正常退出0并移除，`a12-independent-trial-2/shutdown-result.json`。没有重连原聊天、重放保存、安装Skill或将测试批准能力交给Agent。

全量检查、失败定位及定向复验、交付摘要和冗余产物清理现已完成，准确结果及限制见 [最终核对](completion-audit.md)。原先两轮试用的临时库、密钥、运行包、关联及旧候选已移除，保留普通合成源文档、小型结果和日志；不再保留可继续接入的测试身份。
