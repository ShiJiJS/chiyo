# D1 · 普通读取与整理收件箱

2026-10-17，Issue #23。延续 #22 已确认的顶部模块导航、左收件箱—文档核对—决定栏和紫棠、松石、雾蓝、灰底黑白四主题。只使用虚构资料、临时加密库、随机端口和隔离 DPAPI 密钥；没有访问真实 infos、应用资料库或 Codex 配置。

**状态：本次提供的 #23 状态样式已完成独立定向复核，交主集成复验；D1 保持开放，人工系统气泡点击仍未验收。** `44c3318` 是此前行为/主题 WIP 检查点，不是视觉验收基线。用户要求实际 Flutter 严格按已确认 HTML，随后按 `prototype-fidelity.md` 和同尺寸 canonical 参照逐项修正；此记录区分已测业务、离屏视觉、真实窗口观察及未验项目，不以旧结构评审替代还原结论。

## 实现

- `ui_palette.dart` 提供继承式 `UiPalette` ThemeExtension，所有桌面原 `UiColors` 引用、共享表面、输入、菜单、对话框和窗口条均改为从 context 读色。`informationTheme([DesktopColorTheme])` 是统一入口，不使用可变静态颜色。警告与危险状态保留语义颜色；mono的status与notice.warn按原CSS使用灰阶，表单/审计错误仍红色。顶部共享导航采用“信息库”；信息库内部页面迁移由 #24 承接。
- `workspace_access.dart` 的 owner 公共接缝统一普通读取与整理请求：`queryInbox(search, filter, offset, limit, focusRequestId)` 返回有界 `InboxPage`，limit 为 1–100。先按 createdAt 倒序，再按 ID 排序；搜索聊天、用途、ID 和信息名称。公共查询默认页 20 条；审批界面按原型每页 8 条。底层仍扫描既有 repository 内存快照，不声称已经改成 SQL 游标加载。
- 搜索/状态/翻页不保留不匹配的旧详情；当前对象、字段和期限草稿、请求列表/文档/最终范围滚动按稳定身份保存。新请求插入导致当前对象移到另一页时，仍定位正在核对的对象，避免批准错对象。`/` 聚焦搜索；大字模式保留请求选择、状态和翻页。
- 普通读取继续显示原申请、最终选择、遗漏/补选数量，支持跨信息项补选和 1–10080 分钟自定义期限，独立申请默认 480 分钟。字段值先提供有界预览，长值可打开完整内容。已处理、取消、过期请求不出现批准/拒绝动作。
- 决定按请求防重复操作。无效范围保持 pending 和原选择，可修正后重试；审计写入失败则重读真实 approved 终态、阻止内容读取，并提供“重试保存记录”，不会重复批准。服务不可用保留已有视图并停用决定。
- 整理批准仍是一次决定：固定所选身份/版本、标题与说明及分类标签元数据，并允许分类标签写入，界面提供真实 15/30 分钟，未传参数仍默认 30 分钟，公开服务拒绝非正数或超过 30 分钟。期限草稿按请求保留。完成（含无改动）即结束能力；冲突不应用整批。请求与结果使用同一个 task ID，结果入口复用真实记录，不新增第二次确认。旧版 proposed 方案继续沿原审阅语义处理。
- 原生通知只传不具备授权能力的 request ID。Windows 通知气泡与 macOS 通知点击将 ID 交回 owner 桌面；通用托盘打开不伪造请求定位。跳转清除旧搜索并定位到目标页，缺失对象给出明确反馈。通知正文不含 agent 用途、字段或授权材料。
- Windows 原生 adapter 串行投递气泡，活动消息绑定固定 ID，后续请求/测试通知排队，只有 HIDE/TIMEOUT/USERCLICK 才推进。MethodResult 在实际 Shell 投递时完成；Explorer 重建时更新 tray ID，忽略旧图标回调并拒绝未投递项。依据 [Microsoft Shell_NotifyIcon 文档](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyicona) 的排队及终态通知语义，避免“最后一次 notify ID”替代被点击气泡的 ID。native adapter 合约测试覆盖 A/B/测试通知交错、投递失败、隐藏/超时、点击与重置；不是人工气泡点击证据。

