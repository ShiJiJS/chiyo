# D4 原生标题栏辅助树诊断与最小修复

2026-10-17。父任务的 plain 生命周期应用虽完成后台读取、恢复和退出，日志仍有11条 AXTree 更新错误。本次在独立工作区、临时 SQLCipher/DPAPI 信息库和随机端口真实复现一条可定位路径，并修复应用标题栏与 Navigator 的绘制顺序。没有修改 SDK、engine、OS 设置、语义开关、Tooltip 标签或原生窗口接口。

## 可复现的实际节点时间线

原生测试使用 `5ddb537`（含父任务 `314b485` 的归档）加同一份 plain QA 入口；修复前后只有 `window_frame.dart` 的生产差异。入口以透传 `SemanticsUpdateBuilder` 记录实际送往 engine 的增量，所有参数原样交给 delegate；不读取私有 Dart 语义树、不调用 `ensureSemantics`，也不使用 integration binding。首次 binding 记录已是 `semanticsEnabled=true`，不能由“截图操作”推断原生辅助桥未启用。

准备阶段只创建虚构信息并自动批准一次普通请求，通知对该 fixture 关闭。这不是审批或通知验收。实际通过 Sky 读取该窗口辅助树、进入设置再返回审批、点击自绘关闭按钮，窗口随即不可操作；通过真实 `NativeDesktopPlatform.showWindow()` 恢复，鼠标仍停在关闭按钮上，自然出现“关闭窗口”提示。

| 修复前批次 | 相对启动时间 | 实际增量与原生日志 |
| --- | --- | --- |
| 1–15 | 769–148687ms | 更新节点均可从根到达；根中缺少三个 Flutter 标题栏按钮。 |
| 16 | 156740ms | 更新根侧节点1及无父节点86，随后 engine 立即报 `86 will not be in the tree and is not the new root`。 |
| 17 | 156751ms | 节点86引入子87，87的标签为“关闭窗口”；86、87均不可从根到达，紧接着同一错误。 |
| 18–20 | 180324–188160ms | 增量中已无新孤立节点，原生仍重复同一错误。 |

以上序列见[完整增量与原始诊断清单](evidence/26-history-settings/ax-caption/manifest.json)。本轮修复前共20批、2批有孤立节点、5条 AXTree 错误；父任务原来11条的运行没有节点插桩，不能将两次运行的节点编号等同，或逐条反推出旧日志的节点归属。

## 应用侧原因与修复

`DesktopWindowFrame` 原先先绘制标题栏、后绘制 Navigator。所用 SDK 的 `routes.dart:2352` 为普通 ModalRoute 创建 modal barrier，`modal_barrier.dart:264` 使用 `BlockSemantics`；该控件会屏蔽同一语义容器内较早绘制的控件。因此标题栏虽可见、可点击，其三个按钮及 Tooltip 锚点却不在根辅助树内。外层 `Overlay.wrap` 中随后出现的 Tooltip 仍发送自己的节点，产生上述无父增量。

新增公开控件回归使用实际 `MaterialApp.home` 的 Navigator 和 `DesktopWindowFrame`，通过 `tester.semantics.simulatedAccessibilityTraversal()` 观察可访问内容。原实现红测只得到 Workspace，没有三个标题栏按钮；不是对私有 state 或节点编号断言。

修复仅先绘制 workspace，再绘制 caption，并用 `Column.verticalDirection = VerticalDirection.up` 保持标题栏在顶部34px，workspace仍从34px开始。没有移除语义、Tooltip、窗口命令或可聚焦性，也没有改 `main` / `desktop_shell` / MethodChannel API。绿测确认三个按钮的 Tooltip、button/focus/tap 能力；从公开辅助 focus 动作聚焦最小化后，Enter 激活、Tab/Enter 到最大化和关闭均正确。原有鼠标控制、拖拽、无原生支持降级、启动页替换后最大化状态三项继续通过。

## Windows 修复后复验

同一 plain QA 入口重建后创建全新临时信息库，执行相同导航、关闭、恢复和提示步骤，再重复一次关闭/恢复。修复后共23批真实语义增量，孤立批次0、AXTree 错误0。真实 UIA 树包含最小化、最大化、关闭窗口三个 Flutter 按钮；显示中的“关闭窗口”提示位于关闭按钮下。第二次恢复后再进入设置，辅助树也更新到外观页，而非只保留旧树。

