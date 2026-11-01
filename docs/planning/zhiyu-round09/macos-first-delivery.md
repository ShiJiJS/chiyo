# Mac 首批可用版本：执行路线图

更新：2026-11-01。总票 [#69](https://github.com/ShiJiJS/agent-info-manage/issues/69)。当前按 tickets 推进实现；已安装 App 与准备好的候选仍分别保留。

## 首批要交付什么

主人在 Mac 保存普通资料，退出重开后资料仍在；真实 AI 发现公开目录并发起访问请求，主人在 App 中批准部分字段或拒绝，AI 只能读取获批内容。主人能查看记录、撤销授权；到期、会话结束和应用重开不能复活旧授权。

**申请只由 AI 发起；主人负责审批和管理。不增加演示入口、演示模式或自动批准。** Mac ARM64 优先，Windows 适配后置。

## 已拆分 tickets 与交付顺序

沿用现有子票，避免重复建单。每票的详细规格、故障处理与验收标准继续有效；下表是执行入口，不替代原标准。

| 顺序 | Ticket | 工作范围 | 交接与完成结果 |
| --- | --- | --- | --- |
| 1 | [#70 M01：真实保存与重启恢复](https://github.com/ShiJiJS/agent-info-manage/issues/70) | 普通文字、服务器/应用资料、文档正文、档案叶字段；目录、标签、关联、修订与回收 | 真实加密库保存和编辑，独立重开不丢失，旧数据与备份兼容；冲突/失败不显示成功 |
| 2 | [#71 M02：AI 发现、申请与收件箱](https://github.com/ShiJiJS/agent-info-manage/issues/71) | 公开目录、正式 CLI 接入、真实申请、收件箱刷新、状态查询和连接诊断 | AI 与 App 对应同一请求；重试不重复，未批准读不到正文；宿主信任未知时如实显示 |
| 3 | [#72 M03：审批、限定读取与失效](https://github.com/ShiJiJS/agent-info-manage/issues/72) | 部分批准、拒绝、撤销、固定期限、会话结束、授权历史与访问记录 | AI 只读批准字段，跨聊天及越界拒绝；撤销/到期/结束后拒读，重启/恢复不复活；记录可追溯 |
| 4 | [#73 M04：完整流程与 App 交付](https://github.com/ShiJiJS/agent-info-manage/issues/73) | 同候选 App/CLI 联合检查、实际 AI 聊天、固定安装目录、升级保护、说明与清理 | 交付可打开的 Mac App、接入步骤和支持清单；安装升级与尚未完成的系统项明确记录 |
| 后续 | [#74 M05：新版备份与恢复](https://github.com/ShiJiJS/agent-info-manage/issues/74) | 新版设置接恢复密钥、原生文件选择、真实加密导出、空库恢复及原操作核对 | 独立恢复成功且不复活授权；取消/错误/重复操作不覆盖原数据，恢复后旧界面操作失效 |

GitHub 已有依赖 **#70 → #71 → #72 → #73**，五张票均属于 #69，均保持 OPEN；实现票带 `enhancement`、`ready-for-agent`。完成顺序不要求重复开发已有能力，能独立推进的后续工作可复用现有接缝。

#74 是后续增强，可以在等待 #73 的本人操作期间推进；**不成为当前候选交付的新前置**。首批新增数据的迁移和可恢复性仍属于 #70–#73，不能因完整备份界面后置而省略。

## 当前进度与实际剩余工作

当前产品候选是 `1443d358`。保存、AI 请求、审批、历史和限定读取已经有真实存储/服务实现及自动化联合证据；实际 AI 聊天与新版原生测试控件也已有联合记录。并非全部从头开发，也不能据此称为已安装可日用版本。

1. **#70–#72：核对证据与原验收项的差额。** 复用已有测试和实现，只修补真实缺口；准确区分测试入口、正常 Release 入口、真实 AI 聊天与物理系统操作。
2. **#73：完成固定安装交付。** 旧程序归档及候选载荷核对已完成，固定旧安装尚未替换。先保护最新资料并验证可恢复，再正常退出、整体换包、普通启动和必要系统允许；最终核对保存/重开、接入、审批和失效，提供一份实际可用说明。
3. **#74：真实来源已接正式组合，继续最终交付验证。** 持久操作、文件发布失败核对、Owner备份来源、恢复重绑及新版控件联合检查已有实现和证据；三个独立测试进程验证了结果恢复。M05完整Release候选f1bd29ea已打包，旧版混合资料经新版入口四进程往返通过。外部文件访问恢复及明确重选接缝已实现并通过定向检查，仍需同源码完整构建、正式沙箱原生面板及外部位置重开；不能把测试进程等同于已安装 App 可日用。原#73待换包候选尚未擅自替换。

最新实施及证据：[M01](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m01.md)、[M02](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m02.md)、[M03](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m03.md)、[M04](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m04.md)、[M05](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m05.md)。这些记录保留具体来源与验证边界；未验事项不勾选、整票不提前关闭。

## 后置范围与原票归属

| 范围 | 安排 |
| --- | --- |
| 普通附件与托管凭据 | 首批普通资料闭环后，从 #69 单列新版真实适配任务；复用既有底层，不把普通读取批准当作文件交付或凭据执行批准 |
| AI 录入/修改提案、整理 | 后续按 #67 界面合同接真实能力；请求仍由 AI 发起 |
| 插件与其他设置 | 后续按 #65/#68 及领域决策细化；备份部分已单列 #74 |
| Mac 生命周期、通知、完整界面及安装 | 沿用 #46/#47/#48/#50，#73 回填同候选证据；系统通知不是首批接收请求的唯一通道 |
| Windows、跨平台迁移、其他机器与公证分发 | 保留原票范围，放在本机 Mac 首批可用之后，不运行 Windows CI |

需要本人操作的步骤由 #73 集中说明用途，优先完成自动化准备。系统密码由本人输入；中文输入、通知点击及睡眠唤醒分别按实际验收记录，不反复换候选制造授权提示，不承诺更换签名后永不提示。

## 执行约束与历史

保持 `codex/zhiyu-macos` 独立分支，不改 main/Windows。只用隔离合成资料做自动验证，不扩大个人 hooks、信任或资料访问范围。交付后保留一个当前安装，清理本轮可重建的多余 App/dSYM；不动个人资料、旧版回退保护或来源不明文件。

[历史规划与阶段记录](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/planning/zhiyu-round09/macos-real-function-plan.md)保留供追溯，其中旧检查点的“下一步”不再作为当前排期。各子票原规格与未验项保持，本路线图不降低验收要求。
