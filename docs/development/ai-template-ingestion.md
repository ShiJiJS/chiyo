# AI 按模板录入

对应 [#78](https://github.com/ShiJiJS/agent-info-manage/issues/78)。Mac 分支开发中，未宣布整票完成，也尚未替换本机预览 App。

## 已接入的流程

App 开库后，把与插件设置和资料表单相同的模板来源接到本机服务。CLI 的 `plugin-list`、`template-list`、`template-read` 每次查询当前状态，不另存模板注册表。查询只返回公开模板资料；不会返回插件来源路径、受影响资料数或用户字段值。

`template-read` 返回 `definition`（格式、字段说明、关联声明、录入说明、虚构例子）与 `submissionExample`。Agent 用后者的结构提交 `import-submit`，其中 `templateId`、`templateVersion`、`templateDigest` 必须匹配当前可用模板，实际内容放在 `values`。不能自行提交编译后的字段或界面布局。没有适用模板就向用户建议并暂缓该项；查询接口没有安装或创建插件能力。

按模板新增经过正常提案审批，保存实际类型及模板快照，字段可独立授权，经历分成名称、时间和说明，文档保留声明的 plain／markdown 格式。原有平面录入协议保持可用。

修改仍用 `update-submit` 的 `update` 对象：提供已有 `itemId`、`baseVersion`、三个模板标识及完整 `values`；不要混用 `changes`。用户查看原文和拟修改内容，可核对后批准。相同标量字段保留身份，修改保存旧资料修订；提交和批准时都核对模板，审批界面仍能读取已提交的快照以便拒绝过时提案。

按条目保存录入决定的资料库格式为 43（此前模板快照为 42），防止旧版把已批准待入库的内容重新当成未审批的平面提案。待审批正文及快照保存在加密资料库，已入库条目从提案正文中移除，终态提案只留名称、状态与回执。

`relations` 按模板声明的关联键提供目标列表，目标为 `{"kind":"information","id":"目录中的资料ID"}` 或 `{"kind":"credential","id":"目录中的凭据ID"}`。现已支持已入库对象的关联；修改时省略该属性保留原关联，显式传完整映射则替换关联（空映射清除）。主人审批会核对目标仍存在且类型符合模板；批准只保存关系，不授予读取或使用许可。审批页和当前资料比较页展示关联变化前后的对象名称，主人也可在模板提案编辑器中调整关联。

## 新增资料的待审批关联

新增条目可提供稳定 `key`（英文、数字、点、下划线或连字符，最长64字符，首字符须为英文或数字）；不提供时服务生成 `item-0` 等键，并在 `import-status` 的 `items` 中返回。它是提案内的身份，不是正式资料ID。

关联同批待录入资料使用 `{"kind":"information","itemKey":"另一条的key"}`；关联同一会话的其他录入提案时再加 `proposalId`。不能引用或查询其他会话的待审批内容。

批准按条目保留。没选中的继续待审批；不相关的获准资料可以先保存。有待审批关联时，保留为“已批准待入库”，不会提前创建资料或开放读取。全部获准的相互引用作为一组提交，不会互相等待；跨提案的依赖也在同一次数据库事务中入库。

引用被拒绝时，相关资料保留为“需要处理”并说明引用对象，没有自动拒绝或删除。Agent 用 `import-revise` 提供 `proposalId`、当前 `version` 和需要修改的 `items`（必须保留原 `key`）；修改的条目清除原批准，需要主人重新审批。主人也可在原提案编辑器中移除或更换关联再批准。

CLI 状态区分 `pending`、`approved_awaiting_admission`、`needs_attention`、`confirmed`、`rejected`；每项还返回自身状态及真正入库后的资料ID。主人操作回执把已入库记录与等待条目分开，丢回复重试仍读取同一回执，不把批准当成已保存。

此段现阶段覆盖新增的普通资料。对已有资料的修改提案引用待审批内容、待审批凭据加入共同流程，仍须继续实现；当前修改接口明确拒绝此种待审批引用，避免静默丢失关联。

## 当前验证

- `apps/desktop/test/agent_template_discovery_test.dart`：真实加密库、本机 HTTP 服务和 CLI；安装、更新、启停、移除和重开后的动态查询；外部 Markdown 模板实际入库；查询不含用户资料或来源路径。
- `apps/desktop/test/agent_template_import_test.dart`：内置文字模板的查询例子实际提交、审批、修改及重开；类型、经历独立字段、Markdown 和主人核对结果；模板失效、非法格式与私有编译快照注入被拒。
- `packages/info_storage/test/template_import_storage_test.dart`：待审批模板快照持久化、格式标记和数据库加密。
- `packages/info_core/test/import_admission_test.dart`：独立项先保存、同批与跨提案互相引用、引用被拒后修复重新审批、会话隔离及插件变化。
- `packages/info_storage/test/import_admission_storage_test.dart`：等待审批持久化，模拟回执写入失败后所有相关资料和提案一起回滚，再重开恢复并重试。
- `apps/desktop/test/owner_admission_widget_test.dart`：真实加密库与主人审批页面显示待入库对象名称、“已批准待入库”和“需要处理”，批准后不会冒出未获准的正式资料。
- 同时保留原有新增、修改及主人审批回执回归检查。

## 仍须完成

#78 还需把修改提案接入待审批引用，并完善正式使用说明和独立验收；待审批凭据随 #79 接入共同流程。#79 凭据录入、#80 文件与长期版本保留及正式 Skill 更新、同模型独立新会话验收尚未完成。以上测试不替代这些要求或最终原生 App 验收。
