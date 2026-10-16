# Round 05 — #26 授权历史与设置

## 范围与公共接口

本候选实现历史、设置、录入模板和手动备份恢复；服务器同步属于后续阶段，界面不显示无功能的服务器模式。继续复用 #23 的普通请求和整理任务，不从历史创建授权或执行记录。

- `OwnerAccess.history()` 返回批准范围快照、实际读取、普通请求非秘密事实，以及保留期内的 `organizations`。名称和范围冻结在当时；旧记录缺失的名称显示“未记录”，不使用当前改名补写。
- `RequestHistory` 不保存字段值、session secret、proof、token；pending 不写入历史。关闭应用记录取消或结束事实，重新打开不能恢复许可。
- `OwnerAccess.notificationsEnabled` / `setNotificationsEnabled` 持久化应用提醒开关。通知不可用和本机服务不可用分别说明。
- `deleteTemplate(id, expectedVersion)` 删除结构模板，不删除已用模板创建的信息。模板保留字段类型与说明，不保存值。“使用模板”复用 #24 的 InformationEditorDraft / InformationEditor，字段从模板复制为空白草稿；只有保存才通过真实 owner 行为创建信息，失败保留草稿。旧 860 弹窗已删除。
- `AuthorizationHistory(initialRecordId: taskId)` 选中已有记录并进入所在分页；找不到 ID 显示记录不在当前保留范围内或未记录，不跳到无关授权。重复打开同 ID 可由调用方更新页面 key；设置入口继续通过 `onOpenRecordSettings` 回调到真正的 records 页面。
- D1 的“请求设置”和历史的“记录保留设置”接到根导航。主题保存与恢复通过根 `MaterialApp` 更新，失败保留输入。

## 持久化和保留

数据库 schema 13 新增 `request_history`；旧库直接升级路径同时保留既有内容时间、回收和版本结构。`backup_configuration.recovery_saved` 只保存在本机加密库，不进备份。

审计默认 90 天，可选 30/90/180/365。缩短前由 `previewAuditRetention` 显示真实授权、访问、请求和已结束整理记录数量，必须使用本次 preview 确认。清理后的事实不会因延长期限重新出现。整理清理只删除超过 cutoff 的有效终态；pending、active、proposed 不删除，待处理整理仍留在收件箱。历史展示和确认影响数量采用同一保留范围。回收内容及修改版本独立保留 30 天。

`InformationRepository.pruneOrganizationHistory(ids)` 是持久化接缝，由服务在审计队列内只传终态 ID；SQL 成功后才更新缓存。整理任务及整理结果仍不进入备份。

完整备份格式 4 增加普通请求事实，继续读取格式 1–3。旧访问记录可缺失冻结名称；可选 `RecycleFact.restoredFieldIds` 使用统一模型 JSON 和严格校验，保留 #24 的来源映射。恢复的审计事实保留原时间并带恢复标记，不恢复会话、proof、pending、活动许可或整理任务。

## 真实备份流程

生产设置页使用同一 780 宽备份流程：创建密钥 → 真正另存独立恢复密钥文件 → 才能导出加密备份。保存失败或取消不会解锁导出，已有文件不会被覆盖。`recoveryKeySaved` 是实际文件 I/O 成功后的状态，不以说明弹窗代替保存。

恢复流程同时选择备份文件与恢复密钥文件，先验证空库、读取文件和认证备份，再展示真实数量并要求确认。`recipientEmpty()` 只是预览；最终恢复仍在原子事务中重新检查全部目标数据。错误保留文件选择和预览，不覆盖现有库。恢复密钥输入通过 Windows 文件对话框和 macOS NSOpenPanel 平台适配。

## 验证证据

TDD 的已确认接缝为公开 `InformationService.owner` 行为、真实仓储重开/备份恢复、必要 widgets 与隔离 Windows 原生流程。新增行为按单条红→绿推进：请求事实重开、密钥文件保存门槛、备份 4、偏好失败保留、根主题导航、整理保留 cutoff 和按实际 task ID 跨页打开历史。

- `packages/info_storage/test/request_history_test.dart`：冻结读取名称；密钥文件 I/O 成功前导出拒绝；完整备份恢复无活动能力；普通终态重开。
- `packages/info_core/test/settings_history_test.dart`：模板删除不删信息；整理名称与实际完成时间；跨 31 天缩短后清理且延长不复活，近期活动任务仍可读取整理元数据。
- `apps/desktop/test/settings_round05_test.dart` 与 `backup_widget_test.dart`：偏好失败不丢草稿、搜索选择一致、真正导航/根主题、错误密钥重新选文件、空库预览恢复。
- `integration_test/history_settings_native_test.dart` / `scripts/test-windows-history-settings.ps1`：临时 SQLCipher + DPAPI + 随机端口，不打开真实 profile。

