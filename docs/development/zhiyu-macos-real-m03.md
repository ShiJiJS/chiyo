# 知予 Mac M03：真实审批接入实施记录

关联 [#72](https://github.com/ShiJiJS/agent-info-manage/issues/72)，规格见 [M03](../planning/zhiyu-round09/issues/M03.md)。在 `codex/zhiyu-macos` 实施，整票仍 OPEN。

## 2026-10-30：审批决策的原子存储基础

新增 `InformationApprovalReceipt`、`InformationApprovalCommit` 和仓库合同；内存仓库与真实 SQLCipher 仓库实现同一约束。回执只保留操作编号、请求编号、动作、审阅摘要、命令摘要、决策版本和时间，不含正文、会话秘密或读取凭证。

- 回执、请求历史和授权历史在同一事务中提交；SQL 写入或最后一步运行状态校验失败，所有表和内存缓存保持原状。
- 同操作编号不能重复提交，同请求决策版本必须连续；批准/拒绝不能覆盖已有终态。批准核对资料版本和请求字段集合；撤销必须延续同一授权，并完整保留原请求的身份、范围、用途等事实。
- 回执查询同时核对 payload 与表内操作编号、请求编号、版本；不一致报错，不能当成成功或未提交。
- 默认库格式 34 → 36，可移植焦点填充库 35 → 37，保留旧可移植格式的边界。没有新增备份格式；本机决策回执不导出，成功恢复使接收库旧回执失效，失败恢复整体回滚。
- 这些接口只保存决策事实，不创建运行中的会话、授权凭证或读取能力。重开库后的历史沿用既有恢复规则，不复活授权。

### 验证

全部使用隔离合成资料和测试密钥，未使用个人库或系统 Keychain、未运行 Windows CI、未使用 computer use，也未重新打包或替换用户预览。

| 范围 | 命令（包目录内执行） | 结果 |
| --- | --- | --- |
| storage | `../../scripts/dev-macos.sh dart test test/approval_operations_test.dart --reporter expanded` | 9通过：原子落盘与重开、范围/重复/撤销冲突、最终校验及SQL失败回滚、备份排除与恢复失效、拒绝无授权、回执列一致性、并发竞争、34/35迁移 |
| core | `../../scripts/dev-macos.sh dart test test/information_approval_operations_test.dart test/workspace_test.dart test/history_test.dart test/session_end_transport_test.dart --reporter expanded` | 12通过 |
| desktop | `../../scripts/dev-macos.sh flutter test --no-pub test/owner_workspace_approvals_test.dart test/owner_workspace_source_test.dart test/owner_workspace_agents_test.dart test/owner_workspace_host_test.dart --reporter expanded` | 20通过 |
| 静态检查 | core/storage `dart analyze`；desktop `flutter analyze --no-pub --fatal-infos` | 全部通过 |

存储基础上轮全套为216通过、19条件跳过（`build/macos-adaptation/m03-storage-test.log`）；本轮追加回执一致性、撤销事实保留和并发等校验后，重跑上表9项定向存储测试。未重复累计测试数量，也不将旧全套结果当作末次全部源码的全套重跑。原全套包含Mac AOT 80MiB恢复中断及同目标重试，合成进程证据不等于交付App验收。备份测试因同时打开两个独立库触发Drift多实例提示，使用不同数据库及executor，不共享连接。

### 下一步：实际决策与运行中的授权

本阶段没有启用审批按钮。必须继续完成以下接缝，才能宣称真实审批可用：

1. 在 OwnerAccess 接入带版本与原操作身份的异步批准、拒绝、撤销；不能先调用现有同步批准、再补存回执，否则会提前发布读取能力。
2. 提交前后均核对会话、期限和资料版本；关闭、结束或取消可随时使能力失效。处理等待存储期间的旧入口并发、审计队列顺序和正常退出等待，不能由迟到的提交重新激活已结束请求。
3. 写入结果不确定时保守处理并查询原操作，查询只证明历史事实，不自动重放或恢复授权；历史终态与实际可用性一致。
4. 适配新审批页及授权历史；与 #71 的独立客户端联调部分批准、拒绝、撤销、到期、结束及未知结果，之后交给 #73 做同候选真实宿主验证。

#70/#71 的分项实现与测试继续复用；当前预览仍不能据此视为真实业务App，整票验收项保持未勾选。

## 2026-10-30：实际决策、会话竞态与新审批页接入

上述存储基础现已接入 `OwnerAccess.decideInformationRequest` 和 `informationApprovalReceipt`。普通资料的批准、拒绝、撤销按钮已使用真实来源；不创建主人申请入口，不改变预览数据源，也不声称附件/凭据审批已完成。

### 实际行为

- Owner 命令绑定原操作编号、请求、审阅摘要和完整 UI 意图摘要。批准限定到原请求中的普通字段及所见资料版本，固定期限；新字段不会进入已有授权，已批准字段的正常纠正沿用稳定身份。
- 提交期间不发布拟议读取凭证，并阻止旧同步 Owner 入口竞争处理该请求。撤销提交期间旧凭证也暂不可读。事务完成后再次检查会话、期限、资料版本；只有仍有效的确定提交才发布能力。
- 取消、到期、结束和关闭即时改变运行状态，相关审计在决策事务结算后写入最终事实。正常成功直接使用事务中的记录，不重复写一份审批历史。关闭等待在途决策及最终审计；未解决的存储结果不假装关闭成功，重试可以完成清理。
- 写入可能成功而响应丢失时，按原操作查询。查询失败期间保持不可读取和不可再次决策；查到已提交的批准只确认事实并结束能力，不补发凭证或重放。确认未提交则保留当前状态，由主人重新决定；库恢复清除旧运行关联及待核对状态。
- `OwnerWorkspaceApprovals` 校验旧页面的审阅摘要、字段选择及期限，映射真实回执；冲突要求重审，未知结果保留核对入口。刷新签名包含决策正在保存/待核对状态，不仅比较待批数量。
- 普通附件范围如实显示尚未接入，含附件的申请不能误用普通字段批准，但主人仍可拒绝或撤销已有授权。凭据请求继续走独立来源，未接入范围不伪造成功。

### 验证与边界

- core 10个相关测试文件 **67项通过**，包括19项新增决策测试；覆盖提交前/后分别取消、到期、结束、关闭，资料提交后变化，持有旧凭证时撤销，未知提交核对、关闭失败后重试、重开不恢复会话，及既有凭据/传输/备份协调回归。结果日志为 `build/macos-adaptation/m03-decision-core.log`；使用测试门闩精确控制提交位置，不以固定等待猜竞态。
- SQLCipher `approval_operations_test.dart` **10项通过**。新增真实 Owner 命令落盘、部分字段读取、越界拒绝、撤销和重开查询；存储静态检查通过。
- desktop 六个相关文件共 **42项通过**（新增控件/真实来源、审批控制器、正式来源与启动器、desktop_runtime）；核心及桌面静态检查通过，`git diff --check` 通过。桌面日志为 `build/macos-adaptation/m03-decision-desktop.log`。
- 桌面使用真实 HTTP AgentServer + SQLCipher + ApprovalsController 验证 AI 申请、部分批准、期限、读取/拒绝及撤销；旧审阅冲突和拒绝回执跨重开不重放通过。
- 新增两项实际 `ApprovalsPage` 控件测试，点击批准、拒绝和撤销并核对核心读取结果；使用真实 OwnerAccess + MemoryInformationRepository，不使用 SampleWorkspaceSource。它们是 Flutter widget 证据，不是物理鼠标、系统密码或真实 AI 宿主聊天验收。
- 首次桌面组合回归发现旧测试仍预期审批回执为 unsupported；在真实查询实现接通后改为确认不存在的操作返回 null，其他未接入功能仍保留 unsupported 断言，完整重跑通过。未掩盖存储查询失败为 null。

本轮未运行 Windows CI、未使用 computer use/个人资料/Keychain、未构建或替换 App。完整授权历史/访问记录页面、更多独立 CLI/故障联调、Mac 构建与 #73 同候选真实宿主验证仍待完成。#72 保持 OPEN，完整验收项不勾选。


## 2026-10-30：真实授权历史、访问记录与批准版本

`OwnerWorkspaceGrantHistory` 已作为正式来源接入新界面。普通申请、获批范围、实际访问次数及结果来自现有 Owner 审计；凭据流程（包括附带普通字段读取的凭据申请）继续排除在本来源之外。查询支持关键词、日期、状态、分页与原选择定位，日期使用服务时钟；不检索或输出被访问正文。新访问发生时即使申请数量/状态不变也会刷新。

- 授权是否有效逐字段使用核心当前读取决定；部分字段失效显示“部分有效”，撤销、到期、结束、重启和恢复的历史事实不会恢复能力。批准状态事件与访问记录分别显示，“已批准”不计入访问次数。
- 历史页撤销复用真实审批命令及审阅摘要。显式打开或选择不存在的历史时保留该目标并报错，刷新不会默默选中另一条可撤销授权。
- 新异步普通审批在同一事务的 GrantHistory 中保存批准时 `itemVersions`，撤销/结束/恢复保留它。快照只按原信息身份和准确版本从当前资料、保留修订或完整回收快照读取；版本未知、内容清理或不匹配时明确不可用，不按名称或当前值替代。列表和访问事件不包含正文，历史正文必须由主人显式打开。
- 本机数据库继续使用36/37，无新增表列；授权 JSON 的可选版本元数据随现有事务落盘，旧记录没有该键时保持未知，不补造版本。新元数据的备份使用内容触发的格式13，包含布局所需列；无该元数据的资料继续按既有内容选择格式。格式13校验版本映射精确覆盖原获批信息项、正整数及上限，并计入元数据容量预算；格式12不能携带该新键。恢复只保留事实，不携带原操作回执或活跃能力。
- 普通附件历史领取/预览仍后置，缺少批准附件版本的按钮禁用且说明版本不可用；缺少普通资料版本时不再显示误导性的 v0。

### 本轮证据

| 范围 | 验证 | 结果 |
| --- | --- | --- |
| core | grant_history_version / information_approval_access / information_approval_operations / history / session_end / backup_coordinator / workspace / credential_use | 63项通过；含不可变版本依据、旧记录、错误版本拒绝及凭据混合读取不进入普通历史 |
| storage | `dart test --reporter expanded` 全套 | 223项通过、19项条件跳过；新增真实审批版本在修改/撤销/重开/格式13恢复后保留、旧格式继续使用、错误映射和降报格式拒绝 |
| desktop | owner_workspace_grant_history / owner_workspace_grant_history_widget / grant_history_controller / workspace_grant_history / owner_workspace_approvals / owner_workspace_source / owner_workspace_host / desktop_runtime | 54项通过；含SQLCipher真实来源、分页/过滤、失效、准确快照、保留期、库代次隔离、缺失精确目标和实际历史撤销按钮 |
| 静态检查 | core/storage `dart analyze`；desktop `flutter analyze --no-pub --fatal-infos` | 全部通过 |

日志：`build/macos-adaptation/m03-history-core.log`、`m03-history-storage.log`、`m03-history-desktop.log`。存储全套在新增 Owner 只读历史投影之前执行；之后核心63项和桌面54项覆盖最终投影及存储接缝，存储源码未再更改。源库/目标库为独立测试密钥及连接，Drift多实例提示不代表共用执行器。控件验证使用真实 Owner + 内存仓库，资料来源验证使用 SQLCipher；均不是实际鼠标/系统输入或真实 AI 宿主验收。库代次测试单独使用恢复协调器 fixture，真实备份往返由存储测试覆盖，不拼成同候选实机证据。

本轮没有使用个人资料/Keychain、computer use或 Windows CI；没有新建或替换 App。#72 仍 OPEN，下一步为独立 CLI/故障联调、Mac 构建，再交 #73 固定候选真实宿主及交付验收。


## 2026-10-30：独立编译 CLI 与正式 Owner 来源联合验证

新增 `scripts/qa/check-owner-cli.py` 和 `apps/desktop/tool/check_owner_cli.dart`。脚本顺序编译正式 `info`、`info-codex`、`info-codex-hook`，启动独立进程经真实 HTTP 服务访问 SQLCipher 合成库；主人侧使用正式 WorkspaceSource、ApprovalsController 和 GrantHistoryController。支持 `--tools` 指向交付包中的同名 CLI，以便整包之后复用同一检查。

通过14个具名检查：新界面保存、公开目录无正文、待批拒读、操作编号去重/冲突、主人提交响应丢失只查询、不扩大部分批准及跨聊天拒绝、同身份修正与固定期限、历史页撤销阻止缓存凭证、拒绝与到期、AI申请响应丢失后查原操作、合成SessionEnd使一次性客户端失效、应用停止关闭端点、独立Owner进程重开保持资料/历史/回执、重开不恢复旧能力。两阶段Owner进程PID不同；CLI也是独立编译进程。系统平台为NativeDesktopFixture，期限使用可控服务时钟；hook仅接收测试标准输入，未注册、信任或调用真实AI宿主。此前核心竞态测试与本次故障联调证据分别保留，不声称真实宿主验收已完成。

命令：`python3 scripts/qa/check-owner-cli.py --report build/macos-adaptation/m03-cli-interop-2.json`。结果与二进制/探针摘要见该JSON，运行日志为同名 `.log`。首轮探针按整数传入表单端口被正确拒绝，修正为界面合同的文本值后两阶段通过；未修改业务校验来迁就测试。测试目录、固定测试密钥、合成关联文件及临时编译程序均已清理。桌面静态检查通过。

下一步构建固定源码Mac Release包，并用包内CLI重跑；用户预览仍未替换，#72/#73仍OPEN。
