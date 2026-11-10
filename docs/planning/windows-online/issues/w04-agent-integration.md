# Windows：接通 AI 申请、审批和资料读取

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：4。直接前置：[#109](https://github.com/ShiJiJS/chiyo/issues/109)。

## 做完后能做什么

Windows 上的 AI 能通过配套 CLI 申请资料，用户批准后读取，App 退出后仍按原许可工作。

## 做哪些改动

- 接通 AI 设备配置、CLI/hook 聊天关联及生命周期，沿用已有主/子 Agent 与会话结束规则。
- 补 Windows 配套工具识别和调用说明，使用已有运行包登记机制；生成接入材料与安装/信任用户 hooks 分开。

## 完成条件

- [x] 实际 AOT CLI/hook 子进程完成设备接入、聊天关联、申请、等待、正常用户接口批准后的限定读取及撤销/结束失效。
- [x] Agent 身份不能调用管理或审批接口；管理 Token 不放入 Agent 接入材料。
- [x] App 退出、CLI 重开或服务普通重启后仍按原有效许可继续；超时不另建申请或延长许可。
- [x] Windows 完整同版本包正确识别，缺文件/错哈希准确拒绝；正式说明中的 Windows 调用方式实际可用，未改全局接入配置。

## 从哪里接续

- `apps/desktop/lib/online_agent_connection_dialog.dart`
- `apps/desktop/lib/workspace/remote_workspace_agents.dart`
- `packages/info_cli/lib/codex_registration.dart`
- `packages/info_cli/lib/codex_association.dart`
- `packages/info_cli/lib/codex_bundle.dart`
- `integrations/codex/skills/agent-info-access/`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W04 -->

## 验证记录

实现 `c42f7d7`；实际 NAS/AOT 申请审批、限定读取、重启后原许可与截止时间保持、撤销和结束拒绝，以及实际同提交运行载荷的哈希/缺文件检查见 [w110.md](../../../development/evidence/windows-online/w110.md)。本票受控验证身份不是本聊天接入，也不表示 Codex 宿主安装和信任已完成。最终发行 ZIP 与连续桌面验收仍由 #116 核对。
