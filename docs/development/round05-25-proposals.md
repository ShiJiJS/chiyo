# Round 05 D3 · 提案与整理结果

Issue #25，基于已合入 D2 的 `df63de6`。本票复用既有录入、修改、删除、整理事务和 D2 纯编辑草稿，没有新增 schema。视觉审查、最终根分支合并及主入口导航消费仍待收口；本记录不表示已完成整体验收。

## 公开接口与行为

`OwnerAccess.queryProposals` 返回只含队列元数据的 `ProposalPage/ProposalEntry`：新增、修改、删除与整理结果共享队列；待确认、版本冲突、已处理分开。默认每页8项，limit 1–100、search最多2000字符、offset最多1000000；创建时间倒序、ID作为稳定次序。只搜索公开名称、提交方自述、用途及身份，不搜索字段值。显式 focus ID 定位其分页。已删除目标/字段和版本竞争均显示冲突，不能直接覆盖。

`UpdateReview` 是 owner 侧未保存的完整审阅输入；`previewUpdate(id, review:)`、`confirmUpdate(id, proposalVersion, review:)` 保持原调用兼容。目标信息 ID 和基础版本必须与原提案一致；目录、标签、公开说明及字段公开说明一起验证。review 中的 directoryId/tagIds 是完整选择，null/空集合表示未分类/无标签。最终仍通过既有 `_applyUpdate` 和 `confirmUpdateProposal` 原子提交当前内容、旧版本、回收事实和终态回执。无效输入不应用任何一项；重复确认返回已有回执。

桌面入口仍导出 `ImportProposalsPage`，内部为310宽队列与独立滚动文档卡。完整编辑复用 `InformationEditorDraft`、`EditableInformationField`、`InformationEditor`，保存回调只更新当前提案的内存草稿。切换条目、搜索及分页保留各提案草稿；外部终态会清理其草稿缓存。新增草稿还保留可明确舍弃的 suggestedDirectory/suggestedTags，不把名称建议伪造成稳定身份。不可用目录/标签明确标出，可显式修复；保存不会自动归类或发布数据。

新增、移除、普通值修改与语义替换分别列出。显式语义替换即使同名同类型也保留 replacement intent，确认取得新字段 ID；仍存在字段的值修正和公开说明调整保留 ID。新增/替换字段提示需重新授权。清空目录后重开草稿不会被原对象的默认目录覆盖。

批量确认前有590基本确认面板；批量存储/输入失败返回780流程面板，草稿仍在，用户返回核对后可重试。版本竞争转到同一提案的冲突/回执，原内容不被覆盖，并提供查看当前信息与重新提交路径。确认/拒绝/编辑的取消会归还焦点；处理完成焦点回到相应队列条目。

终态只显示处理事实与公开标题摘要；当前详情按结果 ID 每次查询，人工修改后显示当前值，删除后明确不存在，不读取旧提案字段。服务停止时当前详情清值并显示不可用。整理有变更、无变更、冲突、撤销各有只读结果，同一 task ID 关联本次授权。分类历史只读当前或保留期内的真实版本；历史已不可用则明确说明，不用当前分类冒充当时的变更结果。整理页不显示字段值。

## 主入口衔接

页面公开三个回调：`onOpenInformation(String itemId)`、`onGoToLibrary()`、`onOpenOrganizationGrant(String taskId)`。第一项为明确外部定位，第二项为普通 tab 切换，第三项按同一 task ID 打开历史记录。批量回执中的当前信息列表提供逐项定位入口，避免把多个结果误当作一个对象。

按任务协调，#27拥有 main/InformationWorkspace 的统一信息定位入口，保留普通 tab 回切状态，只在明确定位时清不匹配筛选；#26提供 `AuthorizationHistory.initialRecordId` 跨分页定位。D3不另写一套 main/library 导航。上述三个回调在主集成接入后的已访问信息库/搜索/分类移动/目标删除，以及历史跨分页定位，仍需由主集成验证。

## 自动验证