实际[恢复后的截图](evidence/26-history-settings/ax-caption/after-restored-tooltip.png)、[辅助树](evidence/26-history-settings/ax-caption/after-restored-tree.txt)、[后续设置辅助树](evidence/26-history-settings/ax-caption/after-settings-after-show-tree.txt)、增量、构建及红绿日志均按 SHA 固定。初次 QA helper 生成有语法/类型编译失败，修正后才开始原生运行；失败日志也保留，不能将 helper 编译失败算成产品失败或已完成验收。

针对性检查：`window_frame_test.dart` 4项通过，两个修改的 Dart 文件 analyze 无问题。最终再合入父任务稳定 `1d986bec`（D3/D5），标题栏及回归测试文件与原生验证时字节一致；合并后首次 headless 加载因本工作区尚未解析新依赖 `unorm_dart` 失败，运行 offline pub get 后同4项与 analyze 再次通过，失败及后续日志均保留。此次没有重跑无变化的四个文件选择器或整套229项，也没有把这些旧结果称为新候选的全量检查。原生两进程均正常退出，已向父任务和 #27 释放窗口。

这关闭的是本次有前后对照的 caption/Tooltip 路径。原父任务 plain 生命周期入口仍应由独立 merger 合入后的主任务复验；不据此宣称所有 Flutter Tooltip/ListView 情形、真实托盘点击、系统通知点击或 macOS 实机已通过。

## engine 诊断的影响与 Drift 的区别

本机 Flutter 3.47.7，framework `abaf9c523780a608bd46686fd5e53740a07077f8`，engine `deb287481e3ce9468f3434937ced4240a70539ca`。按该版本本机源代码，`accessibility_bridge.cc:108` 调用 `AXTree::Unserialize` 后读取 `error()`；出错即在事件派发之前返回。`ax_tree.cc:1346` 的分支正对应未由父节点引入、又不是新根的节点。其 `error_` 不在后续成功更新时清空，因此同一编号重复日志并不证明有同样多次独立的坏增量；修复前18–20批也实际显示这一点。这不是可随意忽略的无害输出，不能通过消音或禁用辅助树处理。

四个真实文件选择器日志中的 Drift 多实例警告是另一件事。Drift 2.35.2 `db_base.dart:77` 的 debug 计数按 `runtimeType`，并不检查实例是否真的共用 QueryExecutor。该 fixture 同时打开源库 `fixture.root.path` 和接收库 `fixture.root.path/recipient`，DPAPI文件也分开；重开接收库前先关闭原实例。`EncryptedInformationRepository.open` 对实际 canonical 目录作进程内占用保护并取得独占文件锁，每次调用为其 `library.db` 新建 sqlite handle 和 `NativeDatabase.opened`。因此这条警告本身不能证明该 fixture 同库竞争、复用 executor 或损坏；保留警告，没有修改 Drift 全局诊断设置，也没有据此豁免真实存储异常。

## 复现入口

将归档 `ax_probe_app.dart.txt` 原样复制到 `apps/desktop/.scratch/ax_probe_app.dart`，其余两个 Python 文件放到根 `.scratch`。从 desktop 目录执行 `flutter build windows --debug --no-pub --dart-define=D4_AX_PROBE=true -t .scratch/ax_probe_app.dart`。从项目根运行 `start_ax_probe.py`，它只创建本工作区 `.scratch/ax-probe/synthetic-*` 目录和随机 loopback 端口，生产 main 不导入入口。

`ax_control.py request seeded-request` 只做虚构请求准备。之后通过实际窗口按上文导航并关闭；`ax_control.py show native-show` 调用真实 show API，再读取实际辅助树与提示。`ax_control.py quit complete` 正常关闭 runtime。不要把控制器的准备或 show 命令算成真实审批、托盘点击或完整退出 UI 验收。归档 `.log` 仅去除已失效的 VM 调试地址行；其余诊断和批次全部保留，原文件 SHA 与位置见 manifest。未归档临时数据库、DPAPI密钥或活动许可。
