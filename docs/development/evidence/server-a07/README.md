# #97 阶段证据：上传、预览、提案和版本保存

2026-11-08。仅用隔离合成资料、真实 HTTPS/SQLCipher；没有访问个人钥匙串、原资料或日常 App。

本票**未完成**。当前实现 App/CLI 上传、用户原文读取、文件提案新增/修改、App 预览/替换/恢复版本、旧模板多附件表单，以及上传取消和遗留暂存清理。App 另存/本机打开、Agent 获批下载和受管副本、文件授权重启恢复尚未接通，不以这份记录声称交付完成。

## 可复验场景

- `apps/server/test/owner_files_test.dart`：实际 HTTPS 上传10MiB；原操作去重及内容不符拒绝；普通文件保存、替换、保留旧版、恢复成新版、查询原回执及加密库重开。旧模板多附件和文字整体保存，版本错误或复用同一选择拒绝且不部分入库；消费暂存后仍返回原保存回执，重开后分别核对原文。
- `apps/server/test/remote_file_proposals_test.dart`：正式 AgentClient.remote 依据当前生产文件模板提交两版原文，原操作重试；普通 DTO 没有原文，用户读取指定原文并整份确认；重开后修改附件，预览旧/新原文并形成第三版。无效模板填写返回字段错误；结束根聊天后拒绝新操作。暂未开放 Agent 下载能力。
- `apps/server/test/owner_file_staging_test.dart`：加密暂存过期回收而不影响另一张表单，批量关闭及取消尚未观察到结果的上传，长期运行不累积旧取消记录。SQL 删除故障保留清理责任，恢复存储后同一清理成功，不遗留无法重试的暂存；计时由可注入单调计时源推进，没有长时间等待。
- `apps/desktop/test/online_files_widget_test.dart`：正常 OnlineDesktopLauncher、LibraryPage、文件菜单和提案界面，实际 HTTPS/SQLCipher；导入 Markdown、预览、替换、恢复、App 重开及真实 CLI 文件提案原文预览和整份保存。文件选择器只替代系统面板，读取和保存实际合成文件；不是原生面板验收。
- `apps/desktop/test/remote_file_recovery_test.dart`：实际 TLS 代理先让服务器保存上传/入库再断开回复。保留原上传及保存编号；查询失败不表示没保存，重试不会重复暂存、资料或版本，不会重新选择另一个源文件代替未知结果。还核对 RemoteWorkspaceSource 的旧模板多附件保存、原文及回执，以及关闭时一次清理已选与结果未知的上传。

## 已运行与日志

日志在忽略目录 `local/server-first-stage`，下面是实际运行结果，不是正式发布包：

| 检查 | 结果 | 日志 |
|---|---|---|
| Mac 服务完整包（最初文件传输/提案版本） | 20 项通过 | server-file-intake-suite.log |
| Linux ARM64 服务完整包，含多附件与暂存清理 | 21 项通过 | linux-file-forms-suite.log |
| Mac 多附件和 SQL 清理故障复验 | 2 项通过 | owner-file-forms-cleanup-tests.log |
| Linux ARM64 对最终清理可重试改动专项复验 | 2 项通过 | linux-file-cleanup-retry-tests.log |
| 正常 App 文件/提案，加原文件预览/另存/打开/旧模板回归 | 37 项通过 | file-intake-combined-regression.log |
| 原文字/多附件表单回归 | 19 项通过 | shared-file-forms-regression.log |
| 清理可重试改动后的原文件保存与真实丢回复回归 | 12 项通过 | file-cleanup-retry-regression.log |
| 新增实际丢回复专项 | 1 项通过 | remote-file-recovery-tests.log |

新增与相关共享 Dart、服务和 App 文件静态分析通过。原 App 另存/打开回归通过只证明原本机实现没有回归，**不证明 RemoteWorkspaceSource 已连接这些入口**。已有备份测试会同时打开不同库并输出 Drift 多实例提示；服务套件的错误密钥场景输出 SQLCipher 解密拒绝信息，测试最终成功；未关闭这些保护或修改密钥验证。

Linux 使用 `chiyo-server-verification:a05` 验收基础镜像、当前源码只读挂载，以及此前按官方固定 SHA256 核验的 SQLCipher 下载缓存；仍由原依赖 hook 校验。镜像不是最终候选，最终统一构建在 #102 完成。

## 下一步

接 App 另存/本机打开及本机持久操作记录；接 Agent 获批下载、受管副本及清理，再验证 App 退出和服务重启后的有效文件许可。不得返回服务器路径冒充客户端文件，也不得用本地资料库或假路径绕过原交付结果核对。原生面板集中留 #103；第一阶段功能缺项仍属于 #97。
