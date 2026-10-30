# 知予 Mac M02：真实申请接入实施记录

关联 [#71](https://github.com/ShiJiJS/agent-info-manage/issues/71)，规格见 [M02](../planning/zhiyu-round09/issues/M02.md)。Mac 分支 `codex/zhiyu-macos`。本票进行中，不以本记录替代完整验收。

## 2026-10-30：目录发现、原申请查询与普通资料收件箱

在 #70 正式来源及启动接缝上继续开发。复用现有服务、OwnerAccess、SQLCipher 和 CLI，不新增演示入口、不改变个人 hooks/信任。本轮没有替换用户预览、构建新原生 App、使用 computer use 或运行 Windows CI。

### 实现

- 公开目录新增 `typeId`、全部当前标签 ID/名称及信息项标签归属；关键词可搜索标签名称，支持类型筛选。正文、目录树、关系图和布局快照不返回。无布局旧资料归 `generic`。修正内部 `catalog()` 误用分页默认20项导致附件协议检查遗漏后续信息项的问题；外部目录仍分页。
- 普通请求可携带 `operationId`。同一私密会话内，同编号同意图返回原请求，字段顺序/重复字段不改变集合意图；换用途/字段为 `operation_conflict`，不同编号仍是新申请。不延长期限、不重复通知、不复活已拒绝/到期请求。省略编号的旧接口保持原行为。
- 增加只查询的 `/request/status` / CLI `request-status`。CLI 先核对 `information-request-operations.v1`，旧服务不能静默忽略编号；提交通信失败为 `request_unknown`，不自动重发。操作映射仅随服务中的请求保留，不持久化会话秘密；服务关闭/恢复及会话结束后旧证明失效。`not_found` 不证明在途提交不会稍后到达。
- `OwnerWorkspaceApprovals` 接入正式来源。普通信息请求的列表、计数、过滤、分页、保留选择及详情来自实际服务和无正文审计；核心活跃状态覆盖历史事实。界面会话标识采用原审计的公开绑定，不用会话秘密。详情只投影名称、身份、版本、请求范围和时间。
- 重开加密库后显示关闭前的历史结果，不恢复待批或授权。旧库来源在关闭或替换后拒绝继续查询。刷新比较请求状态及授权范围/期限，覆盖待批数量不变时的撤销等变化。
- 本阶段只读审批事实；批准/拒绝/撤销和操作回执仍未接通，界面禁用这些操作并解释未接入，不返回示例成功。普通资料收件箱不声称已覆盖后置的凭据/整理业务。
- 更新 [CLI 说明](../cli.md) 的发现、操作编号、失败与恢复语义。

### 本机验证

所有数据为隔离合成资料，数据库使用测试密钥；临时库和 CLI 测试材料由测试收尾清理。

| 范围 | 命令（相应包目录执行） | 结果 |
| --- | --- | --- |
| core | `../../scripts/dev-macos.sh dart test test/catalog_test.dart test/transport_test.dart test/request_operation_test.dart test/session_end_transport_test.dart test/pending_test.dart test/history_test.dart test/workspace_test.dart` | 23通过 |
| CLI | `../../scripts/dev-macos.sh dart test test/catalog_cli_test.dart test/cli_test.dart test/request_operation_client_test.dart test/credential_reuse_runtime_test.dart test/credential_reuse_json_lines_test.dart` | 18通过、3条件跳过；包含 Mac 本机 worker 定向回归，不运行 Windows CI |
| desktop | `../../scripts/dev-macos.sh flutter test --no-pub test/owner_workspace_approvals_test.dart test/owner_workspace_source_test.dart test/approvals_controller_test.dart` | 16通过 |
| 静态检查 | core/CLI `dart analyze --fatal-infos`；desktop `flutter analyze --no-pub` | 全部通过 |

独立 CLI 进程查询公开目录、提交/重复提交/按原操作查询；假服务验证旧能力拒绝和已收到提交但丢响应时不重放。实际 HTTP 请求经真实 SQLCipher 服务进入正式收件箱适配器与控制器，核对 ID/字段/公开会话绑定/截止时间及未审批拒读。加密库关闭重开后查询历史、旧证明拒绝；撤销在待批数为零时也触发刷新。真实界面保存回归继续通过。

首次组合测试在原有内存界面 fixture 收尾挂起；诊断发现真实异步区与 widget 模拟时钟混用，关闭时没有排空另一时钟的回调。将内存 fixture 保持在 widget 区，并在异步关闭后排空两种调度；中止的运行不记为通过，最后完整重跑16项通过。生产退出流程未改动。首次静态检查发现缺少条件语句花括号，补齐后通过。

这些是源码、HTTP/独立 CLI、真实存储和控制器/界面回归的分项证据，不是同一固定原生候选上的真实 AI 聊天审批闭环；没有物理输入/通知/睡眠验收，也未生成新 App/dSYM。

### 剩余

1. Agent 设置的真实安装/连接/宿主信任状态及失败诊断；原生请求定位到指定收件箱记录。
2. 补齐请求来源声明及其展示，不能把聊天标签或文件存在推断成宿主身份/信任。
3. 与 #72 的实际审批、持久操作回执、授权历史、限定读取及失效联调；当前只读来源不能代替完成审批。
4. 当前版本 App/CLI 打包和 #73 同一候选真实宿主联合验收。#70/#71/#72/#73 均保留未验项，不提前关闭。

## 2026-10-30：指定请求定位及旧资料详情兼容

原生 `open` 事件此前只导航至新审批页，丢失了请求编号。增加可选的 `WorkspaceRequestNavigation`，从已有 DesktopRuntime 传递不透明请求 ID 到正式 WorkspaceApp 和审批控制器；不传能力、不创建或批准请求。启动前收到的请求只定位一次；无编号菜单仍打开普通收件箱。

原生窗口激活是异步的：现在先捕获通知编号，并以导航意图序号忽略晚完成的旧导航，避免覆盖更新的设置/搜索目的地。编辑锁切换同时使在途导航失效，既不会在锁定时跳页，也不把被阻止的通知留到解锁后执行。退出期间完成的激活不再导航。

指定请求在当前资料库不存在时，控制器显示明确 `not_found`，保留该目标直至用户选择其他申请或重置筛选；自动刷新不能悄悄改选另一条申请。列表仍可供主人主动选择，所有处理按钮在目标未确认时不可用。

正式启动器联调暴露旧资料详情崩溃：无新版布局时，编解码器生成分组使用了 `fields`，而详情合同读取 `keys`。已修正为合同所需键名，原字段身份和值保持；用实际旧格式资料验证详情正文显示及其访问申请定位，不通过换成新版样例绕开问题。

验证：`flutter test --no-pub test/owner_workspace_host_test.dart test/approvals_controller_test.dart test/desktop_runtime_test.dart test/workspace_information_codec_test.dart` 40项通过，`flutter analyze --no-pub` 通过。原生平台为 fixture；正式启动器、实际 owner 服务及新 WorkspaceApp/ApprovalsPage 参与测试。覆盖安装前通知挂起、激活竞争、编辑锁、原请求选择、缺失目标、旧资料显示、恢复换源及正常关闭。它不代表 macOS 通知中心的物理点击已重新验证。

首次启动器测试遇到跨真实/模拟时钟的审计收尾挂起，沿用上一检查点的排空原则，让恢复/退出先启动、再驱动两种调度并有界核对完成；中止的运行不计成功。随后真实旧资料触发上述详情异常，修复后完整40项通过。小型日志保留在 `build/macos-adaptation/m02-routing-test.log`，没有新 App/dSYM、个人资料/Keychain、CUA 或 Windows CI。

下一步仍为 Agent 接入诊断和 #72 审批写入：必须区分交付 CLI、Skill 安装、宿主 hook 定义与正式信任。当前聊天需要可核对的会话选择依据，不能把最后一条申请的会话冒充当前聊天，也不能从个人关联文件或公开聊天 ID 恢复能力。#71 保持 OPEN。

## 真实服务会话观察与明确选择（2026-10-30）

正式 `OwnerWorkspaceSource` 现在使用 `OwnerWorkspaceAgents`，替换 Agent 页的不可用来源。核心新增仅供主人端的公开会话快照，包含未提交申请的会话；不返回私密会话证明或仅撤销凭据，也未新增 Agent 端接口。列表合并当前关联与保留的普通资料申请历史，已结束/服务重开的历史不恢复活跃授权；统计范围明确仅含普通资料申请。

主人明确选择会话后才能查看该会话的关联申请；同名会话以公开标识区分，不从最新请求推断正在使用的聊天。选择丢失不会切到别的会话。刷新签名包含空会话创建/结束；诊断和会话详情重新读取真实事实，状态变化或较新读取使旧观察失效。收件箱与会话页复用同一请求状态映射。

本轮只接服务端可观察事实。CLI 载荷/网络连通、个人 Skill 安装和宿主正式信任仍显示“无法核对”，顶部为“接入状态待核对”，不是已连接，也不把未观察到 hook 当作未安装。未扫描个人配置、关联文件或聊天记录，未执行 hook、修改信任或创建申请。

验证：

- desktop 六文件共 **34 项通过**：`owner_workspace_agents_test.dart`（4项真实 SQLCipher/控制器检查）、`owner_workspace_agents_widget_test.dart`（1项实际选择器与详情交互，MemoryInformationRepository）、`workspace_agents_test.dart`、`zhiyu_agents_test.dart`、`owner_workspace_approvals_test.dart`、`owner_workspace_source_test.dart`。
- core `workspace_test.dart` + `session_end_transport_test.dart` **4 项通过**；desktop/core 静态检查通过，`git diff --check` 通过。
- 新检查覆盖无请求同名会话、公开标识不能鉴权、未选择/缺失目标不猜测、选定会话保持、批准/到期/结束使旧观察失效、加密库重开只保留历史、空会话变化通知。
- Widget 曾在清理阶段因跨模拟/真实时钟的异步关闭停留，诊断运行被中断，不计通过。最终拆分持久化与界面测试，按同一 widget 时钟分别发起来源/服务关闭并推进两个时钟，完整重跑通过；不以测试修复宣称实机验收。

未生成 App/dSYM、未替换用户预览；没有个人资料/Keychain、computer use 或 Windows CI。#71 仍 OPEN：配套工具的实际核对、宿主接入说明/可观察边界、请求来源说明完善及 #72 联调继续推进；#73 的真实宿主与同一候选交付尚未完成。