## 后续票复用接口

| 接口 | 所在文件 | 使用约定 |
| --- | --- | --- |
| `UiPalette.of(context)` | `apps/desktop/lib/ui_palette.dart`，由 ui.dart 导出 | 新页用 ink/muted/canvas/rail/paper/line/accent/selected/strong；不添加静态全局 palette |
| `informationTheme([DesktopColorTheme])` | `apps/desktop/lib/ui.dart` | 统一文本、控件、语义状态和滚动条；120ms 控件反馈、150ms 进入，保留 reduced motion |
| `owner.colorTheme / setColorTheme(theme)` | `packages/info_core/lib/workspace_access.dart` | enum purple/green/blue/mono；设置 key `desktopColorTheme`，复用原 int settings 与串行写入，失败不更新保存值；无新增 schema |
| `_changeTheme` / DesktopShell 回调 | `apps/desktop/lib/main.dart` / desktop_shell.dart | MaterialApp 由保存后的偏好重建；#26 设置入口需将主题选择回调至 app，不能只写设置后局部换色 |
| `queryInbox` / InboxEntry / InboxPage / InboxFilter | `workspace_access.dart` | owner-only；普通请求仍遵循现有内存生命周期，跨重启的非秘密终态历史由 #26 承接；不是 active grant 的持久化 |
| `DesktopPlatform.openedRequestId`、`notifyNewRequest(String)` | `desktop_runtime.dart` | opaque ID 的 owner 路由；`runtime.openRequestId/openApprovalsRevision` 交给 Approvals 的 focusRequestId/focusRevision。用户通知启停偏好与运行时抑制由 #26 接入 |
| `prototypeText / prototypeButton / PrototypeCheck / PrototypeSelectCaret / PrototypeSelfDescription` | `apps/desktop/lib/prototype_ui.dart` | CSS 字号/行高、四圆角按钮、17/16px复选框、native-select V、用途说明继承行盒；正文 ProductSans 仅 Regular400，用已有资产合成粗体。宋体/Georgia/Consolas 用系统，不打包闭源字体 |
| `PrototypeIcon(PrototypeIconGlyph.*)` | `apps/desktop/lib/prototype_icons.dart` | 原型全部13枚SVG逐路径 painter；默认18、24viewBox、1.65圆描边。助手提交848bde8合入为4aedfee，不用Material近似轮廓 |
| `OwnerRequestSnapshot.grantLifetime / InboxEntry.organizationRemainingSeconds` | `info_core.dart` / `workspace_access.dart` | 已处理显示真实决定期限，不猜默认值；整理待办倒计时来自服务注入clock，与普通一致，非DateTime.now另算 |
| `InboxQueue` | `apps/desktop/lib/inbox_queue.dart` | 接受有界 page、独立 controller、选择/查询回调，不拥有业务决定或草稿 |

保留 nav-0…、request-<requestId>、field-<fieldId>、approve-selection、grant-lifetime-<requestId> 等已有自动化语义 key。没有引入凭据申请卡片，后续由 D6 接入。

## 验证与证据

SDK：`C:\Users\Todoki\.local\share\flutter\bin`。命令从仓库根目录运行，标注 cwd 的除外。

```powershell
./scripts/check.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin -Offline
./scripts/test-windows-native.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin
# cwd apps/desktop
flutter test --no-pub test/inbox_workspace_test.dart test/workspace_widget_test.dart test/organization_tasks_test.dart
flutter test --no-pub tool/capture_workspace.dart tool/capture_fidelity.dart
# 同尺寸四格/叠加/差分，仅QA，原始PNG不改写
# cwd 仓库根目录
python apps/desktop/tool/compare_fidelity.py
# 可选真窗口短暂观察，正常默认0秒；有上限，不产生系统通知
./scripts/test-windows-native.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin -VisualHoldSeconds 60
# cwd packages/info_core
dart test test/workspace_test.dart
# 仓库根目录；已有 Windows native build 配置后运行
$cmake = ((Select-String -LiteralPath apps/desktop/build/windows/x64/CMakeCache.txt -Pattern '^CMAKE_COMMAND:INTERNAL=').Line -split '=', 2)[1]
& $cmake --build apps/desktop/build/windows/x64 --config Debug --target notification_queue_test
& ./apps/desktop/build/windows/x64/runner/Debug/notification_queue_test.exe
```

