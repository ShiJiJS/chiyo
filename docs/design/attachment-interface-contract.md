# 普通附件字段与服务接口合同 · #36

2026-10-18。冻结后续#37/#38的目标合同，尚未成为可用接口。字段与授权含义来自[客户端规划](windows-attachment-client-plan.md)和ADR0011；公共CLI使用现有逐行JSON和私密会话关联。#33实现共同协议v2协商，#37增加`information-attachments.v1`能力，#30更新随包CLI/Skill。协议v1与旧证明不静默升级。

## 1. 字段载荷与兼容

业务模型使用判别联合：`structured/textNote`对应文本内容，`file`对应附件版本引用。不能以路径、Base64或空String伪装文件。现有文本构造入口可保持源码兼容，但文件只能经专门文件构造入口建立；所有消费者按kind显式分支，文件调用旧文本value接口必须明确报错，不能返回空串。具体内部类布局可调整，不改变以下可持久化含义。

```json
{"id":"resume","name":"简历","description":"求职用简历原文件","version":3,"kind":"file","content":{"attachmentId":"opaque-attachment","attachmentVersion":2}}
```

`version`是字段版本，`attachmentVersion`是原字节版本，均为正整数。元数据修正可只增长字段版本；换文件增长两者，同用途保留字段ID；换kind或业务含义建立新字段身份。附件版本的原字节不可变，不用修改元数据来悄悄替换内容。旧字段载荷迁移为文本分支，字节不变；未知kind、内容与kind不匹配、悬空附件引用均失败，不降级或丢弃。

SQLCipher独立保存附件版本BLOB及私有摘要：`attachmentId, attachmentVersion, originalName, mediaType, byteLength, sha256`。标题、公开说明与原文件名是不同字段。媒体类型只用于展示，扩展名和MIME不证明内容安全，不在本轮自动执行文件或解析正文。

普通目录投影仅保留`itemId, fieldId, name, description, kind`及原有公开版本元数据；不含content、originalName、mediaType、byteLength、sha256、源路径、暂存ID和交付路径。未知旧客户端若无法表达当前文件字段，应返回明确`unsupported_capability`，不能忽略该字段后允许旧编辑完整覆盖信息项。

## 2. 所有者导入与编辑边界

这些接口只存在于OwnerAccess/桌面服务，不暴露为Agent命令：

| 操作 | 输入/返回 | 原子性与失败 |
| --- | --- | --- |
| stageInformationFile | 系统文件选择器返回的本机普通文件；返回`stageId`及私有摘要 | 有界读取/校验容量后存入加密暂存；用户取消不创建stage，不删除源文件；文件变化/无权限/超限明确错误 |
| commitInformationDraft | 信息项基础版本、操作ID、名称/目录/标签及完整字段草稿；文件分支引用未变附件或当前Owner草稿的stageId | 一次事务提交信息项、字段、附件关系及历史版本；乐观版本冲突/写入失败不部分提交。重复同操作ID返回原提交，不产生第二版本；同ID异内容冲突 |
| releaseInformationStage | 本Owner草稿的stageId | 取消/关闭编辑后回收未提交内容；保存失败保留stage供同草稿重试，不能让另一个草稿或Agent消费；重启清理孤立暂存 |
| exportInformationFile | 当前或明确选择的保留附件版本、系统另存目标 | 主人明确另存原字节，写入完整后才发布目标；失败不截断原文件/已有目标，输出副本不承诺随授权回收 |

未变文件草稿只携带附件版本引用，不重新上传、不拷贝BLOB进全库快照。stage占用计入容量预算，取消和故障不能留下永久不可见占用。stageId和附件ID都不构成Agent读取能力。并发保存后过时草稿明确冲突，不能以“保留附件”覆盖另一份新文件。

Owner另存按固定版本完整读取，校验长度和SHA-256，源事务成功结束后才以同卷不覆盖方式发布。已有目标或发布竞争返回`output_exists`，读取/写入/发布失败返回`file_export_failed`，正文不符返回`attachment_integrity_failed`；不在错误中附带源路径。该输出由用户明确持有，不进入Agent受管副本清理。

普通附件在脱离当前内容后至少保留30天；仍有修订/回收快照引用时继续保留。当前文件不按年龄清理，恢复旧文件为当前内容会重置退役状态，正文一旦清理则不因系统时钟回拨恢复。入库检查预算前、Owner另存前及桌面启动/周期维护均核对到期内容；清理失败保留正文并显示可重试状态。可恢复快照与其正文不能出现一边已提交清理、另一边仍可恢复的状态。

