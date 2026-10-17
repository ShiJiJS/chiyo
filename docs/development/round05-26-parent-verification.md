# D4 历史、设置与备份主集成复验

2026-10-17。独立 merger 将最终视觉候选 `308b08c` 合入 `26a1cca`，合并树与候选一致。`1741886` 只整理捕获工具末尾空行；`0c09d77` 再合入恢复后已挂载偏好控件的回归测试与记录，未修改生产行为。以下为主任务在实际集成源码上的独立检查，不以实现者的原生结果代替。

## 合并与自动检查

在 `1741886` 上运行完整 `scripts/check.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin -Offline`，退出 0：CLI18、Core96、Storage46、Desktop69，共229项，各模块 analyze 通过。`0c09d77` 新增的真实根页面恢复回归由 merger 再验2项，确认恢复后仍停留在备份分区，记录控件显示源备份的5分钟/180天，通知控件显示关闭；原有成功回调有效，没有为未复现的疑点修改产品代码。

原始检查和下述 native 日志、来源 SHA 见[验证清单](evidence/26-history-settings/parent-verification/manifest.json)。完整 diff-check 会报告原始 `.log` 的工具进度行尾空格；这些原始日志保留不改。限定排除该证据目录内日志后，其余源码和文档单独检查，不能把这一点写成完整 diff-check 零警告。

## 原型还原范围

主任务复核固定来源与候选源 SHA，并查看实际恢复1280、记录200%和模板编辑等图。独立视觉评审历轮固定双方原图、尺寸和 SHA：默认 r3 四对保持关闭；辅助 aux-r2 六组修正经复核后，仅剩保留期框内基线、模板移除叉和通知/备份实体线；最终 aux-r3 的8张实际图关闭这三处。外部原始报告为 `C:/Project/network_config/info-manage-worktrees/26-fidelity-review.md`，最终候选为 `308b08ccb9effdf078ceb3a5f3c0f15d71fe5149`。

结论限于该报告明确看过的静态范围。真实恢复统计、额外边界说明、系统通知不可用行及其自然高度保留；字体栅格差异不作为实体几何偏差的豁免。业务、OS文件选择、关闭/退出按各自真实流程验收；不将本页结论推广到其他尚未合入的页面。

## 四个真实 Windows 文件选择器

在 `0c09d77` 上运行 `scripts/test-windows-history-settings.ps1`，临时 SQLCipher/DPAPI 信息库和随机 loopback 端口，全程只用截图操作系统对话框，没有在测试中开启 UIA。

首轮停在恢复密钥另存阶段，上下文切换后未及时完成选择，等待提示的断言超时，runner退出1；保留 `native-picker-timeout.log`，不记为成功。未修改产品、测试断言或等待规则，及时操作重跑后实际完成：

1. 将恢复密钥另存到测试库之外的独立目录；成功前不允许首次导出。
2. 加密导出到另一文件，再在新的空库选择该备份。
3. 另选先前保存的恢复密钥文件，验证真实数量并确认恢复。
4. 验证信息、主题、模板和过去事实恢复，活动请求/许可不恢复，旧 token 读取拒绝；关闭并经 SQLCipher/DPAPI重新打开复验。

第二轮构建16.9秒、测试84秒，`D4_NATIVE_ACCEPTANCE=PASS real-pickers separate-key export restore no-live-authority DPAPI-reopen`，`All tests passed`，退出0。日志保留 Drift 同一数据库类多实例警告；fixture 的源库、接收库使用不同实际路径，不复用 QueryExecutor，没有关闭该诊断。此结果覆盖 #24 与 #26 的合并源码，替代此前只能分别验证的限制。

## 原生关闭、后台读取、完全退出及重启

另编译独立 QA 入口，生产 main 不导入它。入口要求 `D4_NATIVE_LIFECYCLE=true`、明确配置参数和 `native-lifecycle-probe/synthetic-*` 目录，仅建立虚构信息及关闭该 fixture 的通知。准备阶段自动批准该 fixture 的普通请求，不能把它算作真实审批 UI 验收或产品能力。

实际使用 `DesktopBootstrap`、`NativeDesktopPlatform`、SQLCipher/DPAPI，以及另一进程中的真实 JSON-lines CLI。主任务以 Sky 截图操作真实窗口：

- 点击窗口关闭按钮后，Sky报告窗口不再是可用应用窗口；进程仍在，CLI继续成功读取已有许可范围。
- 控制器通过实际 `showWindow()` 接口恢复窗口，主任务截图确认重新可见。这没有覆盖托盘图标点击。
- 在设置的“应用运行”页点击“完全退出”，再在确认框点击退出。进程退出0，原CLI返回 `service_unavailable`。
- 同一配置、端口、加密库重新启动，原CLI持有的旧授权返回 `unauthorized`；公开目录的信息ID保持不变。
- 再次由实际设置页确认退出，应用与CLI正常退出0，输出 `NATIVE_LIFECYCLE_VERIFIED`。

[原生结果](evidence/26-history-settings/parent-verification/native-lifecycle-result.json)固定各阶段事实。QA源与控制器按实际运行字节归档：将 `native_lifecycle_app.dart.txt` 复制至 `apps/desktop/.scratch/native_lifecycle_app.dart`，控制器复制至根 `.scratch/native_lifecycle_controller.py`；前者在desktop目录用 `flutter build windows --debug --no-pub --target .scratch/native_lifecycle_app.dart --dart-define=D4_NATIVE_LIFECYCLE=true` 构建，后者须在交互式PTY运行。按实际窗口状态分别输入 `background`、`restore`、`exited`、`restart`、`finish`，不能先提交后续步骤冒充操作。控制器的 `exited`/`finish` 只等待正常退出，没有代替用户点击的终止接口。

准备时首次以非交互管道启动，stdin立即EOF，只有 READY，未算验收；主任务核对精确PID及独立Debug可执行路径后终止该次fixture。随后交互式PTY完整一轮通过。测试均未操作用户已有应用、默认profile、47125端口或个人infos。

## 尚待核对的边界

plain QA应用日志出现11条 Flutter `accessibility_bridge` 的 AXTree 更新诊断，原始日志保留在隔离运行目录，其SHA及不含VM调试URL的诊断原文已归档。功能与退出断言虽通过，不能因此把这些诊断说成不存在；已交回实现者只读定位，未消音或降低断言。根页面视觉验收仍使用DPR1的固定双视口，真实桌面为DPR2、约1267×707逻辑内容，两者不混称。

本轮没有真实托盘点击或系统通知点击成功证据，#23及相关平台票继续保留缺口；macOS新文件对话框handler已写，实机按用户指示延后。#27–#31和服务器同步未因本次历史/设置检查而完成。GitHub状态需按本页证据及仍待诊断项更新。
