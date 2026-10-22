# Mac 隐藏页面提示气泡与原生 AX 树修正

2026-10-22，#48/#50，仅 `codex/macos-adaptation`。产品 `00e1dd2`。
接续[表单用途与隐藏页过滤](macos-field-purposes.md)，不改 Windows 分支或 main，不运行 Windows CI。

## 原因与实际修正

原生多页搜索→凭据草稿→放弃更改后，曾出现旧确认框残留、设置页 AX 树为空。
只读诊断显示失败期间 Dart semanticsEnabled、窗口 active/key/visible 均保持 true，
增强辅助功能仅收到 true，未观察到关闭事件。engine stderr 实际出现 AXTree pending-node
更新错误；FlutterErrors=0 与正常退出不能作为辅助功能通过证据。

禁用本机用途适配器的独立 QA 对照仍失败，因此该适配器不是触发此现象的必要条件。
另一个“等待确认框完整退场”的 QA 假设也失败，未采用该产品改动；其试验测试和日志保留，
不将假设时序合同失败冒充独立产品缺陷。

截图曾显示隐藏收件箱的“上一页请求”提示仍出现在凭据页。查阅官方
[Flutter OverlayPortal/macOS AXTree issue #187198](https://github.com/flutter/flutter/issues/187198)
后，按此线索隔离页面 tooltip；这只是相关上游线索，不声称所有上游问题同因或均已解决。

最终产品为保留的 IndexedStack 页面增加 TooltipVisibility，只有当前页可显示 tooltip；
页面 State 保留。回归通过公开 TooltipState.ensureTooltipVisible 验证隐藏页面不能重新打开气泡，
精确最终测试在独立旧源码6278132上Mac/Windows widget两项失败，修正后相关24项通过、
严格分析0。最初仅检查既有气泡消失的测试在旧源码也通过，故未当成有效红灯；随后加强回归。
Windows widget模式不等于Windows原生验收。

## 分轮证据

| 独立轮次 | 产品/QA 来源 | 原生 AXTree 错误 | 结论 |
| --- | --- | --- | --- |
| adapter-on | a2e010a | 8 | 主树失效独立复现，状态开关未关闭。 |
| adapter-off | a2e010a，QA停用途适配 | 10 | 问题仍在；普通输入值别名也仍在。 |
| await-transition | b71209d，仅QA时序假设 | 5 | 假设未解决；不进产品。 |
| visible-tooltips | 6278132，仅QA气泡可见性假设 | 0 | 设置/模板实际保存及只读数据库核对成功，仅单进程诊断。 |
| product-final | 00e1dd2，正式实现 | 0 | 多页搜索、凭据草稿放弃、模板/信息保存与独立进程重开通过。 |

前四轮均为 observation-only，正常退出只证明诊断收尾，不代替保存/重开。
正式轮使用普通绑定、真实 SQLCipher/内存合成密钥和实际 CUA 操作：
PID57724 保存 SyntheticNativeTemplate、SyntheticField 及两项说明，
模板说明 Synthetic template description、字段说明 Synthetic field description；
实际 Tab 将屏外字段说明带入视图后填写。保存 MacFocusSaved 后正常⌘Q，
独立PID57873 GUI与只读连接确认以上内容保持，普通BaselineValue与原7字节附件v1保持。
两个进程均实际⌘Q退出0、库各关闭一次、Flutter异常0、端口关闭，无强制结束。
只读连接数据库/WAL/SHM字节保持，未保存凭据草稿未入库。

各轮669/668输入对固定Git对象与QA修改逐摘要核对。普通字段AX值别名仍有观察，
不能宣称完整VoiceOver、全部表单/窗口/主题、反向遍历或最终普通入口已通过。
此轮使用合成粘贴检查点，不增加中文IME成功声明；旧真实IME证据保持原范围。
reopened-template阶段文件内嵌的诊断快照来自edit模式（采集脚本固定读取edit），
该阶段文字记录真实重开GUI观察；独立重开证据以reopen.json、PID/退出及实际GUI为准。

## 候选与清理

PACKAGE_RESULT_PLACEHOLDER

固定4690e79普通预览未换包。其7971项清单字节/模式/链接与strict签名保持，PID53592仍在。
全目录相等检查曾因已有运行态 `.local/state/gh/device-id` 多一项失败；随后按清单逐项核对全部匹配，
保留该非包内运行文件（mtime为10月21日），不把它删作测试垃圾。
本轮系统Keychain调用/新密码提示0。SDK/依赖缓存、候选ZIP及私有恢复备份保留，
只清理自有生成App/dSYM、源码副本和构建缓存，不声称全盘个人文件已扫描。

#48保持OPEN 3/6、#50保持OPEN 2/6；原联合验收门槛不缩减。
[需要主人配合的目的、动作和耗时](macos-owner-assisted-acceptance.md)仍集中安排；
不把全部剩余问题推给人工，不为本轮修正反复触发系统密码。