模板持久化字段定义`name,description,kind`，不含value、content、stageId、附件ID或文件路径；套用文件字段为空，保存前必须选择文件。普通文本/元数据提案及整理只修改其明确范围，保留未变附件引用；Agent新增/替换文件字节在本轮返回`unsupported_file_write`，删除提案仍能按既有稳定字段身份表达，不把不支持写入吞掉后显示成功。

## 3. 申请、读取与交付

发现与申请沿用`catalog`、`request(fields)`、`status/wait`、`claim`，不增加第二种普通文件授权弹窗。附件和文本混合申请可部分批准，普通读取默认8小时；私密会话证明沿用AgentClient内部关联，不作为JSON字段或stdout返回。凭据默认15分钟的使用许可不适用于普通附件。

协商v2并具备`information-attachments.v1`后提供以下命令。opaque标识/JSON大小/重复key/未知属性/UTC等沿用运行协议约束；请求只含非秘密引用，真实会话能力由CLI带入私有通道。

```json
{"protocolVersion":2,"command":"file-fetch","requestId":"request-id","itemId":"career","fieldId":"resume","operationId":"delivery-op-1"}
{"protocolVersion":2,"command":"file-status","deliveryId":"delivery-id"}
{"protocolVersion":2,"command":"file-status","operationId":"delivery-op-1"}
{"protocolVersion":2,"command":"file-release","deliveryId":"delivery-id"}
```

`file-fetch`检查当前会话、有效授权、固定字段成员、信息项/字段存续及文件类型；获取提交时当前版本并持久化交付操作后生成受管副本。响应为`{protocolVersion:2,status:"ok",delivery:{deliveryId,itemId,fieldId,fieldVersion,attachmentVersion,fileName,mediaType,byteLength,path,state:"ready",expiresAt}}`，其中path只在此获批交付中返回。本机路径允许Agent交给同机文档或浏览器上传工具；不把本机路径当远程浏览器文件。

同一会话内operationId唯一；相同输入重复调用只返回原操作，在有效授权下保留同一文件版本/副本，不因当前内容变化再产生一份；不同输入返回`operation_conflict`。释放、撤销、到期或重启后不重新创建副本，不通过重复ID恢复读取。新领取使用新operationId，按当前字段版本处理。准备中失败或未知先查询原操作，不自动重放；先保存审计失败则不交付。

`file-status`只返回所属会话的非内容事实：版本、状态、截止及可公开错误；不返回path、正文或摘要哈希。状态为`preparing|ready|released|expired|cleanup_pending|failed|unknown`。`file-release`幂等停止该副本使用并请求清理，重复释放返回当前事实；不伪造文件占用情况下的删除成功。目录/read接口不返回二进制、Base64或交付路径：对文件调用普通`read`返回`file_delivery_required`，提示使用file-fetch。

领取响应丢失时可能尚无deliveryId，因此file-status另接受原operationId，二者必须且只能提供一个；file-release仍使用deliveryId。按operationId查询不排在原文件IO之后，不创建操作/副本，只报告已登记事实。查询到ready也不构成新读取许可，领取路径仍须通过原授权与完整核验；失效清理尚未保存时可能暂报之前的状态及原截止时间。没有所属会话记录时返回delivery_not_found，其他会话不能据此判断记录是否存在。not_found也不证明排队中的原请求将来不会登记，不能自动换ID或重放领取。

CLI文件命令默认v2，显式v1拒绝；先核对服务的协议和information-attachments.v1能力。HTTP为/information-file/fetch、status、release，严格JSON及16KiB请求上限；Agent提交的命令不能带任意目标路径、租约或私密会话证明。私密会话由受信客户端内部带入传输。文件调用等待上限30秒；领取/释放的连接中断、截断响应或超时统一报告delivery_unknown、operationClaimed=true及原非秘密查询ID，禁止自动重试。查询运输失败仅报告service_unavailable。正式bootstrap仍须在原生文件驱动、存储及#38主人界面连接后显式启用能力；旧客户端目录/申请不静默忽略文件。

副本使用应用生成的唯一安全子目录和安全basename；不把原文件名作为路径片段或接受Agent指定任意写入目标。主人另存与Agent受管交付分开。撤销、到期、会话结束和重启阻止新领取，并按登记记录回收副本；打开句柄导致清理失败时记录cleanup_pending并安全重试。此机制不回收已被复制/上传的数据，不提供同用户强沙箱。交付历史和备份均不含path或执行能力。

