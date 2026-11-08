# #100 阶段证据：共享原回收与历史规则

2026-11-09。#100 尚未完成。当前先把现有 Owner 回收与历史规则移入纯 Dart info_workspace，App 保留原构造入口和本机渲染；尚未接新 Owner HTTP 接口、严格传输 DTO 和 RemoteWorkspaceSource，不把抽取完成说成联网入口完成。

- OwnerWorkspaceHistory 共用原资料版本列表、历史预览、恢复、回收查询、逐项生命周期及持久回执。以已存在的 WorkspaceClassificationInformation 提供摘要，以同一个 OwnerAccess 处理原事务，未复制简化恢复逻辑。
- OwnerWorkspaceLibraryRecycle 共用原整批目录/内容预览、恢复冲突、一次提交和回执；App 薄 re-export。
- OwnerWorkspaceGrantHistory 及凭据/整理历史共用原条目、状态、快照、事件和执行元数据。准确历史文件范围先在共享模块解析；PDF/图片等文件渲染仍由原 App 的 OwnerWorkspaceAttachmentPreview 注入，整个原作用域检查覆盖解析和渲染。不把原生 PDF 能力迁到 Linux，也不在服务器打开本机文件。

实际检查：

| 检查 | 结果 | local/server-first-stage日志 |
|---|---|---|
| 原 App 的资料历史、批次回收、授权/凭据/文件历史和正常控件回归 | 30项通过 | a10-shared-history-native-regression.log |
| 无 Flutter 的真实 SQLCipher 共享装配：正常用户批准/实际字段读取、历史事件、版本恢复、资料与凭据整批回收、加密重开后原回执去重、整体恢复、凭据停用及旧许可拒绝、再重开保持 | Mac1个连续场景通过 | a10-shared-history-pure-tests-approved.log |
| 相同纯Dart场景，独立Linux ARM64 Docker | 1个场景通过 | a10-linux-shared-history.log |
| 共享模块、App薄封装及新服务测试分析 | 无问题 | a10-shared-history-analyze-fixed.log / a10-shared-history-native-analyze.log / a10-shared-history-server-analyze.log |

初次抽取的 Dart 参数语法错误和测试误用不存在的 owner.decide 未算通过；已修正后才取以上结果。测试仅合成资料，没有日常 App、个人钥匙串或真实资料变更。测试进程及容器正常退出。

接续必须完成：受认证的历史/回收/版本及批次接口和严格 DTO、RemoteWorkspaceSource/grantHistory 正常入口、历史原附件的设备端显示、原操作查询在断线/重开下准确去重、不同客户端核对、正常控件到服务完整流程。需要覆盖普通资料/文件/凭据、批次冲突/失败不部分恢复、历史及旧许可不复活。#101–#102未完成，#103–#105未动。