`evidence/26-history-settings/windows-native.log` 是旧分步布局的首次完整 PASS。统一 780 流程的 `windows-native-unified.log` 中业务断言到 PASS，但 UIA 读取在测试中途开启了平台 accessibility，结束校验报 SemanticsHandle 计数变化，该轮 runner 失败，保留记录。`windows-native-unified-screenshot.log` 使用同一流程和全部断言、仅截图操作四个真实系统文件对话框，最终 runner 退出 0、`All tests passed`。这轮实际完成独立密钥另存、加密导出、双文件打开、空库预览确认、旧 token 拒绝及 DPAPI 重开。该原生验证在合入 #24 之前完成。其后 #26 的变更为布局、字体、说明、共享模板编辑入口和按已有记录 ID 定位，没有更改平台文件 I/O 或恢复事务；#24 的回收来源与备份校验已合入并通过最终完整检查，未把两轮原生结果说成同一源码的联合运行。

## 视觉证据与独立复核边界

视觉来源唯一为 `docs/design/prototypes/round-05` 最终 CSS，参考图只读。1440×900 与 1280×800 均使用生产 Flutter 页面、真实字体和 `debugDisableShadows=false` 离屏渲染。历史使用 310 收件箱与单纸张；设置使用 260 导航及 940 居中内容；普通弹窗 590，备份流程 780。

- `evidence/26-history-settings/r3/`：默认 history-scope 与 appearance 四对截图及 compare。独立复核 r3 已关闭 r2 四组微项（notice、分页、footer/button、主题卡），只对这四对默认画面有效；不推及其他子页或业务。
- `evidence/26-history-settings/states/`：正常通知/记录/模板/备份/运行页；590 模板编辑/失败、保留确认；780 备份初始/错误/恢复预览/确认后；空历史/异常/长会话与范围；四主题；200% 字号及滚动至备份操作区。源为真实服务和临时 SQLCipher，文件适配器只替换 picker 边界，文件读取、密钥保存、认证、导出、恢复均真实执行。
- `tool/capture_history_settings_states.dart` 的最终两视口运行见 `states-capture.log`，无 RenderFlex overflow。200% 是可访问性压力状态，不充当常规内容还原图。
- `states/compare-*` 使用 oil-ui-pro `shoot.mjs --compare` 对同尺寸 HTML 原图与未缩放 Flutter PNG 生成叠加和差异图。HTML 包装仅承载实际截图，工具的页面 lint 不是 Flutter 业务验证；差异百分比不作为通过阈值。
- 合理差异另列：实际通知/托盘不可用会增加真实状态说明；记录影响数和备份数量来自仓储；未实现的凭据历史不伪造；模板额外删除和展开说明是实际功能；fixture 会话计数/名称和字体抗锯齿不冒充实现差异。

`approval-aux/` 固定自定义授权期限 590 basic 与完整字段值 780 flow 的双视口实际图；紧凑最终范围预览也复用 PrototypeDialog。它们是公共 modal 规则的延伸，原 HTML 没有两种专用状态，不声称存在专用逐像素参照。`states/startup-key-unavailable-*` 使用独立临时 SQLCipher 原库关闭后缺失 key 的真实 bootstrap 失败 fixture，保留原库；它没有可用服务或列表，与 HTML 应用内 key-unavailable 不是同一可用性状态。启动失败和审批离线文案已统一“信息库”。

新增辅助页和弹窗已自看与 compare，仍待父任务独立视觉复核；不得将默认四对通过推广为全票视觉验收完成。只保留候选以便后续定向修复。

## 人工残余

macOS 新文件选择 handler 已实现，本机没有 macOS 实机验收，按用户指示延后。#23 系统通知气泡实际点击仍未成功验收，本票没有重跑 probe，也没有把 Shell 接受请求当作点击成功。未修改用户 OS 设置、真实资料库、个人 infos 或 Codex 配置。没有写 GitHub、push 或关闭 issue。

## 候选检查与后续独立复核

合入主集成 `c8d4561`，回收来源 validator 只保留 #24 的一套全局 target 唯一/计数/fieldOwner 校验。合并新增的 library backup 场景也真正另存独立密钥文件后才导出。

`scripts/check.ps1 -Offline` 最终退出 0，见 `evidence/26-history-settings/full-check-final.log`：CLI 18、core 96、storage 46、desktop 69，共 229 项；各模块静态检查均无 issue。另 `preferences-reopen-restore.log` 的 4 项公开仓储验证覆盖通知关闭、等待期限和主题在加密重开与备份恢复后的值。

待父任务独立复核新增子页、590 模板、780 备份与恢复预览、模板使用入口、审批辅助弹窗和 bootstrap 失败页。恢复预览目前保留实际分项数量及恢复边界说明，文字比原型 fixture 更多，弹窗高度与专门预览参考仍有明显差异，不能计为视觉通过；后续按独立反馈定向收口。默认 r3 的已闭合四对不重开。