公共服务测试经过 red→green：240 请求的稳定页、搜索、目标页定位与状态筛选；混合整理条目及无改动完成；主题写失败/新 service 读回。桌面新增覆盖真实控件下的主题跨页/失败/重新打开、61 请求分页与每请求草稿、新请求插入保留当前对象、通知跨页定位、异步目标消失后的修正，以及 200% 下已批准但审计保存失败后仅重试保存。原有授权边界、跨项选择、8 小时、整理、信息生命周期和备份断言保留；仅将旧左导航/首个插入对象等布局假设改为已确认的新结构或显式选择。

原生 Windows 检查打开真实 Flutter 窗口，真实 JSON-lines CLI 经 loopback 申请→桌面移除原字段/跨项补选→claim 返回精确范围→重复读取→未批字段拒绝→撤销后拒绝。随后 CLI 发起整理→桌面一次批准→读取元数据→无改动完成→后续 metadata 只返回 `{status:confirmed}`，不返回元数据；桌面可打开同一整理结果。主题通过桌面控件保存，再关闭隔离库并用 SQLCipher/DPAPI 重新打开核对偏好。

精确还原截图加载已有 NotoSansSC-Regular 为 ProductSans，另从 Windows Fonts 载入 SimSun、Georgia、Consolas（不写入发布资产），内容视口 DPR=1、文字100%。常规 fixture 为27条请求、8待办，选中“部署北辰文档站”，两信息/四字段；未申请的额外合成catalog只使补选弹窗具有与原型相近的真实内容密度。压力 fixture 独立为241请求/24字段。`debugDisableShadows=false` 用于截图真实blur；初次粗阴影是widget-test默认去blur后的实色offset影，已纠正，并在测试结束前恢复调试变量。

| 证据 | 内容及限制 |
| --- | --- |
| `fidelity/purple-1440.png`、`green-1440.png`、`purple-1280.png` | 真实Flutter离屏，分别1440×900、1440×900、1280×800；和canonical同主题同视口，非HTML截图 |
| `fidelity/purple-1440-scope.png` | 780宽、最大viewport-64，自然收缩；blur背景、父子各15px stable gutter、48ch两行说明、相邻margin折叠的28px字段节奏、固定footer；目录批量入口仍可操作 |
| `*-organization.png`、`*-organization-active.png`、`*-organization-complete.png` | 真15分钟选择、切换离开再回来保留草稿，一次批准后autoapply、无改动完成；信息数量不同于canonical的预置四项完成记录，未补造业务范围 |
| `*-handled.png`、`*-audit-failure.png`、`*-empty.png`、`*-offline.png` | 真实终态/保存失败后重试、无匹配结果、关闭隔离service后保留视图并停用决定；错误不写成“未创建授权” |
| `*-comparison.png` | `compare_fidelity.py`生成的HTML/Flutter/50%overlay/3倍差异四格，无缩放；差异只是定位区域，不计算通过分数 |
| `inbox-1280/1440/blue/mono/200*.png` | 压力样例四主题/200%和实际滚到末字段；验证首个完整字段、独立滚动、固定决定位置及完整值弹窗，不替代常规同内容对照 |

独立 fidelity 评审指出并迭代修正：56高顶栏/嵌套决定卡/纵排字段等首版结构；随后定位并修正持续scroll thumb、期限框/V及动作边界、主题描边、请求标题0.5字距、用途说明父行内行盒、字段组间累积偏移、scope行margin折叠与双gutter、handled期限/clock层级、组织路径右对齐及整栏边线。常规实色线核对：范围456；字段614/654/772/812；批准620–664；tab分界249。已处理线404/562/602/720/760、组织线404/549/607也与对应HTML相同。这些坐标用于定位和防回归，不代替独立人眼最终结论。

文字仍有 Chromium RGB 次像素与 Flutter 灰阶栅格的边缘差异；调色不补偿AA。公共色值与原CSS一致。200%采用同视觉语言的紧凑控制区和固定决定区，保留完整文字缩放；它是原型未覆盖的可访问性延伸，不能据此改正常首屏布局。

