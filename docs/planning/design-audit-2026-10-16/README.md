# 软件设计复核与开发计划

审计日期：2026-10-16；发布核验跨至2026-10-17（北京时间）。round05视觉方向已获认可；按用户要求更新方案并发布GitHub任务，生产开发尚未开始。

总入口：[升级父任务 #21](https://github.com/ShiJiJS/agent-info-manage/issues/21)。10张子任务有原生父子关系和阻塞依赖，第一可执行任务为[#22](https://github.com/ShiJiJS/agent-info-manage/issues/22)。

- [开发计划与任务映射](development-plan.md)：阶段、逐票验收和依赖。
- [运行时实施契约](../../design/runtime-implementation-contract.md)：三类许可、部分批准、占位符、一次启动、生命周期和备份。
- [后续执行说明](execution-runbook.md)：用户授权开发后怎样连续推进，何时算完成。
- [审计发现](design-review.md)：14项缺口及原检查证据，未因发布票务而消失。
- [已发布票务调整](tracker-adjustments.md)：旧票、PR20与依赖变化。
- [已确认HTML基线](../../design/prototypes/round-05/README.md)：可独立本地预览；D0仍需补齐流程。

本轮更新旧#1–#19正文，保留开放状态与既有评论；创建#21及#22–#31；PR20保持草稿，去除全量自动关闭关联。#18/#19移除#17的前置阻塞，单平台往返与#17跨平台完整验收分别保留。新任务ready-for-agent表示规格可执行，不代表依赖或验收已经完成。

发布前快照保留为github-snapshot.json、pr-20-snapshot.json、dependencies.json；发布正文在published/，读回核验在publication-verification.json，实际编号在published-issues.json。独立UI评审曾受额度限制未完成，原审计没有伪报这一项；本轮仅核验文档、票务与复制资产，不新增安全/原生平台测试结论。
