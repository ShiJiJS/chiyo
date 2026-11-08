# #102：联网资料切换模板

2026-11-09。本阶段补齐初查缺少的原资料模板转换入口，**#102 仍未完成**。只用隔离合成资料，不改日常安装或个人资料。

## 实现

原 `OwnerWorkspaceAdoption` 的字段对应、保留内容、附件及经历身份、关联规则、预算检查、计划预览和应用逻辑移到纯 Dart 的 `info_workspace`。原 App 路径只 re-export；原 `OwnerWorkspaceInformation` 和服务器 `OnlineOwnerLibrary` 通过同一个只读投影接口供它使用。原写入及错误映射也一并复用，保存继续走原 `OwnerAccess.saveInformationRecord` 和持久回执，不另写一套转换规则。

用户管理接口新增 `/v1/owner/adoption`：POST `previews` 产生原预览，DELETE `previews/<id>` 关闭预览，POST `changes` 按原 operationId 和 planId 应用。服务重开后不恢复未保存预览；已经保存的准确旧操作可从原资料回执查询或幂等返回。库恢复时释放旧投影与预览。受限 Agent 设备身份不能访问这些管理接口。

`RemoteWorkspaceSource` 的三个正式模板转换方法已接上述接口；继续使用信息库「采用资料模板」原对话框。共享传输层保留完整资料、目标模板定义、预览结果、字段对应、关联和错误；拒绝未知字段、错误布尔值及额外文件路径等格式。

同时修正两个接入细节：远程资料回执原来只区分新增/编辑，现在保留原 adoptionPlanId、legacyTemplate 身份并正确标为模板切换；提交后失去回复或无法解码结果时，返回待核对而不是普通连接失败，避免原 `RecordMutation` 丢掉操作并允许重复写入。明确的预览过期、版本冲突等拒绝保留原含义。

## 实际检查

| 检查 | 结果与范围 |
|---|---|
| 正常联网 UI | `OnlineDesktopLauncher → 信息库 → 资料菜单 → 采用资料模板 → 选择正常安装插件 → 字段对应及同含义确认 → 预览 → 应用`。实际 HTTPS/SQLCipher，原资料在预览前后不变，应用后原字段身份、内容和格式正确。没有 computer use 或系统授权。 |
| 联网资料与附件 | 原正文和关联保留；附件不能映射为文本，修正后作为原字段保留，实际读取同一版本原文。取消预览、资料后来修改导致旧预览冲突、重开返回准确原回执均检查。 |
| 丢回复与重开 | 真实代理丢失保存回复并使原查询失败；原正常 `RecordMutation` 冻结该操作，重开整套服务后只查询回执，仍为原模板切换身份。POST 只有一次，版本与历史也只增加一次。 |
| App 相关回归 | **31 项通过**，`a12-adoption-final-regression.log`：新 5 项（含真实 UI、联网/附件/丢回复/传输）及原模板转换、生产插件和已有 UI 合同 26 项。 |
| Mac 服务相关组 | **6 项通过**，`a12-adoption-server-first.log`：新 Owner HTTPS 检查及原历史、恢复和动态模板组。Agent 设备身份不能预览或应用；旧回执重开准确，额外字段拒绝。 |
| Linux ARM64 相同组 | **6 项通过，无平台跳过**，`a12-adoption-linux.log`。真实 SQLCipher 与当前共享代码，服务没有 Flutter 依赖。 |
| 静态检查 | 相关 App、服务器及新共享模块分析无问题；git diff 空白检查通过。日志 `a12-adoption-analyze-final.log`、`a12-adoption-server-analyze.log`。 |

第一轮测试把中文资料名称拼进了内部操作编号，违反原编号格式；已改用正常 `workspaceOperationId()`，用户资料名称仍为中文。早期失败不计通过，没有为测试放宽产品校验。分析发现的未使用 import 和格式提示已修正。

## 接下来

设置、应用运行/原生桌面和 Agent 接入观察仍需要接通。随后构建同一源码的正式候选、连续试用全部功能，再做无上下文独立 Agent 试用。当前模块通过不等于 #102 整票完成，更不等于真实安装或跨电脑交付；#103–#105 不动。
