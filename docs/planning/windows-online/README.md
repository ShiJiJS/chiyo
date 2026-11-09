# Windows 联网适配：九张工单

用户已确认方案 2、3、4、5、6、7、9、10、11，并于 2026-11-09 要求整理发布到 GitHub、提供持续执行的 goal 描述。用户已启动持续目标，2026-11-10 已取得并在 Windows 验证 NAS 接入配置；#108–#112 和 #114 已完成。#113 的 NAS 兼容修补候选已验证，待用户明确批准替换运行版本；等待期间推进 #115/#116 的独立工作。发布结果与原生关系核对见 [publication.json](publication.json)。

九张工单已发布为 #108–#116，全部挂在 #104 下；正文、标签、父关系和 13 条前置关系已回读核对。原先十二项草案已由本组九票替代。

## 本轮范围

Windows 直接连接用户现有 NAS 服务，接通已有 App、AI CLI、附件和凭据使用、备份及桌面能力，最终生成完整 Windows 包。沿用现有服务端、Flutter/Dart 和业务规则。

原草案的另起 WSL/测试服务器、前台密码填充和额外交付票已移除。SSH 密码登录、Mac 专项和 #105 跨电脑审批继续后置。本轮不重写已有托盘、通知和备份功能，按 Windows 实际缺口修补。

## 工单与依赖

方案号是用户选择的编号；GitHub 号以 [tickets.json](tickets.json) 的发布映射为准。

| 方案 | 内容 | 直接前置 | GitHub |
| --- | --- | --- | --- |
| 2 | [保存连接和本机配置](issues/w02-private-device-storage.md) | 无 | [#108](https://github.com/ShiJiJS/chiyo/issues/108) |
| 3 | [连接 NAS 并正常管理资料](issues/w03-app-connect-and-records.md) | 2 | [#109](https://github.com/ShiJiJS/chiyo/issues/109) |
| 4 | [接通 AI 申请、审批和资料读取](issues/w04-agent-integration.md) | 3 | [#110](https://github.com/ShiJiJS/chiyo/issues/110) |
| 5 | [补齐文件管理、系统打开和 PDF 预览](issues/w05-owner-files-and-preview.md) | 3 | [#111](https://github.com/ShiJiJS/chiyo/issues/111) |
| 6 | [让 AI 领取附件并释放本机副本](issues/w06-agent-file-delivery.md) | 4 | [#112](https://github.com/ShiJiJS/chiyo/issues/112) |
| 7 | [让 AI 使用 Token、SSH 私钥和凭据文件](issues/w07-local-credential-execution.md) | 4 | [#113](https://github.com/ShiJiJS/chiyo/issues/113) |
| 9 | [接通现有备份和恢复流程](issues/w09-backup-and-recovery.md) | 5、6、7 | [#114](https://github.com/ShiJiJS/chiyo/issues/114) |
| 10 | [核对并修补托盘、通知、退出和重连](issues/w10-desktop-lifetime.md) | 5、6、7 | [#115](https://github.com/ShiJiJS/chiyo/issues/115) |
| 11 | [完整打包并连续核对主要使用流程](issues/w11-matched-candidate.md) | 9、10 | [#116](https://github.com/ShiJiJS/chiyo/issues/116) |

父任务是 [#104](https://github.com/ShiJiJS/chiyo/issues/104)。建议顺序：2→3→4，接通 5/6/7，收口 9/10，最后 11。依赖用于选择当前可做的工作，不要求开多个 Agent。

## 持续推进

启动目标使用 [goal.md](goal.md)；执行者先读[执行约定](execution.md)、[当前进度](progress.md)、当前票及其评论。做完一张的实现、必要检查、修复、提交和回填后直接接下一张，不每票等用户回复。

computer-use 已获准在必要时使用。正式安装及需要用户认证的操作仍留到最后集中；2026-11-10 用户允许用现有实际资料验证，并允许为验证接续正常重启知予服务。九票自己的完成条件和 #104 真实交付条件分别判断。

## 现有基线

- 源码基线 `ac8960c77e124e7f10c3be3c6a67364db3a0ea2e`，PR #107。
- SDK、C++ 工具链、Windows release 与五个 AOT CLI 已准备好，见[本机开发说明](../../development/windows-local-setup.md)。此前 25 项选定检查不代表这九张联网工单已完成。
- 环境准备留下的脚本、开发说明和三处 lint 改动记录在 progress.md，启动时保留并核对。
- 执行方式参考此前[复盘](../server-multidevice/retrospective.md)；旧文件中的分支、后置范围和其他平台安排不覆盖本轮指令。

本目录保存正文、GitHub 实际编号、原生父关系/前置核对与 goal 描述。持续目标已启动；实际状态和首个动作以 progress.md 为准。