真实 Windows 原生测试输出 physical2534×1414、DPR2、logical1267×707，推算192DPI。主Agent另用Computer Use观察并截图唯一隔离exe：真实中文宋体、顶栏/队列/主题已出现；窗口含原生caption和fixture惰性平台不可用提示，不冒充1280×800 canonical内容视口。观察中拉丁宋体有较细/稀疏笔画，可能与原生栅格/DPI/WGC有关，本轮未据此改字体/颜色，也未将其认定为所有原生字号已像素一致。

原生初次复跑因懒加载字段未建树，改为真实滚动；下一次因小高度下结果入口在屏外，改为真实滚入再点，未删业务断言。最终真实CLI/窗口闭环通过。`-VisualHoldSeconds 0`默认不停留，显式1–60秒才在`D1_VISUAL_READY`后真实停留；该入口只为观察隔离窗口，不模拟任何通知点击。

真实 macOS 运行、macOS 通知投递/点击及跨平台互通按用户指示延期；Windows 原生通知气泡点击没有人工操作验收，已验证 Dart owner 路由并实际编译对应 Windows runner。没有因此宣称全平台交付，也没有关闭 Issue 或修改 GitHub PR。

最终完整 `scripts/check.ps1 -Offline` 通过：CLI18、Core84、Storage41全部分析/测试及desktop analyze、60项桌面测试。原生 Windows CLI 流程和主题重新打开检查通过；新增串行通知 adapter 的 C++ 合约检查通过。为优先还原样式，本轮未执行人工系统气泡点击；仅有路由、队列及编译证据，后续Windows验收仍需尝试。本次精确还原结果另交主Agent复核。源码和集成基点见本记录所在 Git 提交；没有把上述检查写成 D1 的视觉完成。


## 本轮保存范围

最终基线合并到主集成 `a225606`（canonical状态参照与规范）；后续若主集成再前进，交付前再合并。没有修改GitHub/PR、没有关闭Issue，也没有开始服务器同步。为优先还原样式，本轮未执行人工系统气泡点击；通知定位的Dart与C++队列边界及原生编译已测，后续Windows验收仍需尝试真实气泡点击。


最终针对采集为9项（常规紫/绿/1280/mono及压力四主题/200%），全部通过。mono另有整理/离线/审计失败状态图；警告panel取样为背景`#f4f4f5`、边线`#c6c6ca`、文字`#3f3f44`，审计错误保持红色。`QuietNotice(panel:true)`用于CSS notice.warn，默认inline warning历史调用仍表示表单/保存错误，避免把flow-error一并灰化。


最终独立定向复核已收口：scope组锚265/366/467/568/669、placeholder374、关闭叉1042–1055；handled期限555/595与摘要线616；整理期限455/495、完成摘要线516均对应。mono常规/整理/离线未见明显主题渗色。主Agent已实际查看scope、complete、mono、empty、audit及200%首末字段，并以HTML为参考做最后compare；不将差分指标当通过评分。结论只限本票已提供状态，不推断全软件已还原。

最后源码的Windows原生闭环再次通过（`.scratch/d1-final-source-native.log`），包含真实CLI申请/范围/默认8h/重复读取/拒绝未批/撤销、一次整理与无改动结束、真实结果入口及加密库主题重开；最终命令和范围见上文。主Agent接下来在主集成独立复验。本票未执行人工系统气泡点击，不能据此关闭通知定位验收条目。

## 显式手动 Windows 通知探针（后续验收入口）

主集成 `1852f8c` 已合并回独立工作树。新增入口只涉及 integration test、隔离 fixture 适配参数和脚本，不改生产 UI 或通知协议。`IsolatedDesktopFixture.start` 默认仍用惰性平台；只有显式手动探针注入 `NativeDesktopPlatform`。可选 `prepareLibrary` 在 runtime 订阅请求事件前预置25条合成请求，不会向真实 Shell 连发25条通知。

