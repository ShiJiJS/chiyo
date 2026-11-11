# Windows 构建、安装与清理

Windows x64 开发包包含完整桌面程序、CLI、worker、固定 GH/AWS 工具、依赖许可和来源清单。构建要求固定 Flutter SDK、Windows C++ 工具链及 Python。

## 从源码构建

在干净、已提交的源码下执行，输出必须是新目录：

```powershell
.\scripts\package-windows.ps1 -FlutterBin 'C:\SDK\flutter\bin' -Python 'C:\Tools\python.exe' -OutputDirectory 'C:\Artifacts\chiyo-new' -Offline -PackageOnly
```

首次缺少缓存依赖时去掉 `-Offline`；版本和摘要仍按锁定配置核对。`-PackageOnly` 只产包。脚本验证归档和解包载荷，生成 ZIP、SHA256、manifest 与核对回执；这些结果不替代真实桌面、Codex 宿主或干净机器验收。

## 本机安装与清理

Windows 固定安装位置为 `C:\Software\AgentInfoManage`：`current` 保存完整程序，`package` 保存当前版本 ZIP、SHA 和安装核对信息。桌面“知予”快捷方式指向 `current/app/info_desktop.exe`。

用户已授权安装时，可省略 `-PackageOnly`，完整检查成功后脚本安装并清理。安装器先校验归档与全部载荷、暂存新目录、通过 CLI 正常退出旧实例，再切换目录和保存快捷方式。退出或保存失败时保留旧实例，不强杀。

单独安装已核对的归档：

```powershell
.\scripts\install-windows-preview.ps1 -ArchivePath 'C:\Artifacts\chiyo-new\chiyo-version-windows-x64.zip' -CleanBuildArtifacts
```

如需退出从其他构建目录启动的实例，先核对路径，再传入准确的 `-RunningProcessId`。未通过完整检查的候选仅在用户明确要求预览时使用 `-PreviewReason`，如实保留限制。

`clean-windows-artifacts.ps1` 复核外部安装和 ZIP 后，清理项目中的旧包、桌面 build、Dart 生成缓存及所属 QA 编译输出。它支持 `-WhatIf`。当前安装及正在使用的产物、用户资料库、密钥、恢复备份、已配置的独立 Codex 运行目录、共享 SDK 和依赖缓存分别管理。

SDK 工具的可执行文件可能位于共享 SDK，进程路径不能反映其正在使用的工作目录。已知有此类工具仍在运行时，用 `-KeepPath @('apps/desktop/build', 'apps/desktop/.dart_tool')` 显式保留对应目录；路径相对当前 checkout，也可使用 checkout 内的绝对路径。缺少 `build` 根目录的独立 checkout 仍可清理其他已生成缓存。

开发截图、历史日志和一次性证据不作为长期仓库资料；任务产物放在被 Git 忽略的 `build/` 下，用完清理。当前包的完整性清单和安装核对信息随包保留，避免把历史截图当作当前版本的运行验收。

## 使用和接入

- [联网包使用说明](windows-online-delivery.md)
- [Codex 接入](windows-codex-integration.md)
- [连续核对范围](windows-online-acceptance.md)
- [本机开发环境](windows-local-setup.md)

已安装 hooks 和 Skill 独立管理；构建与清理不改变它们的路径或信任。用户资料与安装目录分离，升级前按实际迁移需要准备恢复材料，勿将另一台机器的 DPAPI 文件当作备份。
