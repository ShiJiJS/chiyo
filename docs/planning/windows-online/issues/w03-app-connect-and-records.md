# Windows：连接 NAS 并正常管理资料

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：3。直接前置：[#108](https://github.com/ShiJiJS/chiyo/issues/108)。

## 做完后能做什么

从 Windows 正常 App 入口连接现有 NAS，查看、新增、修改资料，重开或重连后仍能取回。

## 做哪些改动

- 把现有 OnlineDesktopLauncher、WorkspaceApp、远程缓存和同步流程接到 Windows，复用现有服务端和界面。
- 核对目录、标签、关联、顺序、提案及历史等共享入口的 Windows 装配；按实际缺口修补，不重做已有业务。

## 完成条件

- [ ] 正常入口配置和重开可连接现有 NAS，Windows 新配置能取回相同资料与版本。
- [ ] 新增、修改、搜索、目录标签和关联保存有效；整份提案一次保存、手动编辑直接保存等原规则保持。
- [ ] 断线、重连、错误 Token、证书/服务器身份变化和保存响应丢失均准确处理；结果未知先查原回执。
- [ ] 写入核对仅使用明确标识的合成资料，现有用户资料与旧 Windows 库保持独立；相关自动检查使用正式生产装配。

## 从哪里接续

- `apps/desktop/lib/main.dart`
- `apps/desktop/lib/online_desktop_launcher.dart`
- `apps/desktop/lib/workspace/remote_workspace_source.dart`
- `apps/desktop/lib/workspace/remote_library_cache.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W03 -->

