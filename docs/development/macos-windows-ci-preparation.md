# Mac 分支的独立 Windows 回归入口（待批准运行）

2026-10-21，为 #41 尚未完成的当前共享改动 Windows 回归准备。代码和 workflow 只在 `codex/macos-adaptation`，没有更新主分支或 Windows 开发分支，没有触碰用户的 Windows 机器。

现有 `.github/workflows/macos-validation.yml` 已明确规定：只有仓库主人同意使用私有仓库 Actions 额度/预算后才运行托管 runner。本轮确认该仓库为 Private。因而先完成可审查的入口和本机检查，**尚未调度云端任务，不宣称 Windows 已通过，也不勾选 #41 第四条**。

原有手动工作流增加 `platform: windows | macos` 选项（此分支默认 Windows）；原专用 `ci/macos-validation` push 仍只跑 Mac。普通整合分支 push、PR 和本 Mac 分支 push 不触发付费 runner。并发组按平台与 ref 隔离。默认 main 上现有工作流不变。

Windows 目标使用 GitHub 托管的 `windows-2022` x64 独立临时机器，单 job 上限 30 分钟、仓库只读权限、checkout 不保留凭据，不部署、不安装用户配置、不注册或信任 hook。官方 runner 清单当前仍提供该标签；Flutter 固定为现有 `abaf9c523780a608bd46686fd5e53740a07077f8`，Actions 固定完整提交摘要。

按顺序验证：

1. 四包严格分析及测试、Windows Release 构建，原依赖锁保持；
2. 编译同业务源码的 Windows x64 CLI/hook/worker 材料，仅生成材料，跑实际 AOT 子进程测试；
3. Windows 原生 Flutter 窗口中的 desktop/CLI、资料管理和提案流程，均使用隔离合成库；
4. Windows 普通附件原生窗口流程、独立 AOT CLI、部分批准、版本/回收与备份恢复，明确启用 picker 夹具，不宣称实际 OS 文件面板或浏览器上传通过。

脚本为 `scripts/qa/windows-mac-branch.ps1`，拒绝已有输出或 build/ 外路径。在 Mac 用校验过官方发行摘要的项目本地 PowerShell 7.5.4 完成语法解析、确认 Windows 前置拒绝且不创建输出；YAML、手动分支条件、30 分钟上限、Action 摘要及只读权限做了静态核对。**这些检查不等于 Windows 运行**。

已在真实 Actions 表单中核对该已存在 workflow 文件：ref=`codex/macos-adaptation`、platform=`windows`，分支参数正常显示，观察到 0 次运行。尚未点击提交。批准后再次核对当前分支和平台，只执行一次；运行失败不自动续用额外预算重复调度。

保留 3 天的 artifact 只含 manifest、测试日志、文件流程的公开 result 与合成截图；不上传 exe、数据库、备份或恢复密钥。各阶段失败会保留退出事实，未完成不标为成功。只有取回实际 Windows 日志、逐项核对通过/跳过和原生结果后，才评估 #41 的 Windows 条件。

本轮仍未消费 Actions runner 额度。后续是否运行，等待用户明确批准这一次 Windows job（最多 30 分钟，消耗私库额度或可能的按量费用）。
