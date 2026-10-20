# 软件设计复核与开发计划

> 当前执行入口（2026-10-18）：[Windows后续计划](../windows-next-iteration.md)已统一三项新增调整和六张主工单。当前程序0.4.0+8仍是v1一次启动，新增功能未实现；#28/#29/#31的Windows基线已交付，通知、真实Codex、干净环境仍待验收。下文旧阶段状态/自动继续同步安排仅作历史，不作为当前指令；无子Agent、服务器同步暂停，Mac及双向恢复延期。

审计日期：2026-10-16；发布及后续核验：2026-10-17（北京时间）。round05视觉方向已获认可，方案和GitHub任务已发布。后续用户已明确授权自主实施；D0已完成，D1实施中。完整执行范围和最新进度见[Windows与同步执行记录](../windows-and-sync-execution.md)。

总入口：[升级父任务 #21](https://github.com/ShiJiJS/agent-info-manage/issues/21)。10张子任务有原生父子关系和阻塞依赖；[#22](https://github.com/ShiJiJS/agent-info-manage/issues/22)已按设计证据完成，当前前沿为[#23](https://github.com/ShiJiJS/agent-info-manage/issues/23)。

- [开发计划与任务映射](development-plan.md)：阶段、逐票验收和依赖。
- [运行时实施契约](../../design/runtime-implementation-contract.md)：三类许可、部分批准、占位符、一次启动、生命周期和备份。
- [后续执行说明](execution-runbook.md)：已授权工作怎样连续推进，何时算完成。
- [实施衔接复核](planning-followup-2026-10-17.md)：当前票正文、协议链接、共享接口及格式分工的读回记录。
- [审计发现](design-review.md)：14项缺口及原检查证据，未因发布票务而消失。
- [已发布票务调整](tracker-adjustments.md)：旧票、PR20与依赖变化。
- [已确认HTML基线](../../design/prototypes/round-05/README.md)：可独立本地预览；D0补齐流程与协议的[验收记录](../../development/round05-22-design.md)单独保留。

本轮更新旧#1–#19正文，保留开放状态与既有评论；创建#21及#22–#31；PR20保持草稿，去除全量自动关闭关联。#18/#19移除#17的前置阻塞，单平台往返与#17跨平台完整验收分别保留。新任务ready-for-agent表示规格可执行，不代表依赖或验收已经完成。

原发布快照保留为github-snapshot.json、pr-20-snapshot.json、dependencies.json；published/是最初发布正文的历史记录，不覆盖为最新正文。原读回核验在publication-verification.json，编号在published-issues.json。原审计时独立UI评审受额度限制未完成，原记录保留；后续D0独立评审与原生隔离测试另记执行证据，不能从这些历史快照推断当前完成状态。
