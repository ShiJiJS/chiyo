# 从这轮 Mac 改动继续 Windows 开发

2026-11-07。当前源码版本 `0.4.4+18`；Mac交付源码为`612cb89b004a`。
本轮把 `codex/macos-library-management` 的资料管理、AI录入说明、动态模板
示例和SSH会话授权改动整理为PR，目标是让下一轮Windows开发从主分支接续。
合并不代表这批改动已在Windows完成构建或原生验收。

## 包含什么

- #82—#84：正确保存来源原件、完整目录查询、审批时展示和选择完整目录。
- #85—#87：目录连同内容整批回收与恢复、右键和多选管理、移动及手动排序。
- #88：按用途命名、分类和去重的录入指引；App动态提供部署及设备配置例子。
- #89：SSH可由用户选择当前聊天内不限时，撤销及结束聊天后阻止后续使用。
- Markdown文件预览、旧附件转独立文件模板、凭据说明编辑入口等相关修复。

业务与加密存储主要在 `packages/info_core`、`packages/info_storage`，CLI在
`packages/info_cli`，共用界面在`apps/desktop/lib/workspace`。Windows启动入口为
`apps/desktop/lib/platform/windows_library.dart`，系统驱动和原生目录仍保留。
接续时复用当前业务规则；系统差异放在已有平台实现，不另建一套录入或模板协议。

## Windows上从哪里开始

先保存Windows工作区里尚未提交的修改，再取主分支并新建开发分支：

```powershell
git fetch origin
git switch main
git pull --ff-only origin main
git switch -c codex/windows-followup
```

先运行源码检查和Windows Release构建；`FlutterBin`换成本机SDK位置：

```powershell
pwsh -File .\scripts\check.ps1 -FlutterBin 'C:\SDK\flutter\bin' -WindowsRelease
```

检查脚本会按锁文件解析依赖并运行四包检查。不要为绕过失败直接升级依赖或
重写锁文件。完整Windows打包、固定安装位置及清理继续按
[Windows交付说明的本机安装与清理](windows-delivery.md#本机安装与清理)执行。
本轮没有发起Windows CI；托管runner仍须按工作流中的额度约定另行安排。

## 优先验证什么

1. 在独立合成资料库启动，确认Windows系统密钥、加密开库、文件选择与另存。
2. 跑一份多条录入提案：目录树、动态模板、密码补填、预览及一次整体保存。
3. 右键、Ctrl／Shift多选、拖放移动、键盘调序和整批回收恢复；核对Windows焦点
   与快捷键，并确认失败不会留下部分变更。
4. 重开及完整备份恢复后，目录顺序、关联、文件原文和全部版本保持；旧授权不恢复。
5. 使用合成SSH服务检查限时与会话内不限时、撤销、会话结束，以及现有Windows
   worker和焦点填充入口。重新生成并审阅同版本CLI／Skill接入材料，不能混用旧包。

新增内容会按需使用资料库格式50（目录批次）、51（排列）、52（SSH会话条件），
相应备份支持到22；没有这些内容的库不因读取自动提升到最高标记。旧Windows程序
不能读取全部新格式。真实升级前先在旧版导出完整备份并另存恢复密钥，先用空库
完成这轮验证，不用旧程序重新打开已升级的库。

Git只同步代码。Mac上的真实资料、密码、恢复密钥、本地安装包及接入信任不在PR中，
不会随拉取代码自动迁移。当前Mac测试范围及实际结果见
[0.4.3软件检查](macos-library-management-043.md)、
[后续Skill试用](skill-guidance-20261107.md)及
[0.4.4正式库核对](macos-source-cleanup-044.md)；它们不替代上述Windows检查。
