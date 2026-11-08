# #98阶段证据：共用原凭据保存规则

本票尚未完成。已将原OwnerWorkspaceCredentials、OwnerCredentialStaging及纯文件选择输入抽到info_workspace，桌面以原路径重新导出；原生选择器仍在桌面。没有复制第二套凭据业务规则，没有开放服务器本机执行或新Agent凭据能力。

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
