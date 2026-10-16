# D2 · 信息库管理与恢复

2026-10-17，Issue #24。使用 #23 的 UiPalette、字体、SVG 图标和顶部导航，按 `docs/design/prototypes/round-05/` 最终级联还原信息库。当前记录区分服务行为、离屏视觉和真实 Windows 流程；Mac 实测按用户指示延期。没有启动用户资料库、读取真实 infos、修改 Codex 配置、同步服务器或写入 GitHub。

## 行为与身份

信息库保持 240px 目录、340px 列表和剩余详情三栏，主标题为 ProductSans 26/700。目录、列表、详情独立滚动；小视口保留全部三栏并允许横向滚动。目录以稳定 ID 表达父子关系，重命名或移动不会更换身份，服务拒绝移动到自身下级。目录可展开和包含下级筛选，标签按 AND 查询。

`owner.queryInformation` 只搜索公开元数据，不搜索字段值；按小写名称、ID 稳定排序，包含零字段信息。公共页长 1–100，界面每页 50；搜索最多 2000 code units、最多 100 个标签。底层查询现有 repository 快照，不声称已经改成 SQL 游标加载。筛选、翻页、删除和刷新按稳定身份协调选择；没有结果清空详情。被服务拒绝的查询明确报错并清空旧结果，不能静默展示上一条件的数据。

手动创建、模板创建和完整编辑共用编辑器。公开说明就是 `InformationItem.description`；受控文本说明就是 `FieldKind.textNote`，没有新建隐蔽备注列。模板只复制空白结构。保存前可预览公开 catalog 元数据，值不会出现在此预览。未保存离开需明确放弃；写失败保留输入；版本冲突保留输入并要求重新核对。删除或语义替换字段有明确确认。

`owner.editInformation(itemId, expectedVersion, {name, description, directoryId, tagIds, changes, fieldDescriptions})` 复用 `_applyUpdate` 和 `commitRecycleChange`。信息、上个修订、删除快照及事实在一个事务中保存，事务成功后才失效已删除字段的许可。本人编辑不创建 Agent 会话或新增/修改提案。

信息 ID 稳定。仍存在字段的普通值修正、字段公开说明和历史内容修正保持 field ID；删除、语义替换及显式回收恢复得到新 field ID。批准快照、过去授权及历史快照原样保留，旧 ID 不成为新 ID 的授权别名。

回收站与修改历史分别保留 30 天。历史恢复先预览差异，再创建当前信息的新版本；不会回退授权、其他信息或应用设置。历史需要已删字段时，必须先在回收站明确恢复。`RecycleFact.restoredFieldIds` 可选 JSON map 记录同条信息的 old→new 来源，在恢复事务内与新 ID 一起保存。历史预览仅沿这些显式来源解析到当前 ID，支持 A→B→C；缺失映射仍要求回收恢复，同名字段不用于推断，循环或歧义拒绝为 `revision_conflict`。已清理字段不会被历史自动重建。旧 JSON 没有 map 时默认空，不在读取或迁移时猜关系。

SQLite 已有 `recycle_facts.payload` 存储完整 JSON，不新增 schema。完整备份校验 map 的来源属于 `fieldIds`、目标唯一且归于相同信息；备份和重新打开原样保留来源。与 #26 的 backup4 合并时仅保留同一套可选字段校验，不能删去旧格式兼容或把 map 投影掉。

## 后续页面复用接口

| 接口 | 文件 | 约定 |
| --- | --- | --- |
| `InformationEditorDraft` | `apps/desktop/lib/information_editor.dart` | 无存储能力的草稿；`original` 固定基准，公开 name/description/directoryId/tagIds/fields 可调整；`changes`、`fieldDescriptions` 生成保存输入 |
| `EditableInformationField` | 同上 | `original` 可空；name/kind 改变生成 replace，值改变生成 correct，说明改变保留身份 |
| `InformationEditor(draft, onSave, directories, tags, templates, title, saveLabel)` | 同上 | `Future<void> Function(InformationEditorDraft)` 保存回调；编辑器负责草稿、校验、放弃/失败界面，不持有 owner，不调用 owner 副作用。#25 应传提案保存回调 |
| `owner.editInformation(...)` | `packages/info_core/lib/library_access.dart` | 本人保存专用，`expectedVersion` 冲突拒绝；changes 沿用公开 `FieldChange` |
| `createInformation/createInformationFromTemplate` 的 `directoryId/tagIds` | `packages/info_core/lib/info_core.dart` | 可选 named 参数，第一版本原子保存分类；既有调用兼容 |
| `InformationLibrary.onMigrateSecretFields` | `apps/desktop/lib/library.dart` | #31 接入既定“转换旧秘密字段”入口。尚未接入时给出真实不可用反馈；不替换为无关动作 |
| `PrototypeDialog`、`prototypeSecondary/Primary` | `apps/desktop/lib/prototype_dialog.dart` | 590 basic /780 flow，复用 UiPalette。编辑器具有内滚动 gutter；恢复列表和 taxonomy 仅外层 gutter |
| `prototypeCh(context, fontSize, count)` | `apps/desktop/lib/prototype_ui.dart` | 用实际零字形 advance 和 textScaler 表达 CSS ch，避免按 em 猜测说明列宽 |

