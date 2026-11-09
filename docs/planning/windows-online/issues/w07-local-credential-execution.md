# Windows：让 AI 使用 Token、SSH 私钥和凭据文件

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：7。直接前置：[#110](https://github.com/ShiJiJS/chiyo/issues/110)。

## 做完后能做什么

服务器批准后，AI 在 Windows 本机使用已有凭据执行操作，并能查询原结果、清理临时材料。

## 做哪些改动

- 补联网执行宿主的 Windows 环境和状态存储，接回已有 Windows worker、Job 进程树管理、材料目录和输出过滤。
- 提供当前电脑的 gh/ssh/aws 工具观察、版本与身份校验；使用合成接收器或明确授权的目标验证。

## 完成条件

- [ ] 实际 AOT CLI/worker 跑通 gh Token、SSH 私钥和 AWS 凭据文件，工作目录和执行环境属于 Windows 本机。
- [ ] App 退出后可继续执行/查询；服务重启保留原有效许可，限时和聊天内不限时遵守原到期、结束和撤销规则。
- [ ] 同操作重试、响应丢失、并发启动和进程异常先核对原事实，未知执行不自动重放。
- [ ] 敏感值过滤、材料清理和进程树退出闭环；缺工具或版本不符准确报告，不降低校验标准。SSH 密码登录和前台密码填充不在本票。

## 从哪里接续

- `packages/info_cli/lib/device_credential_host.dart`
- `packages/info_cli/lib/device_credential_journal.dart`
- `packages/info_cli/lib/credential_runtime_client.dart`
- `packages/info_core/lib/runtime_process_identity.dart`
- `packages/info_core/lib/runtime_material_files.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W07 -->

