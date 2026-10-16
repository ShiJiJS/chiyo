# Windows 开发预览交付（Issue #18）

交付物是未签名的 Windows x64 ZIP，包含完整 Flutter release 目录、独立 AOT
CLI、SDK-free Codex 接入材料生成器、合成资料控制台检查、依赖许可和来源清单。
它用于配合验收；Issue #18 的干净环境、真实桌面和 Codex 检查仍开放。

## 使用预览包

1. 对照一起提供的 `.sha256` 文件核对 ZIP 的 SHA-256，然后完整解压到一个稳定
   的当前用户目录。保留 `AgentInfoManage/app` 中全部 DLL 和 `data/`。
   `manifest.json` 记录准确源码提交、SDK、锁文件和每个文件的校验值。
2. 环境须为 Windows x64，并已安装兼容构建工具链的 Microsoft Visual C++ v14
   x64 Redistributable。本包不包含、不下载也不自动安装运行库。需要时由用户从
   [Microsoft 官方运行库页面](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)
   安装。当前编译及无窗口检查环境为 Windows 11 Home x64（10.0.26300）；
   Windows 10、ARM64、32 位、无开发工具干净机器尚未实测，不承诺支持。
3. 用户准备好后启动 `app/info_desktop.exe`。关闭窗口保留托盘和本机服务；
   使用应用的“完全退出”停止服务。先使用虚构信息。
4. CLI 可用完整路径调用 `cli/info.exe`（通用 JSON-lines），无需安装 Dart、
   Flutter 或 Java；不自动修改 PATH。Codex 使用下面的独立接入步骤。

示例（路径仅为示例，使用实际解压路径）：

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '.\agent-info-manage-<版本>-windows-x64.zip'
& 'C:\Tools\AgentInfoManage\cli\info-prepare-codex.exe' 'C:\Tools\AgentInfoCodex-preview'
```

生成器将编译好的 Codex CLI/hook 复制到指定的**新目录**，生成指向该最终目录的
`hooks.json` 和 `skills/agent-info-access/SKILL.md`。已有目标目录或文件会被拒绝；
不合并、不覆盖项目/用户配置，也不安装或信任 hook。支持含空格和中文的路径。
生成后保持此目录位置稳定；更换位置时选新目录重新生成并审查配置。

在用户明确准备接入后，按随包 `CODEX-INTEGRATION.md` 审查、合并项目 hook、
放置 Skill 并通过 Codex 正式入口信任准确的定义，保留现有配置。
生成器只写指定的新目录；安装与信任仍需单独配合。不要将私密关联放进命令参数。

`diagnostics/bin/info-storage-check.exe` 仅在独立临时目录使用合成资料和当前用户
DPAPI 验证加密、重开、旧凭据失效及旧 schema 迁移，不打开实际资料库，也不启动
桌面。保留旁边完整的 `diagnostics/lib/`；原生资产使用
[Dart build cli 的 bin/lib 布局](https://dart.dev/tools/dart-build)。其 SQLCipher DLL
校验值与桌面包相同；这不能代替真实桌面启动验收。

## 升级、数据和已知限制

资料保存在 `%LOCALAPPDATA%\AgentInfoManage`，本机随机数据库密钥由当前用户
DPAPI 保护，和安装目录分离。升级前在应用中导出独立恢复密钥的备份并另行保存
恢复密钥，然后完全退出旧应用，将新 ZIP 解压到新目录，保留原数据目录及
`database-key.dpapi`。不要同时运行两个版本；重新生成及审查新版本 Codex bundle。
仅复制本机数据库或 DPAPI 文件到另一个用户/设备不能代替独立备份恢复。

当前保持既有内部可执行文件名和资料路径；没有安装器、自动升级、开机自启、
商店发布或代码签名。Windows 可能提示未知发布者；不安装自签根证书、不修改
系统执行策略来绕过提示。源码尚未声明项目级开源许可，本包仅作私有开发验收。
第三方许可见 `notices/`，Flutter 生成的组件许可也保留在 `app/data/`。

等待用户配合的项目见随包 `ACCEPTANCE.md`，包括真实桌面、通知/托盘、文件对话框、
Codex 两聊天/主子 agent/结束事件、干净用户环境及实际升级。macOS 使用用户自己的
Mac 后续验证，当前不运行托管 Mac 作业。生产发布及跨平台依赖锁定仍受 ADR 0004
验收约束，不能从本包的编译成功推断全部完成。

## 从源码重建

在带 Flutter 及 Visual Studio C++ 桌面工作负载和 Windows SDK 的 Windows x64
开发环境，从干净已提交源码执行：

```powershell
.\scripts\package-windows.ps1 -FlutterBin 'C:\SDK\flutter\bin' -OutputDirectory 'C:\Artifacts\agent-info-new' -Offline
```

首次依赖未缓存时去掉 `-Offline`。命令运行全量无窗口分析/测试和 Windows release
编译，编译独立 CLI/检查程序，复制完整发行目录和依赖许可，验证 SQLCipher
官方资产哈希，生成版本化 ZIP、manifest 和 SHA-256；随后解压到中文/空格临时
路径运行真实编译 CLI/hook 和合成 DPAPI/SQLCipher 检查。输出目录须不存在。
不承诺不同机器生成的二进制逐字节相同；锁文件、源码提交、工具链及输出哈希用于
复现和核对构建。失败会保留输出供诊断，重试使用新目录。

ZIP 布局遵循 [Flutter Windows 分发说明](https://docs.flutter.dev/platform-integration/windows/building)。
SQLCipher 使用 sqlite3 包锁定的原生资产，其预期哈希及 Dart 依赖锁文件收录于
`provenance/`；SQLCipher 4.19.0 许可来源为
[上游 LICENSE](https://github.com/sqlcipher/sqlcipher/blob/v4.19.0/LICENSE.md)。
