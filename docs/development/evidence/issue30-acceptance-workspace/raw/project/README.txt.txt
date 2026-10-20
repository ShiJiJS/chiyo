Codex / Windows 同版本实机验收项目

软件来源：995283f1d5ef806a629f6cb917cca3bb7e88944f，版本：0.4.0+12-dev.995283f1d5ef
独立项目：C:/Project/network_config/info-manage-codex-acceptance-0.4.0-12-995283f
被引用的SDK-free材料：C:/Project/network_config/info-manage/build/codex-preview-0.4.0-12-995283f
桌面程序：C:/Project/network_config/info-manage/build/windows-preview-0.4.0-12-995283f/AgentInfoManage/app/info_desktop.exe

这只是尚未在Codex打开、注册或信任的项目材料，不是实机验收通过记录。
没有修改当前项目、用户级hook、个人Skill或信任配置；没有启动聊天或子Agent。
保留上述bundle位置；移动后须重新生成、重新审查准确的hook定义。

开始之前先在原开发会话说明可以配合。由开发会话启动独立虚构资料库的应用，
确认服务可用后，再由用户把本目录作为项目打开，并通过客户端正式入口审查与信任
.codex/hooks.json；CLI官方入口为/hooks，桌面入口需以实际客户端提供的界面为准。
若入口不存在或hook未受信任，保留现象，不绕过信任，也不手动伪造事件冒充客户端。
不要在尚无测试服务时先开启测试聊天，不访问真实资料库。

按acceptance-cases.json逐项留证。聊天A可使用以下提示：
“使用agent-info-access，发现虚构资料的公开目录，申请服务器地址和用户名。
等待我审批，不要因等待超时重复提交；批准后用多个独立CLI进程读取获准字段，
核对有效期不变，再核对未批准字段被拒绝。不要输出私密关联、token或文件内容。”

聊天B必须由用户另开，只提供A的公开请求ID/聊天ID，不把A的私密关联交给B。
真实结束/恢复也由用户操作；主子共享按用户允许的真人场景另行安排。
普通字段、凭据命令、普通附件和焦点填充保持独立流程；能力以实际capabilities为准。
记录客户端版本、实际信任入口、公开请求ID和截止时间；所有测试只用虚构资料。

参考官方文档：
https://learn.chatgpt.com/docs/hooks
https://learn.chatgpt.com/docs/build-skills
