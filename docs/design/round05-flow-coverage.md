# round05 流程覆盖与开发映射

2026-10-17，Issue #22（D0）。沿用已确认的顶部导航、收件箱、三栏、文档卡片和四主题。HTML设计修改内存中的虚构资料，刷新重置；不能证明Flutter、CLI、加密库或Windows安装已经通过。入口为[原型](prototypes/round-05/index.html)，以下状态加在 `?state=` 后。

| 复核项 | 原型入口/状态与验收 | 已有实现依据 | 生产票 |
| --- | --- | --- | --- |
| F01 补选与期限 | 普通申请→调整范围，`scope`；取消申请字段并补选其他信息，原申请遗漏/补选分开计数；默认480分钟，可改15/30/60；切换请求保留草稿 | core/test/adjusted_approval_test.dart、desktop/lib/approvals.dart | #23 |
| F02 整理结束 | `page=proposals&state=organized`→本次授权；AUTH-022昨天14:25→14:28完成；`organization-noop/conflict/revoked`分别无改动完成/整批未应用/撤销，不显示虚构变化 | ADR0007、core/lib/organization_task_access.dart及对应测试 | #23、#25、#26 |
| F03 四维状态 | `execution-start_failed/prepare_failed/running/revoked_running/nonzero/unknown/token`；列表和首屏显示未启动、额度已消耗、重新申请；Token无需文件清理；清理失败只重试清理 | 新凭据执行未实现；已有history只含普通许可与访问事实 | #28–#30 |
| F04 组合许可 | `use-file`取消凭据复选保留字段→仅批准字段；双批产生两个ID及分别截止时间，启动不消费字段许可；零范围不可批准 | 复用普通claim/read，新增使用许可 | #28、#30 |
| F05 规格一致 | 73b7080已对齐旧排除项和既有实现；ADR0008保留无强隔离；本轮精确接口见[协议](runtime-protocol-v1.md)，未更改领域决策 | 本地规格、ADR0001/2/7/8 | #22，父Agent同步tracker |
| F06 信息生命周期 | `editor/edit/trash/revision/taxonomy/save-failed`；完整名称/公开说明/目录/标签/字段编辑；回收恢复，指定历史版本恢复，失败保留草稿，删除当前对象后改选 | desktop/lib/library.dart、recycle.dart、revisions.dart及storage测试 | #24 |
| F07 提案核对 | `proposal-edit`完整编辑；P-011调整修改内容；确认后只显示回执→按结果ID打开当前内容，已删除则显示不存在，不从旧副本读取字段 | desktop/lib/import_proposals.dart、update_proposals.dart | #25 |
| F08 凭据生命周期 | 凭据详情→更换版本/停用/启用/删除/恢复；`credential-rotate`；旧秘密保留30天不可用，轮换失效旧待用许可，恢复新版本停用 | 新能力 | #27、#31 |
| F09 可发现目录 | `credential-discovery`；默认不允许发现，只公开ID/名称/用途/形式/版本/状态，不披露原文、源路径、备注；关联不自动公开；申请明细typed reference及receiver | 托管目录新能力 | #27、#28 |
| F10 备份闭环 | `backup-enable`创建→另存密钥→导出；`restore`先选文件/密钥校验再预览确认；`restore-preview/wrong-key/damaged/interrupted/old-format`及`backup-export-failed`；含凭据非空库禁止覆盖 | desktop/lib/backups.dart、core/lib/backup_access.dart、storage/lib/backups.dart | #26、#31 |
| F11 大数据空态 | `empty/no-results/large-data`（1012条、每页50行）；请求/提案/历史8行分页和独立滚动；无匹配不保留旧详情。HTML内存分页不替代服务有界查询 | 原CRUD已有，新UI查询待接入 | #23–#26 |
| F12 错误恢复 | 顶部本机连接→服务状态；`service-offline/key-unavailable/save-failed`；重连、通知权限、原库保护、保存失败输入保留、恢复失败当前库不变 | desktop_bootstrap/runtime/settings，核心事务 | #23、#26、#30 |
| F13 秘密迁移 | 信息详情→转换旧字段，`migration`显示旧授权/历史/离线备份影响；普通模板去掉访问令牌，普通字段明确可被授权读取，关联凭据独立 | 模板/普通字段已有，转换事务新增 | #24、#31 |
| F14 非交互执行 | SSH固定 `-T -o BatchMode=yes … /usr/bin/true`；Token/file_env保留；[协议](runtime-protocol-v1.md)冻结stdin、输出分页、失败和断线 | 现行CLI单行请求/响应 | #29、#30 |

上表路径省略前缀：core=`packages/info_core`，storage=`packages/info_storage`，desktop=`apps/desktop`。

## 数据与身份映射

“公开说明”映射现有InformationItem.description/ImportItemDraft.description，进入公开目录；本轮不新增私有备注字段。原型publicDescription是旧视图兼容字段，保存映射为description，不能误把内部说明公开。唯一组织结构是稳定目录ID和标签；path是显示，原型旧category仅用于派生图标/显示，不新增并列分类实体。生产选择directoryId/tagIds。

普通值修正及仍存在字段的版本恢复保留身份；曾删除/替换后恢复的语义字段取得新身份，旧许可不复活。回收恢复保留信息身份但不恢复授权。凭据恢复建立新版本并停用。提案终态只留事实和目标身份；目标不存在不能读取旧副本。

## 状态与重试

| 对象 | 状态/转换 | 恢复规则 |
| --- | --- | --- |
| 请求 | pending→approved/partially_approved/denied/cancelled/expired | 超时查原申请，终态不再批准，不自动重提 |
| 普通许可 | active→expired/revoked/session_ended/restart_invalidated | 固定成员读当前值；启动失败不消费字段许可 |
| 整理许可 | approved→completed（含无改动）或conflicted/revoked/expired | 完成结束能力；冲突整批不应用，不二次确认 |
| 使用许可 | available→consumed或revoked/expired/version_invalidated | 原子占用之前可核查重试；占用后准备/启动失败也消耗 |
| 执行 | preparing→running→exited（exitCode区分），或prepare_failed/start_failed/unknown | 未知先核查，不重放；撤销不杀已运行进程 |
| 清理 | not_needed或pending→complete/failed/needs_check | 仅重试登记且身份吻合材料清理，不执行命令 |
| 凭据 | active/disabled/expired/trash，旧版本退休30天 | 旧版不可用，恢复新版本停用，默认不允许发现 |

四项默认方案由用户授权自主规划并固定在[实施契约](runtime-implementation-contract.md)：非交互SSH、一次一凭据、两个独立许可可部分批准、退休/删除秘密30天。协议v1补精确schema/错误码/输出/私有边界，后续票按此实现。

目标1440×900；长表单独立滚动，动作底栏分离，Esc还原焦点。新增面板淡入/5px进入和按钮反馈，遵循reduced-motion。异常通过URL直达，不在产品UI显示制作验收控件。见[D0证据](../development/round05-22-design.md)；生产/Windows由后续票验证，macOS实际验收按用户指示延期。