探针选择真实排序中首屏以外的申请，先留下无匹配搜索并切至信息库，隐藏本隔离 runner，再只投递该申请的一条真实系统气泡。输出 `D1_NOTIFICATION_READY requestId=… remainingSeconds=…` 后由操作人员点击气泡；从投递起最多60秒等待。只有原生回调带回同一 ID、`runtime.openRequestId`/revision 更新、实际详情 `detail-<ID>` 和队列选中目标可见、用途与目标吻合且旧搜索清空，才输出 `D1_NOTIFICATION_VERIFIED`。没有直接调用 `handleEvent`、伪造 MethodChannel 回调或设置 `openedRequestId`。Shell拒绝、通知不可用和60秒无真实点击都明确失败，不作为验收通过。

```powershell
# cwd C:\Project\network_config\info-manage-worktrees\23-workspace
# 必须先安排一次操作人员可点击的空窗；未传 -Run 时脚本直接拒绝启动。
./scripts/test-windows-notification-manual.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin -Run
```

该脚本只对专用 integration test 传 `D1_MANUAL_NOTIFICATION=true`；不带 define 的测试默认跳过，不由常规 `check.ps1` 或 `test-windows-native.ps1` 执行。使用临时 SQLCipher/DPAPI 目录与 port0，结束沿原 fixture 路径边界校验清理；不打开默认用户库、不改系统通知权限/设置，不隐藏或关闭已有用户 app。

准备阶段已通过 `flutter analyze --no-pub`、PowerShell AST 语法检查和 `git diff --check`。此记录时尚未启动真实气泡探针，等待主Agent安排空窗；上述静态检查不是人工通知点击证据。

### 2026-10-17 第一次实际尝试：未验成功

主Agent确认完整检查/原生窗口空窗后，执行上述带 `-Run` 的命令。真实 Windows runner 编译成功，Shell `notify` 返回 true 并输出 `D1_NOTIFICATION_READY`（剩余59秒）。从投递起60秒内未收到携带目标 ID 的真实点击，`runtime.openRequestId` 仍为 null；断言明确失败，测试与脚本非零退出，没有输出 `D1_NOTIFICATION_VERIFIED`。原始日志保存在 [windows-notification-attempt-2026-10-17.log](evidence/23-workspace/windows-notification-attempt-2026-10-17.log)。

这证明本次探针实际运行、Native adapter 接受一次投递及等待超时，不能证明气泡已展示或已点击，也不能据此断言系统通知权限关闭。没有补注入回调使测试通过，没有自动循环重试。fixture 完成停止/关闭/临时目录删除，进程与 `aim-native-approval-*` 目录检查均无本次残留；没有触碰用户 app 或默认 profile。交付前另合并了主集成文档基线 `5842e6a`。

第一次的实际人工观察由主Agent完成：仅在 `DISPATCH` 后、`READY` 确认前调用一次 `Sky.list_windows`，列表未出现通知窗口或已隐藏 runner；没有发出任何点击。这一时间点和窗口枚举不足以判定 Shell 气泡是否展示，不能作为系统权限故障证据。

### 2026-10-17 第二次也是本轮最后一次尝试：未验成功

主Agent明确授权第二次有界尝试，通知投递/等待/断言逻辑保持相同。真实 runner 再次编译成功，Shell accepted 并输出 `D1_NOTIFICATION_READY`（剩余59秒）；主Agent收到 READY 后立即连续两次调用 `Sky.list_windows`、一次 `list_apps`，均未获得“信息访问授权”气泡或通知宿主的可操作窗口，主动隐藏的 runner 也未返回。没有执行任何点击，也没有猜坐标操作未观测的 toast；这些枚举结果不等于 OS 未展示，更不能据此判断系统权限故障。

本次自然等待满60秒，`runtime.openRequestId` 仍为 null，测试/脚本明确失败且没有 `D1_NOTIFICATION_VERIFIED`。独立日志见 [windows-notification-attempt-2-2026-10-17.log](evidence/23-workspace/windows-notification-attempt-2-2026-10-17.log)；两份日志仅规范了行末空白，未改事件/断言内容。运行结束无本隔离 runner 进程或临时目录残留。没有继续自动重试、修改系统设置/权限或伪造回调，真实人工 Windows 系统气泡点击保留在整体平台验收中，后续可沿本显式入口继续；本轮没有将此项判定通过。
