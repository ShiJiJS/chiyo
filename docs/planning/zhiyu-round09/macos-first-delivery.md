# Mac 首批可用版本：执行路线图

更新：2026-11-01。总票 [#69](https://github.com/ShiJiJS/agent-info-manage/issues/69)。当前按 tickets 推进实现；固定安装已换入0a5e3500，等待本轮一次系统钥匙串允许。

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
| 后续 | [#75 M06：普通附件管理](https://github.com/ShiJiJS/agent-info-manage/issues/75) | 原文验证读取、真实版本/预览、导入/替换/恢复版本/另存 | 先接Owner读取，再接原生选择与持久操作；实际面板另验 |
| 后续 | [#76 M07：AI文件申请与交付](https://github.com/ShiJiJS/agent-info-manage/issues/76) | 新版文件审批、准确版本、受管副本和交付历史 | AI申请，主人审批；复用现有协议，核对失效和清理 |
| 后续 | [#77 M08：托管凭据真实管理](https://github.com/ShiJiJS/agent-info-manage/issues/77) | 真实元数据/版本、安全录入、更换、启停及生命周期 | 先接已有凭据读取，再接持久原操作；AI使用审批后续单列，不增加主人申请入口 |

GitHub 已有依赖 **#70 → #71 → #72 → #73**，八张实现票 #70–#77 均属于 #69，均保持 OPEN；实现票带 `enhancement`、`ready-for-agent`。完成顺序不要求重复开发已有能力，能独立推进的后续工作可复用现有接缝。

#74 是后续增强，可以在等待 #73 的本人操作期间推进；**不成为当前候选交付的新前置**。首批新增数据的迁移和可恢复性仍属于 #70–#73，不能因完整备份界面后置而省略。

## 当前进度与实际剩余工作

当前完整候选是 `0a5e3500`，已换入固定目录。保存、AI 请求、审批、历史和限定读取已有真实存储/服务实现及联合证据；文件流程也已通过两根真实AI聊天、当前包外部CLI及新版原生控件联合检查。当前正常Release入口正在等待一次Keychain系统决定，尚未证明打开原资料及正常独立重开，不能称升级完成或已可日用。

1. **#70–#72：核对证据与原验收项的差额。** 复用已有测试和实现，只修补真实缺口；准确区分测试入口、正常 Release 入口、真实 AI 聊天与物理系统操作。
2. **#73：完成固定安装交付。** 旧版已导出当前完整加密备份，已有恢复文件匹配，独立空库恢复/重开通过；程序归档已重验复用，关闭的原资料已另存保护。正常退出后整体换包已完成，当前只需本人处理已发起的一次系统密码提示。允许后继续普通开库、原资料、保存/重开与接入核对，提供实际可用说明；临时旧程序在核对成功后清理。
3. **#74：真实来源已接正式组合，继续最终交付验证。** 持久操作、文件发布失败核对、Owner备份来源、恢复重绑及新版控件联合检查已有实现和证据；三个独立测试进程验证了结果恢复。M05完整Release候选f1bd29ea已打包，旧版混合资料经新版入口四进程往返通过。外部文件访问恢复及明确重选接缝已实现；e3117d4a完整Release的20阶段及独立签名沙箱两进程检查通过，仍需正式Flutter App原生面板及外部位置重开；不能把测试进程等同于已安装 App 可日用。当前#73的实际换包与钥匙串状态以上述记录为准。

4. **#75/#76：普通附件后续适配。** #75已接Owner有界校验读取、真实版本及文字/图片/PDF分页预览；PDF完整Release构建和同源隔离沙箱Debug原生通道/翻页6项检查通过，导入/替换/保留版本恢复及持久回执已接并通过真实存储/控件回归，同源独立沙箱Debug导入/替换/恢复9项通过，主人另存已接持久发布/原结果核对/暂存清理，存储300、桌面45及同源真实沙箱11项通过；本机打开已接Owner临时副本/持久结果/清理及原生调度，存储313、桌面74+启动16及同源沙箱14项通过；实际默认程序接收/显示、文件面板和同候选正式交付仍待，#76已接真实当前文件元数据核对、部分审批及准确原文事务校验，核心363/6、存储313/19、桌面43及实际沙箱App→AOT CLI的19项联合检查通过；真实交付/清理历史与批准/交付各自准确预览已接，相关桌面及正式Host56项、同源实际沙箱21项通过；b3fe1964完整ARM64候选20阶段通过，运行库同源的隔离原生App四个独立进程21项重开/完整恢复通过；0a5e3500修正撤销/结束误写为到期的问题并重新打完整包；同包外部CLI与真实AI文件聊天及新版原生审批/历史控件11项已通过，22次模型调用与两个真实开始/结束事件完成。正常Release固定安装已换入，但仍等待系统允许及正常开库/重开；合成QA不替代这些结论。未增加演示入口。

5. **#77：托管凭据管理。** 已从#69后置范围单列，750899d8接已有凭据的Owner元数据和保留材料版本，fee8e4a7补纯时间到期刷新，SQLCipher/控件相关54项及最终严格分析通过。申请和关联读取失败独立提示，换来源不沿用旧私有备注。安全录入、持久写入/回执、生命周期与同源交付继续实施；本段没有重打包或替换当前等待Keychain的0a5e3500。

最新实施及证据：[M01](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m01.md)、[M02](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m02.md)、[M03](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m03.md)、[M04](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m04.md)、[M05](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m05.md)、[M06](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m06.md)、[M07](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/development/zhiyu-macos-real-m07.md)。这些记录保留具体来源与验证边界；未验事项不勾选、整票不提前关闭。

## 后置范围与原票归属

| 范围 | 安排 |
| --- | --- |
| 普通附件与托管凭据 | 普通附件已拆为 #75/#76，详见[实施顺序](macos-ordinary-attachments.md)；凭据管理已单列 #77，AI使用审批/执行适配后续拆分。复用既有底层，原#73换包不等待本增强 |
| AI 录入/修改提案、整理 | 后续按 #67 界面合同接真实能力；请求仍由 AI 发起 |
| 插件与其他设置 | 后续按 #65/#68 及领域决策细化；备份部分已单列 #74 |
| Mac 生命周期、通知、完整界面及安装 | 沿用 #46/#47/#48/#50，#73 回填同候选证据；系统通知不是首批接收请求的唯一通道 |
| Windows、跨平台迁移、其他机器与公证分发 | 保留原票范围，放在本机 Mac 首批可用之后，不运行 Windows CI |

需要本人操作的步骤由 #73 集中说明用途，优先完成自动化准备。系统密码由本人输入；中文输入、通知点击及睡眠唤醒分别按实际验收记录，不反复换候选制造授权提示，不承诺更换签名后永不提示。

## 执行约束与历史

保持 `codex/zhiyu-macos` 独立分支，不改 main/Windows。只用隔离合成资料做自动验证，不扩大个人 hooks、信任或资料访问范围。已逐项验证保留ZIP后清理M04/M06/旧M07三份展开载荷，约1.10GB逻辑大小，当前候选和旧安装回退仍保留。交付后保留一个当前安装，清理本轮可重建的多余 App/dSYM；不动个人资料、旧版回退保护或来源不明文件。

[历史规划与阶段记录](https://github.com/ShiJiJS/agent-info-manage/blob/codex/zhiyu-macos/docs/planning/zhiyu-round09/macos-real-function-plan.md)保留供追溯，其中旧检查点的“下一步”不再作为当前排期。各子票原规格与未验项保持，本路线图不降低验收要求。
