# 本机焦点填充的 Windows 用户流程检查点

2026-10-19，用户解锁后继续。正常 `WidgetsBinding` 下的两轮隔离流程通过：Win32 密码框来源 `5ab8995`，当前 Codex 内置浏览器来源 `1bbcd8f`，两个实际进程均退出 0。**#35 保持 OPEN**：默认 `testWidgets` 的原生辅助功能崩溃仍需定位，完整故障矩阵和最终交付门槛继续保留。

## 已验证的实际流程

使用真正 Windows runner 内绑定的 broker 摘要、正式驱动、隔离 SQLCipher/DPAPI 资料库和独立编译的 JSON-lines CLI。Flutter 的实际批准、确认、历史、人工确认和撤销控件由 `LiveWidgetController` 驱动。窗口管理使用应用已有的 channel，只最小化/恢复本任务的 QA 窗口。没有操作用户旧应用或真实资料库。

两轮各产生一次批准、三次完整输入和一次中途改变焦点的未知结果：

| 条件 | 实际结果 |
| --- | --- |
| 批准前后 | 批准只保存许可，输入操作仍为 0；重新点击目标后由 CLI 触发输入 |
| Unicode、中文、emoji、首尾空格 | 接收器在自己的测试边界内核对随机假密码，三次均完整匹配 |
| 同操作 ID | 返回原结果，未追加输入；新操作复用原许可，不重新审批或续期 |
| 中途改变目标 | Win32 为 unknown/focus_changed；浏览器切到普通文本框为 unknown/unsupported_target；后续新 ID 被 fill_needs_attention 拒绝 |
| 人工确认 | 实际 Flutter 确认入口保存检查事实；清空、重新聚焦后原许可可明确再用 |
| 撤销 | 实际 Flutter 撤销后新操作返回 grant_revoked，未创建输入操作 |
| 重开加密库 | 各保留 1 条申请/4 条操作，许可未复活；这一步没有另启服务并用旧 CLI 会话查询，不扩大为该项证明 |

浏览器的校验页只向随机 loopback 端口提交合成输入；这些值不写入日志、控制文件、CLI 回执或 Git。Win32 接收器的原生剪贴板序号检查与浏览器页面的 paste 事件计数分别核对，两轮均无 paste、剪贴板不变。测试专用接收器读取自己的输入作匹配校验，生产 broker 不读密码值。

## 当前内置浏览器的支持记录

当前宿主为 `OpenAI.Codex_26.1013.4894.0` 的 ChatGPT.exe，实际文件摘要、CLI 回执及操作事实固定在验证清单。批准绑定应用文件身份；网页地址仍只是 Agent 自述，不能据此证明域名。

1. 浏览器工具说 DOM 密码框已聚焦时，前台实际可能仍是审批窗口或测试接收器。原生发现返回 unsupported_target，没有输入。只有两个 QA 窗口让出前台、再次点击密码框后才返回 ready。显示浏览器面板本身不保证 Windows 前台切换。
2. 正式 CLI 输入后，页面的正常 AX 快照显示 `Value: <redacted>`；显式读取该输入框的 `value` 也返回 `<redacted>`，正常截图显示圆点。
3. 点击测试页的“显示明文”后，截图确实出现合成内容，随后恢复遮挡。这是保留的泄漏对照，不能宣称本软件会清理所有截图或外部工具输出。

第 2、3 项为本会话浏览器工具的实际观察；像素显示在会话工具结果中，未保存本地 PNG，也未对浏览器工具的完整传输载荷作原文扫描。仓库保存文字转录及 CLI 的原文/JSON 转义精确扫描事实，不伪造截图哈希。这些结果只对应当前宿主及这一个合成页面，不承诺远程、无头、后台浏览器或任意工具兼容。

## 失败和诊断仍保留

- 原生 testWidgets 的两轮在打开确认流程时发生 0xc0000005。匹配 SDK PDB 将其中一份 dump 定位到 `flutter::AccessibilityBridge::CreateRemoveReparentedNodesUpdate +186`，RVA 0x3c1ea。原始 dump 不入库，只保存符号化元数据。上游有[同函数崩溃报告](https://github.com/flutter/flutter/issues/175041)，尚不能证明具体触发原因相同。
- 不由测试框架主动请求语义的另一轮到四分钟边界，没有显式关闭，整轮失败；随后完整走完的 testWidgets 轮在结尾报 `A SemanticsHandle was active at the end of the test`，也记失败。[上游相似句柄报告](https://github.com/flutter/flutter/issues/153850)不作为本地已修复的证据。
- 普通 MaterialApp 弹窗的最小原生诊断 1 项通过；正常 WidgetsBinding 的完整 Win32/浏览器流程也通过，批准及输入时实际语义已开启。没有关闭生产辅助功能、修改 SDK、吞掉测试框架断言或将失败轮重标成功。完整触发条件仍需进一步区分。
- 独立入口首版直接调用测试 `expect`，在测试 zone 外失败，随后改为同一 Matcher 的显式核验回调。一次 shell 直接启动 GUI 没有取得真实 exitCode，不计通过；之后使用带标准流重定向和进程句柄的启动方式。
- 浏览器首轮未让出前台，发现被拒后控制器错误继续申请，整轮失败。第二轮最小化后 QA 控制循环等待帧，原命令未开始；保留超时、原控制状态及精确 PID 停止记录。已修为正常应用入口在等待命令时使用异步计时，不等待最小化窗口的帧。第三轮完整通过。一次控制文件替换遇到 Windows 读句柄，确认未发布后重试同 ID，随后补有界替换重试；没有重新触发凭据操作。

## 复现和固定来源

源码入口 `apps/desktop/tool/focused_fill_native_probe.dart` 要求 `FILL_STANDALONE_PROBE=true`；生产 main 不导入它。Debug 构建另指定 FILL_CLI、FILL_RECEIVER 和独立 FILL_EVIDENCE 目录；浏览器轮再指定 `FILL_BROWSER_PROBE=true`。CLI 来自此前 `3e98ec6`，相关 CLI 生产输入协议未改变。默认 testWidgets 回归仍是 `integration_test/focused_fill_native_test.dart`，没有改成默认关闭语义。

控制器快照见[验证目录](evidence/issue35-native-user-flow/verification.json)旁的 `control-native-ui.py.txt`。复制到 ignored QA 目录后，只对本轮目录发 discover → request → approve → fill 等动作。发现拒绝时先处理目标，不能继续申请；申请/批准、首次回执和后续查询须分别观察。浏览器轮需在 discover/fill 前让出 QA 前台，进行审批、历史和确认前恢复自己的窗口。四分钟内必须显式 close；只有最终 assertionsPassed 与真实进程 exitCode 同时通过才计成功。

验证清单固定原始日志、事件、控件渲染、来源文件和锁文件哈希；最新浏览器 Debug EXE、kernel_blob、引擎和 helper 均有摘要。早期被后续构建覆盖的 Debug kernel 没有哈希，不声称其字节与当前资产一致。两个公开 stdout 版本仅移除了已退出的 VM 调试 URL，保留原文件摘要并明确标为派生文本。

测试标签页、临时静态服务器、接收器、CLI、服务和本任务 runner 均已关闭，Computer Use 两个会话均 reset。用户旧包仍为 0.4.0+8；此前 QA ZIP 未重建，不以这次 Debug 诊断替代最终 Release 或干净 Windows 验收。无子 Agent，服务器同步继续暂停。
