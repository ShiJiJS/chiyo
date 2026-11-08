# #97 阶段证据：上传、预览、提案和版本保存

2026-11-08。仅用隔离合成资料、真实 HTTPS/SQLCipher；没有访问个人钥匙串、原资料或日常 App。

本票**未完成**。当前实现 App/CLI 上传、用户原文读取、文件提案新增/修改、App 预览/替换/恢复版本、旧模板多附件表单，以及上传取消和遗留暂存清理。App 另存/本机打开与独立本机操作记录现已接通；Agent 获批下载和受管副本、文件授权重启恢复尚未接通，不以这份记录声称交付完成。

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

新增与相关共享 Dart、服务和 App 文件静态分析通过。上方早期原 App 另存/打开回归仅证明原实现没有回归；下方新增实际远程原文和正常联网 App 场景才证明 RemoteWorkspaceSource 已连接这些入口。已有备份测试会同时打开不同库并输出 Drift 多实例提示；服务套件的错误密钥场景输出 SQLCipher 解密拒绝信息，测试最终成功；未关闭这些保护或修改密钥验证。

Linux 使用 `chiyo-server-verification:a05` 验收基础镜像、当前源码只读挂载，以及此前按官方固定 SHA256 核验的 SQLCipher 下载缓存；仍由原依赖 hook 校验。镜像不是最终候选，最终统一构建在 #102 完成。

## 下一步

接 Agent 获批下载、受管副本及清理，再验证 App 退出和服务重启后的有效文件许可。不得返回服务器路径冒充客户端文件，也不得用本地资料库或假路径绕过原交付结果核对。原生面板集中留 #103；第一阶段功能缺项仍属于 #97。


## 本机另存和打开已连接（后续阶段）

原 InformationFileOutputs / InformationFileOpens 改依赖最小私有操作日志接口，旧资料库仍使用原加密私有日志。联网客户端使用独立 DeviceFileOperations：仅保存本机输出路径、原生访问证明、操作结果及清理责任；库表没有资料、文件原文、凭据或授权，不是本机资料副本。日志使用 SQLCipher 和独立本机密钥文件，目录700、文件600，与服务器密钥、接入Token分开；更换Token不要求重新加密操作记录。按服务器身份隔离，错误身份、丢失密钥、宽权限密钥及链接路径拒绝，不能自动重置成空记录。开发与默认联网接入均不调用个人钥匙串。

另存和打开主体流程继续复用原协调器、原路径身份/字节验证、no-replace 发布、未确认操作及清理规则。OwnerFileActionContext保留旧单机快照屏障，远程实现读取实际服务器原文并在本机写入前再次核对字段和版本；不伪造OwnerAccess、资料库或服务器路径。本机操作串行，App完全退出前清理打开副本；中断或清理失败的记录留待重开处理。用户选择另存的文件不纳入副本清理。

RemoteWorkspaceSource接同一文件菜单、另存、打开、结果查询、重新选择原输出核对，以及副本结束使用和重试清理。关闭使用同一个完成Future，界面与外层同时收尾不会重复关闭资源。

新增实际证据：

| 检查 | 结果 | 日志 |
|---|---|---|
| DeviceFileOperations实际加密、锁、身份/密钥保护，原发布/打开流程重开核对 | Mac 2项通过 | device-file-operation-tests.log |
| 原另存/打开完整回归加真实HTTPS远程文件动作 | 21项通过 | remote-file-actions-tests.log |
| 加强远程动作：面板打开时服务器文件变更，拒绝旧内容发布 | 1项通过 | remote-file-actions-final-tests.log |
| 正常联网App连续流程，新增菜单另存、打开、结束副本并核对原字节 | 1项通过 | online-file-actions-ui-tests.log |
| Linux ARM64：两个服务文件场景加独立日志加密/锁/身份保护 | 3项通过 | linux-device-file-operations-tests.log |

远程场景实际核对：另存原字节、重开原成功操作不再弹选择器或覆写用户后来修改的文件、已有同名文件不覆盖、旧版本/错操作编号拒绝、打开回复丢失可核对、核对失败保持未知并阻止第二次操作、成功核对不重复打开、结束使用及退出清理副本且保留用户另存文件。原始与替换版本仍保持。Linux不运行Mac原生文件发布/打开测试；这里不声称Linux或Windows桌面交付通过。

最初设备日志原生发布测试使用临时目录别名，被原路径身份检查拒绝；改为读取规范路径后通过，没有放宽路径检查。界面首次收尾仍有HTTP计时器待结束，随后直接等待在Flutter测试时钟内创建的关闭Future导致测试驱动停住；定点停止该测试进程后，改为持续推进测试时钟并观察真实关闭完成，再通过全部流程。没有去掉退出检查、关闭计时器断言或缩短超时。中止测试遗留的确切合成目录已检查文件名并清理；没有清理其他测试或真实目录。

相关 Dart/Flutter 分析通过。系统文件面板用合成选择器、系统打开响应以校验实际副本的调度器代替；字节读取、原生文件生成/发布/验证/回收及加密日志都是真实实现，系统面板和真正外部程序仍由#103集中实测。#97仍保持打开，不能把本机用户动作当作Agent下载授权已经接通。
