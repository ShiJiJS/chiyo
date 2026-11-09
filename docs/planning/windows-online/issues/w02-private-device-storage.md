# Windows：保存连接和本机配置

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：2。直接前置：无。

## 做完后能做什么

Windows 能正确保存 NAS 地址、接入 Token、AI 设备配置和本机操作记录，重开后继续使用。

## 做哪些改动

- 补齐用户连接配置、Agent 设备配置、私有状态目录及本机加密操作记录库的 Windows 实现，复用已有 DPAPI、ACL 和平台能力。
- 管理身份与 Agent 身份分别保存；保留原操作、服务器绑定和独立密钥，不改 Mac/Linux 已有格式。

## 完成条件

- [x] 用户与 Agent 配置分别保存、重读和重开成功，现有 Windows 平台拒绝得到实际解决。
- [x] 本机设置、文件和执行记录可重开；损坏、错误密钥、原状态缺失或服务器绑定不符时准确拒绝。
- [x] 相关检查覆盖并发创建、原子替换失败、文件占用及中文空格路径，不覆盖原记录或重建旧密钥。
- [x] 敏感配置和控制凭证不进入普通日志、普通偏好或版本库；其他平台相关回归保持。

## 从哪里接续

- `packages/info_remote/lib/connection_profile.dart`
- `packages/info_remote/lib/agent_connection.dart`
- `packages/info_cli/lib/private_device_state.dart`
- `packages/info_storage/lib/device_file_operations.dart`
- `packages/info_storage/lib/platform_keys.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。2026-11-10 用户进一步允许使用现有实际资料验证；保持原资料与旧 Windows 库独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 必要时可用；正式安装与需要用户认证的操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W02 -->


