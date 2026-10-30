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
