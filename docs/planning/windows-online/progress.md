# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-09（Asia/Shanghai）。
- 状态：九张工单已发布并逐项回读核对；持续开发尚未启动。
- 方案范围：2、3、4、5、6、7、9、10、11；已发布为 #108、#109、#110、#111、#112、#113、#114、#115、#116。父任务 #104，#105 后置。
- 已完成开发票：无；启动后的第一项：方案 2。
- 源码基线：ac8960c77e124e7f10c3be3c6a67364db3a0ea2e，当前分支 main。
- 约束：直接对接现有 NAS；computer-use 暂缓；没有 WSL/另建服务、密码填充或额外交付票。
- 当前没有本组启动的开发任务或测试进程。

## 已有准备

GitHub #108–#116 的标题、正文、ready-for-agent 标签、#104 父关系及 13 条直接前置已全部核对；#104 原规格和历史保留。发布结果见 publication.json，启动描述见 goal.md。本轮没有创建或启动实际 goal。

SDK、C++ 工具链、Windows release、五个 AOT CLI 和开发说明已准备。已有静态分析及 25 项选定检查不代表新联网工单通过。

用户已否定最初十二项草案中的过度拆分；已撤掉方案 1、8 和 U01 文件，并重写九票、执行约定及 goal。后续以本目录九票清单为准。

## 启动前保留的改动

- scripts/dev-windows.ps1
- docs/development/windows-local-setup.md
- packages/info_core/lib/builtin_information_definitions.dart（lint）
- apps/desktop/lib/workspace/owner_workspace_grant_history.dart（lint）
- apps/desktop/lib/workspace/owner_workspace_history.dart（lint）
- AGENTS.md 中本规划入口、docs/planning/windows-online/ 中的发布材料。

这些是环境准备及规划，未作为九票业务实现。启动时核对并归档，不清掉已有编辑来获得干净工作区。

## 下一步

本轮只完成工单发布和 goal 描述；收到明确启动指令后，读取 #108 并开始。恢复时核对 tickets.json/publication.json，避免重复建票。

## 执行时的记录

保持当前快照简短，逐票补：工单/提交、实际结果、有效检查及日志、运行资源、待用户/待回填事项、下一票和首个具体动作。不要积累互相冲突的“下一步”。

