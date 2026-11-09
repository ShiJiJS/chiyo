# Windows：连接 NAS 并正常管理资料

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：3。直接前置：[#108](https://github.com/ShiJiJS/chiyo/issues/108)。

## 做完后能做什么

从 Windows 正常 App 入口连接现有 NAS，查看、新增、修改资料，重开或重连后仍能取回。

## 做哪些改动

- 把现有 OnlineDesktopLauncher、WorkspaceApp、远程缓存和同步流程接到 Windows，复用现有服务端和界面。
- 核对目录、标签、关联、顺序、提案及历史等共享入口的 Windows 装配；按实际缺口修补，不重做已有业务。

## 完成条件

- [x] 正常入口配置和重开可连接现有 NAS，Windows 新配置能取回相同资料与版本。
- [x] 新增、修改、搜索、目录标签和关联保存有效；整份提案一次保存、手动编辑直接保存等原规则保持。
- [x] 断线、重连、错误 Token、证书/服务器身份变化和保存响应丢失均准确处理；结果未知先查原回执。
- [x] 使用用户允许的实际 NAS 数据核对，保留原资料；新增或修改验证内容可追踪，旧 Windows 库保持独立；相关自动检查使用正式生产装配。

## 从哪里接续

- `apps/desktop/lib/main.dart`
- `apps/desktop/lib/online_desktop_launcher.dart`
- `apps/desktop/lib/workspace/remote_workspace_source.dart`
- `apps/desktop/lib/workspace/remote_library_cache.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。2026-11-10 用户同意直接使用实际数据；本票仅新增并编辑《Windows 知予接入说明》，不改原有资料，旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 必要时可用，正式安装与用户认证最后集中；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W03 -->

## 验证记录

实现与边界见 [w109.md](../../../development/evidence/windows-online/w109.md)。实际 NAS 检查覆盖正常资料保存/重开、目录标签关联、原回执恢复以及连接故障和恢复；桌面 Release 实际显示 58 项并正常退出。原生键盘注入/快捷键尚未得到可确认结果，已作为 #116 的同版本桌面核对事项，不把 widget 结果当成真实键盘通过。

