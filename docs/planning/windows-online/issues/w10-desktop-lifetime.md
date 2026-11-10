# Windows：核对并修补托盘、通知、退出和重连

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：10。直接前置：[#111](https://github.com/ShiJiJS/chiyo/issues/111)、[#112](https://github.com/ShiJiJS/chiyo/issues/112)、[#113](https://github.com/ShiJiJS/chiyo/issues/113)。

## 做完后能做什么

已有 Windows 桌面能力适用于联网版，关窗、后台和退出行为准确，恢复连接后能继续查看待办与运行状态。

## 做哪些改动

- 复用旧 Windows 托盘、通知、窗口和退出接口，修复联网模式的实际接线问题，不重新设计桌面流程。
- 核对本机设置、运行维护、唤醒恢复和通知路由，区分 NAS、当前 App 与独立 CLI worker。

## 完成条件

- [ ] 关窗后台与完全退出符合保存设置；App 退出不停止 NAS、CLI 执行或原聊天有效许可。
- [ ] 本机偏好重开保持，待办更新和通知路由不串到另一申请，模态或编辑期间不乱跳页。
- [ ] 受控事件验证网络/唤醒恢复和服务器身份变化，运行维护只处理本机登记对象，不操作远端 PID/路径。
- [ ] 已有能力正常的部分保留；相关自动检查通过。真实托盘/通知点击、键鼠、中文输入、高 DPI、睡眠唤醒留最后集中核对，computer-use 仍暂缓。

## 从哪里接续

- `apps/desktop/lib/online_desktop_runtime.dart`
- `apps/desktop/lib/workspace/remote_workspace_runtime.dart`
- `apps/desktop/lib/workspace/remote_workspace_settings.dart`
- `apps/desktop/windows/runner/flutter_window.cpp`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W10 -->
