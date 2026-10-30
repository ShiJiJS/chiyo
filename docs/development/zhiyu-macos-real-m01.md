# M01：真实资料接入进度

对应 [#70](https://github.com/ShiJiJS/agent-info-manage/issues/70)，Mac 分支 `codex/zhiyu-macos`。本记录是实施中的检查点，不是 #70 完成声明。

## 2026-10-30：组合入口与持久保存回执

代码提交 `9894f060`。

- 将 `WorkspaceApp` 从 `PreviewWorkspace` 分离。正式入口可以提供自己的 `WorkspaceSource` 和桌面桥；共享界面不构造示例来源、不打开数据库。预览根继续持有原示例来源，现有预览 App 未替换。
- 同一来源的普通重建保持控制器；更换来源/桌面桥时销毁旧页面投影和订阅。旧页面销毁不能清除新页面注册的菜单回调；来源与桌面服务的销毁仍由组合根负责。
- `OwnerAccess.saveInformationRecord` 复用现有完整表单事务、字段身份、版本检查、修订与回收规则，提供跨表单/重开可查询的操作结果。新文件仍走原暂存表单，当前入口只处理文字与未变的附件引用。
- `information_record_operations` 与资料在同一 SQLCipher 事务内写入，仅保留操作编号、输入摘要、信息项身份、前后版本；没有正文快照。原临时表单回执继续按原生命周期清理。重复操作不会再次创建或修改资料，改变输入复用操作编号会拒绝。
- 普通库格式 22 升级至 24；带可移植焦点填充数据的格式 23 升级至 25。保留普通/可移植格式边界，实际存储可移植数据时 24 转 25。旧读者不能读新的数据库格式。操作回执不进入备份，备份内容格式本次未改变。
- 恢复事务将接收库中的旧回执标为失效，查询/重放返回 `library_changed`；失败恢复回滚该变化。资料删除及保留期清理后，重放原保存仅返回原操作元数据，不重新创建资料。

### 已运行检查

使用项目 `scripts/dev-macos.sh` 的固定 SDK；测试只使用临时合成库，没有访问个人库、系统钥匙串或真实焦点填充。

| 范围 | 命令（在对应 package 目录运行） | 结果 |
| --- | --- | --- |
| core 静态检查 | `dart analyze --fatal-infos` | 通过 |
| storage 静态检查 | `dart analyze --fatal-infos` | 通过 |
| desktop 静态检查 | `flutter analyze --no-pub --fatal-infos` | 通过 |
| 持久回执与格式边界 | `dart test test/information_record_operations_test.dart test/focused_fill_storage_test.dart` | 28 通过，2 跳过 |
| 既有存储/备份/附件 | `dart test test/storage_test.dart test/backup_test.dart test/backup_interruption_test.dart test/information_attachments_storage_test.dart test/information_time_test.dart` | 24 通过，2 跳过 |
| 既有核心事务/生命周期 | `dart test test/information_draft_test.dart test/information_attachment_lifecycle_test.dart test/backup_coordinator_test.dart` | 25 通过 |
| 共享界面/原预览 | `flutter test --no-pub test/workspace_app_test.dart test/owner_preview_test.dart test/mac_preview_isolation_test.dart test/mac_preview_desktop_test.dart test/zhiyu_preview_test.dart test/zhiyu_runtime_test.dart` | 26 通过 |

格式边界的两个跳过项依赖外部旧版读者程序，本轮未提供。存储测试的两个跳过项为该文件内平台限定项；不据此声称 Windows 通过。Drift 对多个数据库实例发出调试警告；相关备份测试实际使用不同目录、独立句柄。无 Windows CI，无原生界面操作，无重新构建/打包。

### 尚未完成，下一步

1. **正式资料映射**：持久保存类型/定义快照、槽位到真实字段的映射、经历叶身份和资料关联；新字段同时补迁移、修订/回收及备份兼容。不能把复合经历序列当成一个可授权字段。
2. **WorkspaceSource 正式适配**：真实分类、列表/详情、编辑/新建、修订和回收；错误及未知结果使用上述持久查询。未接入模块明确不可用，不能套用示例来源伪装成功。
3. **正式启动与恢复**：将新界面接入现有 bootstrap/runtime，保留正式技术身份、数据库位置和正常退出流程；表单尚未提交的意图也必须绑定资料库身份，不能仅依赖已提交回执。
4. **完整 #70 证明**：独立进程重启、实际业务适配、迁移/备份和 Mac 构建。当前仅证明核心保存回执与组合边界，不等于新界面已可保存真实资料。

#71–#73 仍按依赖顺序待实施，未勾选四张票的任何完整验收项。目标仍是可实际使用的 Mac App，不以本检查点替代最终交付。

## 2026-10-30：资料结构进入同一持久模型

代码提交 `43e6eb15`。这一检查点接续上文，尚未完成新界面正式适配，不替换用户现有预览 App。

- `InformationItem.layout` 保存不可变的 owner 布局快照、类型、槽位到真实字段身份的映射，以及带 information/credential 种类的关联引用。正文仍在独立 `InformationField`，公开目录不返回布局、关系和字段值；布局不是访问范围或授权证明。
- `InformationDraftLayout` 把 UI 槽位与提交的字段顺序对应，最终由原核心事务分配真实身份并原子保存。前端生成的条目/槽位 ID 不直接作为授权字段 ID。输入摘要包含布局变化，旧的持久操作回执仍只含无正文元数据。
- 值纠正、分类、目录说明修改、提案更新、凭据字段迁移均保留原布局；替换和回收恢复重映射发生变化的字段身份。修订与回收快照同时保存布局。已另作他用或已移动的槽位不被历史恢复覆盖；未映射的实际字段保留，后续适配器必须将其投影为保留字段，不能静默丢弃。
- 普通库升级为 **26**，可移植焦点填充库为 **27**。支持普通旧版本及旧可移植 23/25 的升级，后者不能降为普通格式。当前字段和任何修订/回收快照含布局时采用 **备份格式 12**；无布局仍按既有内容选择格式 7–11。布局信息进入原 SQLCipher 与备份容量检查；恢复没有可移植填充记录的格式 12 不强行改变其格式类别。
- `snapshot` 是有大小、深度和 JSON 类型边界的 owner 描述容器；UI 定义/条目顺序的具体编码与未知类型保留仍属于下一步适配器，不因该容器存在就声称所有模板业务接入完成。插件包执行/安装未实现，ADR0016 状态不变。

### 检查证据

- storage 全套 `dart test`：**182 通过、19 跳过**。跳过来自 Windows 平台或外部旧版探针条件，不是运行失败。首次执行的 5 个失败均为当前格式号仍预期 22 的断言，更新准确预期后全套通过。最终日志：`build/macos-adaptation/m01-layout-checkpoint/storage-tests-final.log`。
- 上述全套包括新的 7 项真实 SQLCipher 布局测试：重开、公开目录隔离/逐字段读取、编辑/分类保留、部分/整项恢复、格式 12 当前及历史布局往返、事务失败回滚、旧 24/25 迁移。末次修正移动槽位的恢复去重后又定向运行这 7 项通过，日志 `layout-tests-final.log`。
- Mac AOT 子进程的既有格式 8/9、80 MiB 恢复中断测试通过：强制终止发生在测试子进程，SQLCipher 完整性和回滚通过，同一目标重试成功。不是对用户 App 强杀；不使用个人钥匙串。格式 12 中断专项尚未运行。
- core：`dart analyze --fatal-infos` 通过；`information_layout_test`、`information_draft_test`、`recycle_test`、`revisions_test`、`library_test`、`update_proposals_test` 共 **37 通过**。移动槽位的恢复去重修正后，布局模型 3 项再次通过。
- desktop：`flutter analyze --no-pub --fatal-infos` 通过；`workspace_app_test`、`desktop_bootstrap_test` 共 **9 通过**。没有新 UI 行为、真实 OS 输入或打包完成声明。
- storage 静态检查通过。中间与最终日志合计约 264 KiB；未复制 App/dSYM，测试临时子进程产物由测试清理。

### 当前下一步

1. 实现真实 `WorkspaceDetail`/`WorkspaceCreate`/`WorkspaceEdit` 编解码：冻结定义和实例覆盖、独立经历叶、正文格式、关联及未知旧字段；字段标签以当前真实描述为准，不能因旧模板标签误导用户。
2. 将编解码接入 `WorkspaceSource` 的真实 OwnerAccess 读写、分类、修订/回收和操作核对，并接入正式 bootstrap/runtime。未知结果先查询回执；未提交意图绑定库身份。
3. 完成 #70 独立进程与新界面整体接缝、实际 Mac 构建，再进入 #71/#72。#73 仍负责同候选真实 AI 闭环及交付；所有完整验收项保持未勾选。
