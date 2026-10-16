# D1 · 普通读取与整理收件箱

2026-10-17，Issue #23。延续 #22 已确认的顶部模块导航、左收件箱—文档核对—决定栏和紫棠、松石、雾蓝、灰底黑白四主题。只使用虚构资料、临时加密库、随机端口和隔离 DPAPI 密钥；没有访问真实 infos、应用资料库或 Codex 配置。

**状态：WIP 检查点，D1 未完成。** 用户在看到实际截图后明确要求完全按 HTML 原型执行，当前 Flutter 的结构/功能验证和此前视觉润色复核不能作为忠实还原验收。以下记录已实现行为和中间证据；下一步按同尺寸原型精确还原字体字号、导航高度、列宽、留白、纸张边界、决定栏和全部控件，不关闭 Issue。

## 实现

- `ui_palette.dart` 提供继承式 `UiPalette` ThemeExtension，所有桌面原 `UiColors` 引用、共享表面、输入、菜单、对话框和窗口条均改为从 context 读色。`informationTheme([DesktopColorTheme])` 是统一入口，不使用可变静态颜色。警告与危险状态保留语义颜色。顶部共享导航采用“信息库”；信息库内部页面迁移由 #24 承接。
- `workspace_access.dart` 的 owner 公共接缝统一普通读取与整理请求：`queryInbox(search, filter, offset, limit, focusRequestId)` 返回有界 `InboxPage`，limit 为 1–100。先按 createdAt 倒序，再按 ID 排序；搜索聊天、用途、ID 和信息名称。默认页 20 条。底层仍扫描既有 repository 内存快照，不声称已经改成 SQL 游标加载。
- 搜索/状态/翻页不保留不匹配的旧详情；当前对象、字段和期限草稿、请求列表/文档/最终范围滚动按稳定身份保存。新请求插入导致当前对象移到另一页时，仍定位正在核对的对象，避免批准错对象。`/` 聚焦搜索；大字模式保留请求选择、状态和翻页。
- 普通读取继续显示原申请、最终选择、遗漏/补选数量，支持跨信息项补选和 1–10080 分钟自定义期限，独立申请默认 480 分钟。字段值先提供有界预览，长值可打开完整内容。已处理、取消、过期请求不出现批准/拒绝动作。
- 决定按请求防重复操作。无效范围保持 pending 和原选择，可修正后重试；审计写入失败则重读真实 approved 终态、阻止内容读取，并提供“重试保存记录”，不会重复批准。服务不可用保留已有视图并停用决定。
- 整理批准仍是一次决定：固定所选身份/版本、标题与说明及分类标签元数据，并允许分类标签写入，最长 30 分钟。完成（含无改动）即结束能力；冲突不应用整批。请求与结果使用同一个 task ID，结果入口复用真实记录，不新增第二次确认。旧版 proposed 方案继续沿原审阅语义处理。
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
| `InboxQueue` | `apps/desktop/lib/inbox_queue.dart` | 接受有界 page、独立 controller、选择/查询回调，不拥有业务决定或草稿 |

保留 nav-0…、request-<requestId>、field-<fieldId>、approve-selection、grant-lifetime-<requestId> 等已有自动化语义 key。没有引入凭据申请卡片，后续由 D6 接入。

## 验证与证据

SDK：`C:\Users\Todoki\.local\share\flutter\bin`。命令从仓库根目录运行，标注 cwd 的除外。

```powershell
./scripts/check.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin -Offline
./scripts/test-windows-native.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin
# cwd apps/desktop
flutter test --no-pub test/inbox_workspace_test.dart test/workspace_widget_test.dart test/organization_tasks_test.dart
flutter test --no-pub tool/capture_workspace.dart
# cwd packages/info_core
dart test test/workspace_test.dart
# 仓库根目录；已有 Windows native build 配置后运行
$cmake = ((Select-String -LiteralPath apps/desktop/build/windows/x64/CMakeCache.txt -Pattern '^CMAKE_COMMAND:INTERNAL=').Line -split '=', 2)[1]
& $cmake --build apps/desktop/build/windows/x64 --config Debug --target notification_queue_test
& ./apps/desktop/build/windows/x64/runner/Debug/notification_queue_test.exe
```

公共服务测试经过 red→green：240 请求的稳定页、搜索、目标页定位与状态筛选；混合整理条目及无改动完成；主题写失败/新 service 读回。桌面新增覆盖真实控件下的主题跨页/失败/重新打开、61 请求分页与每请求草稿、新请求插入保留当前对象、通知跨页定位、异步目标消失后的修正，以及 200% 下已批准但审计保存失败后仅重试保存。原有授权边界、跨项选择、8 小时、整理、信息生命周期和备份断言保留；仅将旧左导航/首个插入对象等布局假设改为已确认的新结构或显式选择。

原生 Windows 检查打开真实 Flutter 窗口，真实 JSON-lines CLI 经 loopback 申请→桌面移除原字段/跨项补选→claim 返回精确范围→重复读取→未批字段拒绝→撤销后拒绝。随后 CLI 发起整理→桌面一次批准→读取元数据→无改动完成→后续 metadata 只返回 `{status:confirmed}`，不返回元数据；桌面可打开同一整理结果。主题通过桌面控件保存，再关闭隔离库并用 SQLCipher/DPAPI 重新打开核对偏好。

截图脚本加载现有 AppSans、MaterialIcons 和本机 Consolas，使用真实 Flutter 渲染，fixture 含 241 请求、24 字段和长字段名/长实际值。输出在 [evidence/23-workspace](evidence/23-workspace)：1280×800、1440×900、200% 字体、四主题；`*-last-field.png` 是实际滚到末字段后的画面。脚本同时验证首个完整字段在大字模式的决定区之前、滚到末字段仍能点击批准、决定位置不动、完整值入口可打开返回，没有 overflow。截图是离屏 Flutter 证据；真实原生窗口由独立 native 命令证明，两者没有混同。

独立无评分视觉评审一轮、定向复核一轮：原评审发现 200% 首屏没有完整字段、队列/正文滚动提示缺失、右摘要黑色粗滚动条。已合并大字控制区并去掉重复定位、保留完整字号与必要说明；三块滚动区统一细主题灰阶滚动条。主 Agent 和独立复核均查看修改后的首字段/末字段截图，三项可见问题已解决。未重新探索风格。没有网页截图工具的 lint 提示；视觉评审不替代功能/焦点/原生测试。

真实 macOS 运行、macOS 通知投递/点击及跨平台互通按用户指示延期；Windows 原生通知气泡点击没有人工操作验收，已验证 Dart owner 路由并实际编译对应 Windows runner。没有因此宣称全平台交付，也没有关闭 Issue 或修改 GitHub PR。

当前完整 `scripts/check.ps1 -Offline` 通过：CLI、Core、Storage 全部分析/测试及 desktop analyze、60 项桌面测试。原生 Windows CLI 流程和主题重新打开检查通过；新增串行通知 adapter 的 C++ 合约检查通过。后续手动真实气泡入口暂按用户最新指示停止，先保存本检查点并完成精确还原。源码和集成基点见本记录所在 Git 提交；没有把上述检查写成 D1 的视觉完成。