错误投影至少包含`not_authorized, grant_expired, session_ended, field_removed, not_a_file, unsupported_capability, unsupported_file_write, file_delivery_required, operation_conflict, stage_unavailable, version_conflict, attachment_too_large, attachment_capacity_exceeded, attachment_missing, attachment_integrity_failed, delivery_io_failed, audit_failed`；客户端保留当前位置和可重试草稿，不把错误当空文件或成功。权限失败不泄露未获批文件的名称/大小。

2026-10-19最新传输检查点：[HTTP/独立CLI与实际中断](../development/issue37-delivery-cli.md)已通过，30秒超时按原操作查询、不自动重放。最终容量/RSS及全写入口预算、正式bootstrap及#38仍待，不宣告能力。此前存储检查点如下。

2026-10-19最新实施检查点：[加密交付登记/归档](../development/issue37-delivery-storage.md)已接schema21/备份9；实际SQLCipher与Windows占用重开、归档白名单和末段回滚已验证。HTTP/独立CLI及生产bootstrap仍待，能力继续关闭；旧检查点如下。

2026-10-19实施检查点：[交付核心及Windows文件驱动](../development/issue37-delivery-core.md)已按上述顺序接入，Memory/合成适配器覆盖公开核心Interface，另有真实Windows保护/并发读取/占用清理检查。SQLCipher交付登记/备份归档、实际HTTP/CLI和生产bootstrap尚未连接，不宣告能力。受管副本暂定32份/100MiB，preparing及cleanup_pending均计入占位；本轮份数上限已测，最终组合字节/峰值内存仍待实测冻结。

## 4. 存储、恢复及消费者清单

2026-10-19实施状态：schema20已接Owner完整草稿保存、不可变附件版本/字段关系和修订/回收/幂等回执的同一事务。含正式附件或文件模板时，完整备份入口使用[格式8](attachment-backup-v8.md)，验证当前/修订/回收引用后原子安装；纯文本库继续输出7，兼容旧1–7。恢复确认会重新验证选中文件与预览一致，并通过同一已验证句柄读取；更换来源时拒绝，不恢复另一份内容。[Owner另存及版本清理](../development/issue37-owner-file-lifecycle.md)已接通，Agent文件交付及#38客户端尚待，不宣告文件能力或关闭#37。下段1–6是本合同冻结时的旧基线，不能据此丢弃格式7。

BLOB按需加载，使用加密库事务；元数据页不能把正文带进InformationRepository.items全量恢复路径。历史/回收30天保留关系与相应BLOB不可分离。若新备份容器需分块认证，先冻结格式/认证边界，再实现；绝不以逐块可解密作为整个备份完整恢复的证明。完整容器验证后方可原子发布恢复库；兼容1–6格式，旧读取器拒绝新格式。格式6包含#33全部操作的冻结计划和归档，不能仅兼容5而丢弃这些事实。数据库后续升级须同时维护独立library_format标记和物理表映射，不能只改PRAGMA user_version；依据[实际v2兼容合同](runtime-protocol-v2.md)。

| 消费者 | #37/#38必须改动的边界 |
| --- | --- |
| `information.dart`、`library_access.dart` | 类型化文件字段及Owner草稿事务；列表/详情元数据与正文读取分离 |
| `templates.dart`、模板编辑 | 文件定义，无实际附件引用 |
| `update_proposals.dart`、`proposal_access.dart`、`update_access.dart`、整理 | 未变引用保留、支持删除、明确拒绝文件字节提案；不走旧字符串全量重建 |
| `protocol_json.dart`、`agent_server.dart`、CLI `agent_client.dart` | kind能力协商、文件命令、严格JSON与非泄漏错误投影 |
| `history.dart`、`history_access.dart` | 批准成员/版本提示与实际交付版本分别记录；无正文/路径 |
| `revisions.dart`、`recycle_access.dart`、存储清理 | 保留引用及BLOB一致，恢复不复活授权，当前值/保留值不串版本 |
| `info_storage.dart`、`backups.dart`和分块备份 | 迁移/BLOB事务/加密暂存、容量和完整备份；原字节往返 |
| 桌面`information_editor.dart`、`information_workspace.dart`、`library.dart` | 字段类型控件、独立stage生命周期、原型三栏及真实IO；异步保存禁止重入 |
| 桌面提案、审批、历史、设置 | 文件摘要、部分批准、真实访问记录、版本/容量/恢复预览；未知kind拒绝保存 |

本合同的完成证据是原型、协议/消费者清单及设计测试。加密、系统文件选择器、实际CLI交付、故障恢复、字节一致与Flutter行为必须由#37/#38另取生产证据；不由HTML模拟状态背书。