凭据关联区显示真实“未关联”，不创建假凭据。#27 接入后需核对真实关联行和自然高度；#24 的编辑、删除、恢复不扩大普通字段许可，也不擅自改变凭据生命周期。

## 验证

```powershell
# 仓库根目录
./scripts/check.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin -Offline
./scripts/test-windows-library.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin
# cwd apps/desktop；真实字体、DPR1、debugDisableShadows=false
flutter test --no-pub tool/capture_library.dart
# 仓库根目录；仅 QA 展示原始 Flutter PNG，不是产品 HTML 实现
node apps/desktop/tool/compare_library.mjs compare-r3
```

主要纵向切片经过 red→green：公开 owner 原子编辑及冲突、删除后显式恢复/重新批准、删除前历史内容沿显式来源修正、真实 SQLCipher 重开和完整备份来源回读。少量既有行为和畸形来源循环/歧义为补充特征测试，未把首次已绿的断言宣称为先红。原有 CLI 删除测试继续断言旧 ID 被拒绝，再对新 ID 重新批准读取，没有弱化授权断言。保存失败控件测试在 `commitRecycleChange` 边界注入失败，保留草稿并重试。

离屏测试实际操作新建/模板/分类标签、编辑失败、未保存放弃、当前删除后的选择、回收和历史确认/失败。长内容独立 fixture 含 120 条附加信息和 24 个附加长字段；200% 首末状态保留全部栏、字段可达及固定操作区。压力图不替代常规双视口 HTML/Flutter 对照。

真实 Windows 独立入口使用 `integration_test/support/isolated_desktop.dart` 创建临时 SQLCipher、Windows DPAPI 密钥和 loopback port 0，使用惰性系统平台，不运行默认入口。真实 Flutter 控件完成模板→字段/受控说明→分类标签→删除→回收恢复→历史恢复。真实 JSON-lines CLI 在独立进程申请、claim 和读取：旧字段拒绝、未删除字段继续可读、新 ID 在新批准前拒绝；对新 ID 重新批准后读取，并在历史修正后读到当前值。停止 runtime 后用 SQLCipher/DPAPI 重新打开核对新 ID 和来源映射。两轮原生通过；窗口 physical2534×1414、DPR2、logical1267×707，不能冒充 canonical 1440×900 内容视口截图。

全量检查在视觉 r2 后通过 CLI18、Core91、Storage42、Desktop62及各包分析；随后新增两项畸形来源特征测试，`library_test.dart` 9 项通过。最终合并和后续检查结果在本文末追加。Mac 实测、真实系统通知气泡点击不属于这些通过项；没有运行通知探针。

## 视觉证据和复核

证据索引见 `docs/development/evidence/24-library/README.md`。只按最终已确认 HTML，不改原型配合 Flutter，也不使用 Material 近似图标。D1 公共 palette、ProductSans 字体、宋体 modal 标题和 prototype SVG 原样复用；正文只有 Regular 资产，粗体由相同字体合成。

独立 r1/r2 采用固定图规范对照，不评分。修正包括主动作加号和文案、工具栏右动作及左 breadcrumb 分别对齐、quiet 高度34、footer #31接缝、close 锚点、110宽保存按钮、secondary border宽度、输入40高/内边距、标签 y332 和说明段落、taxonomy 48ch/首表单/66.5行距与编辑入口间隔、恢复列表右 gutter和empty列宽。r2 的旧差异图含中文元数据混入等宽值导致的黑块，r3 已改为值与元数据分别排版并重取，旧固定图未覆盖。最终 r3 独立复核进行中，不能据测试通过宣称视觉完成。

保留的差异有明确来源：稳定 Unicode/ID 排序与 HTML 的本地排序不同；#27 尚未关联时不补造凭据，相关区自然高度不同；实际编辑/差异/恢复确认和保存错误的附加文案属于真实能力。Chromium 次像素与 Flutter 灰阶字边缘差异不通过改色补偿。说明列宽、实体线和锚点仍按 HTML 对照。

按钮沿用共享 120ms 状态反馈和 modal 路由进入/退出；没有新增装饰动画或额外视觉方向。未删真实对象名称、状态和判断依据。oil 截图 compare 的8个 report 均无 issues/lint，差分仅用于定位，不计算通过评分。
