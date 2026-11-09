# #98 联网凭据保存与整份提案验收

本票当前实现与验收见末节；下面按阶段保留开发记录。最初将原OwnerWorkspaceCredentials、OwnerCredentialStaging及纯文件选择输入抽到info_workspace，桌面以原路径重新导出；原生选择器仍在桌面。没有复制第二套凭据业务规则，没有开放服务器本机执行或新Agent凭据能力。

原共享保存继续使用OwnerAccess.saveCredentialRecord、加密材料、版本核对、操作回执、关联和分类规则。仅改名称/备注不会改变材料版本或有效使用代际；更换材料才产生新版，停用保持原语义。原先不可用的直接申请/演示入口继续不可用。

实际检查：

- 原桌面凭据写入/管理与真实工作区界面26项通过，日志`local/server-first-stage/shared-credential-owner-regression.log`。
- 不依赖Flutter的真实OnlineInformationRuntime/SQLCipher场景在Mac及Linux ARM64各1项通过，日志`shared-credential-server-tests.log`和`linux-shared-credential-server-tests.log`。核对字符串及文件原字节、原操作重试、说明编辑不换材料、更换材料增加版本/代际、停用、关联/分类与回执重开保持、取消材料不入库；库文件不含合成明文，保存没有生成使用授权。
- 共享包、桌面原导出入口及新服务测试静态分析通过。Linux仍使用原固定哈希验证的SQLCipher缓存与原验收基础镜像，不作为最终发布镜像。

尚需：受认证的用户凭据材料暂存/管理接口、远程WorkspaceCredentialSource与正常编辑入口、Agent凭据提案、提案内密码填写和整份原子入库，以及重连/丢回复/非泄露的完整流程验证。正常AgentGateway仍整体拒绝尚未接通的凭据提案，RemoteWorkspaceSource未开放凭据创建；不能因这轮抽取声称联网凭据已能保存。实际凭据使用由#99接续。

## 用户保存与正常App入口已接通

后续实现已接OwnerCredentialRoutes，严格的用户认证下接材料暂存、核对/取消、保存、停用、详情/材料历史和持久回执。仍使用同一个OwnerWorkspaceCredentials；暂存只有私有内存材料和不含正文的候选，不创建服务器明文文件。相同输入编号与摘要返回原候选，改内容拒绝；失效/已消费候选不重新暂存。原16份/16MiB容量不变，输入元数据限512，单调30分钟过期，Host周期清理及关闭清零；取消早于上传也能阻止迟到输入。普通管理2MiB请求上限足够1MiB文件Base64，没有放宽普通上限。

RemoteWorkspaceCredentials在私有输入请求中发送材料，普通Write/Detail/Receipt只传候选或元数据；上传丢回复先查原操作，查询失败不重新上传，保存未知时核对原持久回执。原生/远程输入共用CredentialInputStaging和原输入组件，支持异步传输、关闭后的取消/释放；正常OnlineDesktopLauncher已连“添加凭据”、更换、编辑和停用。信息库摘要补凭据元数据，远程和本机详情共用同一个投影。

| 检查 | 实际结果 | 日志（local/server-first-stage） |
|---|---|---|
| 受认证HTTPS凭据管理、1MiB文件、停用/编辑/更换、重开、无材料输出及加密文件无明文；共享保存；暂存过期/取消与清零 | Mac 3项通过 | owner-credential-http-tests.log |
| 当前完整服务包 | Mac 26项通过 | owner-credential-server-suite.log |
| 当前完整服务包 | Linux ARM64 25项通过、Mac文件驱动场景1项按平台跳过 | linux-owner-credential-server-suite.log |
| 正常联网App全流程及原凭据工作区、丢回复恢复 | Mac 28项通过 | online-credential-ui-tests.log |
| 真TLS代理：服务器已暂存/已保存后断开回复，查询失败不重做，恢复核对后只有一条凭据 | Mac 1项通过（亦含上行28项） | remote-credential-recovery-tests.log |

App场景实际从正常新建入口填写合成值、替换成第二版、停用，再保存合成凭据文件，关闭并重新连接后核对版本、状态、文件名和完整列表。只有原生密码编辑器返回和文件选择面板以合成边界替代；接口、SQLCipher、列表、编辑器、保存和重新拉取是真实现，不把它说成原生系统面板实测。

测试曾在输入框尚未重新启用时输入，实际提交空名称被原校验拒绝；现等待可编辑并核对控制器实际值，没有放宽校验。重开后的测试还调整了真实I/O与Flutter假时钟间的等待，去掉在假时钟中再次等待已观察完成的真实Future；两次定点停止的隔离测试不是通过，最终完整28项已重新通过，所属合成目录已核对并清理。临时诊断均移除，相关静态分析通过。

