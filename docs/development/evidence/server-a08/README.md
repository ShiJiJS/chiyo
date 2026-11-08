# #98阶段证据：共用原凭据保存规则

本票尚未完成。已将原OwnerWorkspaceCredentials、OwnerCredentialStaging及纯文件选择输入抽到info_workspace，桌面以原路径重新导出；原生选择器仍在桌面。没有复制第二套凭据业务规则，没有开放服务器本机执行或新Agent凭据能力。

原共享保存继续使用OwnerAccess.saveCredentialRecord、加密材料、版本核对、操作回执、关联和分类规则。仅改名称/备注不会改变材料版本或有效使用代际；更换材料才产生新版，停用保持原语义。原先不可用的直接申请/演示入口继续不可用。

实际检查：

- 原桌面凭据写入/管理与真实工作区界面26项通过，日志`local/server-first-stage/shared-credential-owner-regression.log`。
- 不依赖Flutter的真实OnlineInformationRuntime/SQLCipher场景在Mac及Linux ARM64各1项通过，日志`shared-credential-server-tests.log`和`linux-shared-credential-server-tests.log`。核对字符串及文件原字节、原操作重试、说明编辑不换材料、更换材料增加版本/代际、停用、关联/分类与回执重开保持、取消材料不入库；库文件不含合成明文，保存没有生成使用授权。
- 共享包、桌面原导出入口及新服务测试静态分析通过。Linux仍使用原固定哈希验证的SQLCipher缓存与原验收基础镜像，不作为最终发布镜像。

尚需：受认证的用户凭据材料暂存/管理接口、远程WorkspaceCredentialSource与正常编辑入口、Agent凭据提案、提案内密码填写和整份原子入库，以及重连/丢回复/非泄露的完整流程验证。正常AgentGateway仍整体拒绝尚未接通的凭据提案，RemoteWorkspaceSource未开放凭据创建；不能因这轮抽取声称联网凭据已能保存。实际凭据使用由#99接续。

本轮只用隔离合成资料和密钥；未操作个人钥匙串、真实资料、日常App、Windows CI或#103–#105。
