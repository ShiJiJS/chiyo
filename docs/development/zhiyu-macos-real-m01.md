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