**#98仍未完成**：AgentGateway仍拒绝凭据提案，Remote提案内的私有密码输入尚未接通，未宣称整份凭据提案已可保存。下一步复用原fillImportCredentials和整体提案规则，保证补填、修订/失败、丢回复及重连行为；之后才接#99实际使用。未操作真实资料、个人钥匙串、日常App或#103–#105，尚无#102统一候选。

本轮只用隔离合成资料和密钥；未操作个人钥匙串、真实资料、日常App、Windows CI或#103–#105。


## AI提案、内联密码及整份保存完成

AgentGateway现按实际能力宣告`credential-import.v1`，正式CLI使用服务器当前动态模板提交字符串、Token和凭据文件；沿用`relations`/`itemKey`建立同份关联。人设且未进入上下文的密码用owner占位；已读到的密码和Token由Agent填并保留contextExposed说明。文件仍用原filePath读取提交，没有配置文件字段提取协议。

正常OnlineDesktopLauncher将OwnerProposalPasswords.remote接回原提案输入组件，没有第二套预览或新演示入口。专用Owner认证接口初始化和保存私有密码；普通Workspace DTO、提案回执、目录和Agent状态没有材料。显示/隐藏在原内联控件中；缺必填时不能整体确认。SQLCipher将整批密码修订与私有操作回执同事务写入；SQL故障回滚全部输入和修订。回执只在服务器私有状态，普通重启保留，便携备份不包含它或待处理提案输入，沿用原备份策略。

丢失填写回复先核对准确操作；查询失败保留原操作与输入，不换编号重发。ProposalsController现在区分密码填写未知与整份审批未知；重新核对填写只恢复审阅，不自动批准。确认没保存才可明确重试或修正输入。迟到的私有初始化回复也不能更新已经清除/更换的控件状态。

| 检查 | 实际结果 | 日志（local/server-first-stage） |
|---|---|---|
| 当前完整服务包、私有密码事务及原服务器状态存储 | Mac 32项通过 | credential-proposal-server-suite-complete.log |
| 服务包、私有事务及状态存储 | Linux ARM64 31项通过、Mac本机文件驱动1项按平台跳过 | linux-credential-proposal-server-suite-final.log |
| 正式CLI动态模板：服务+两个待填密码+已见密码+Token+密钥文件；未齐全不入库、Owner专用认证、重启、整体保存、正确关联与不泄露 | 含在上述服务包中；独立运行1项也通过 | remote-credential-proposal-http-tests.log |
| 正常联网App手动保存/更换/停用/文件/重开，随后AI提案内两次输入、显示隐藏、一次整体保存与重开；原生整份规则、Mac输入私有边界、两种真TLS丢回复恢复 | Mac 5个连续场景通过 | credential-proposal-combined-ui-tests-final.log |
| 真TLS丢填写回复且查询503、同原操作恢复、服务器重开后核对；确认未提交后修正重试，不自动入库 | 含在上述UI检查中；独立运行1项通过 | credential-proposal-recovery-focused.log |
| 原核心凭据录入与整份提案规则 | 11项通过 | credential-proposal-core-regression.log |
| 原临时副本释放关闭竞争：已确认清理返回原结果，未确认或不同身份不猜成功 | Mac 1项通过 | device-file-release-race-tests-verified.log |

相关App、服务、核心、存储及本机交付代码/测试静态分析通过。Mac UI场景仍只将系统密码输入回调和文件选择替换为合成边界，其余正常UI、TLS及SQLCipher均是真实现；原生系统实测留#103。

回归先发现旧测试仍断言credential-import未接通，已按新能力更新；缺少准确模板快照仍被拒绝。另一次完整Mac服务测试暴露原文件测试把“授权跨重启有效”误当作“网络中断期间副本路径必然保留”；已保留网络未知即清理规则，改查旧操作准确状态，并验证原有效许可可领取新副本。进一步定位到后台已确认清理并关控制端口与CLI释放之间的竞争，CLI仅在原身份/原manifest匹配、lease已清且终态已确认时接受原服务器结果；未知清理仍报未知。新增确定性专项及最终Mac完整32项均通过，不把此前失败记成通过。

#98的保存范围已达到本票自动验收条件；凭据实际执行仍由#99完成，#99–#102尚未交付。未操作真实资料、个人钥匙串或日常App；#103–#105未推进。