预先确认的 seam 为 owner 服务公开行为、真实仓储重开与真实 widgets；没有测试私有函数。新增逐行为 red→green 包括 UpdateReview、队列元数据、缺失字段冲突、单项草稿、显式 replacement 身份、确认期间竞争、整理无改动结果、服务停止清值、Esc归还焦点、不可用分类修复、分类建议舍弃、目录清空后重开，以及外部提案身份定位。已有批量事务/重试和分页搜索行为另作特征验证，不把首次已绿的断言描述成先红。

当前等价完整分包检查：CLI18、Core95、Storage43、Desktop76，共232项通过，各包 analyze 无问题。`check.ps1 -Offline` 首次在新文件一处括号风格 info 停止；修正后从 core/storage/desktop 逐包完成 analyze/test，CLI18保持同源已通过。最终根分支合并后追加统一脚本结果。

`packages/info_storage/test/proposal_review_test.dart` 用真实 SQLCipher 仓储确认：无效审阅整批不变，修改与元数据/字段公开说明同次提交，替换字段新ID、普通字段保留ID；重开后身份、旧版本、回收快照和清值终态保留，重复确认不产生额外版本。

公开仓储边界的 I/O 故障由控件测试注入：在 `confirmImportProposal` 提交前抛错，检查无部分内容或分类发布、调整值保留，解除故障后整批只提交一次。此注入不能冒充真实磁盘故障。

## Windows 原生

独立入口为 `scripts/test-windows-proposals.ps1` 与 `integration_test/proposals_native_test.dart`。复用隔离 fixture 创建临时 SQLCipher、Windows DPAPI 密钥和 loopback port 0，真实 CLI 为独立进程，未调用默认 profile/infos/Codex 配置，也没有通知探针。

native-r3 退出0（20.3秒构建、18秒测试）：CLI提交两项、仅改第一项草稿、第二项不可用分类令整批校验失败、明确修复后重试、重复确认不重复、手动更改当前值、从终态读取当前值，另验证拒绝、删除和冲突不可覆盖。停止 runtime 后 SQLCipher/DPAPI 重开核对回执和字段 ID。原生故障是实际输入/分类校验失败；I/O 注入为前述独立控件 seam。最后批量失败面板及分类建议变更后的原生复验仍待追加。

Mac真实测试按用户指示延期；真实通知气泡/系统窗口控制不属于本票通过范围。

## 视觉证据

唯一来源为 `docs/design/prototypes/round-05` 最终级联，未改原型配合 Flutter；共享 UiPalette、ProductSans/宋体/Consolas、SVG图标和 Theme。Widget capture加载真字体、保留阴影、DPR1、关闭测试 fixture 的 DEBUG banner；原图不裁切或重画。

`review-round2` 固定40张 Flutter与10张原HTML双视口参考图，manifest记录PNG及源码SHA。1440×900与1280×800包括新增、完整编辑、确认、差异、冲突、删除、整理、终态当前/改值/删除、失败/无结果/离线、200%首末、20条200字段长批次首末。长内容的末屏是真正 maxScrollExtent，普通截图与压力图分开。`compare-round2` 十对退出0；差分用于定位，不以一个像素比例宣布通过。

`review-round3` 固定46张Flutter与24张HTML，共70张PNG及源码hash，补齐整理无改动、冲突、撤销。D0原HTML为delete/organized/terminal-proposal/organization-noop/conflict/revoked；失败参考通过原型已有save-failed状态、关闭编辑面板、切到提案并确认触发，不注入新页面或修改脚本。新错误面板按真实HTML排为错误说明→未应用标题→返回核对，保留780宽与原先空标题/关闭区；notice父行高与说明间隔、整理链接padding也在本轮按参考收敛。旧固定轮不覆盖。`compare-round3` 24对正在执行，最终结果另记。

已知数据差异：生产使用真实 opaque ID；旧 update/delete 模型没有 Agent 名称与用途，诚实显示 Agent/核对提示，不能补造 Codex 身份。合成当前目录、标签、版本及结果数量来自真实服务调用；不为比图篡改身份或历史。Chromium与Flutter字边缘差异不能通过改原型或改颜色掩盖。

独立静态视觉审查尚在进行；这里只记录实现与证据范围，没有声称样式验收完成。主入口组合导航和最终根分支复验也仍单独跟踪。没有推送或写入 GitHub。
