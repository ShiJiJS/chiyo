# Windows 本机开发环境

2026-11-09，在 `C:\Project\agent_ask\agent_info` 配置。源码来自
`ShiJiJS/chiyo` 的 `main`，基线提交为 `ac8960c77e124e7f10c3be3c6a67364db3a0ea2e`
（PR #107：服务端、联网客户端和增量同步）。

## 工具与目录

| 内容 | 位置或版本 |
| --- | --- |
| Flutter / Dart | `.tools/flutter`，3.47.7 / 3.13.5，与 Mac 固定版本一致 |
| Flutter 提交 | `abaf9c523780a608bd46686fd5e53740a07077f8` |
| Python | `.tools/python`，uv 管理的 Python 3.13 |
| Dart 包缓存 | `.cache/pub` |
| uv 缓存 | `.cache/uv` |
| SDK 归档及安装日志 | `.downloads` |
| 本机验证记录 | `local/development` |
| 已编译 CLI / worker | `build/development/cli` |
| 本机生成的接入材料 | `build/development/codex-bundle` |
| Visual Studio Build Tools | 2022，C++ 桌面工作负载、MSVC、CMake 和 Windows SDK，安装在系统目录 |
| VS Code | `.vscode/settings.json` 指向项目 SDK；Flutter 和 Dart 扩展已安装 |

SDK、缓存和下载目录通过本机 `.git/info/exclude` 排除，不提交到仓库。
Flutter Windows ZIP 的 SHA-256 已与官方发布清单核对：
`c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4`。
来源：[Flutter SDK archive](https://docs.flutter.dev/install/archive)。

## 常用命令

在仓库根目录的 PowerShell 中运行：

```powershell
.\scripts\dev-windows.ps1 setup
.\scripts\dev-windows.ps1 doctor
.\scripts\dev-windows.ps1 analyze
.\scripts\dev-windows.ps1 smoke
.\scripts\dev-windows.ps1 build
.\scripts\dev-windows.ps1 run
```

`setup` 使用锁文件安装五个共享包、服务端和桌面端依赖。
`build` 编译 Windows release，输出为
`apps/desktop/build/windows/x64/runner/Release/info_desktop.exe`，运行时保留其全部相邻文件。
同一命令会编译配套 `info-runtime-worker.exe` 并放在桌面程序旁。
`run` 使用调试模式，支持 Flutter 热重载。

`smoke` 运行 Windows 可执行的加密存储、连接配置、审批控制器及资料列表检查。
`test` 尝试全部测试；其中联网集成测试直接启动 Linux/macOS 服务端，依赖 Unix
密钥文件权限接口，不能在 Windows 原生环境完整运行。此类测试应在 Linux/macOS
或相应容器环境验证，不能通过放宽服务端密钥检查绕过。

需要直接调用 SDK 时，命令保持当前目录：

```powershell
.\scripts\dev-windows.ps1 flutter --version
.\scripts\dev-windows.ps1 dart --version
```

首次在其他 Windows 机器准备环境，先安装 Git、Visual Studio 2022 Build Tools 的
`Microsoft.VisualStudio.Workload.VCTools`（包含推荐组件）及
`Microsoft.VisualStudio.Component.VC.CMake.Project`，再运行 `setup`。
可选 Python 使用 `uv` 安装到上述项目目录：

```powershell
$env:UV_PYTHON_INSTALL_DIR = "$PWD\.tools\python"
$env:UV_CACHE_DIR = "$PWD\.cache\uv"
uv python install 3.13 --no-bin
```

## 当前程序的入口

`apps/desktop/lib/main.dart` 启动联网客户端，连接页面使用服务器地址和服务接入 Token；
Mac 上的服务接入凭证不随 Git 源码分发。
此开发环境本身不需要运行额外的 MySQL、Java 或 Node 服务。
独立服务端的部署说明见 `docs/planning/server-multidevice/`。

**当前主分支仍有 Windows 联网适配缺口。**
`packages/info_remote/lib/connection_profile.dart` 的
`PrivateConnectionProfileStore` 明确只允许 Linux/macOS，因此 Windows 启动后会显示
“无法读取连接设置，请重新连接”，保存连接设置也会被拒绝。桌面 release 编译成功
不表示已经能够连接 NAS。后续 #104 需要实现 Windows 的私密连接配置保护，并核对
Agent 设备配置、CLI/worker 接入及相关平台路径；不能删除平台检查后明文保存 Token。

本机源码构建与启动检查不代表 #104 的第二台设备全流程、#105 的跨电脑审批均已完成。
需要生成完整 Windows 交付包时，继续遵循
`docs/development/windows-delivery.md`；开发构建不自动安装或替换正式软件。

## 本次验证

- Git 当前源码完整性检查通过，依赖锁文件版本保持。
- 五个共享包、服务端及桌面端的 `analyze --fatal-infos` 全部通过。修复了原有三处
  lint（缺少大括号、可使用 super 参数），没有修改业务规则。
- Windows 原生加密存储及服务端状态存储共 6 项通过；连接配置、审批及资料列表
  控制器共 19 项通过。
- 五个 CLI/worker AOT 可执行文件编译成功，接入材料生成器实际运行成功。
- Visual Studio Build Tools 17.14.44 和 Windows SDK 10.0.26100.0 安装完成，
  Flutter Windows 工具链检查通过，无需重启。doctor 中缺少 Android SDK 的提示不影响 Windows 开发。
- Windows release 桌面程序、焦点辅助程序、SQLCipher 及配套 worker 已生成；
  CLI 实际状态查询和正常退出检查通过。
- 尝试的两项联网集成测试未通过 Windows 本机验证：TLS 夹具需要 OpenSSL，
  随后依赖的服务端密钥提供器明确仅支持 Linux/macOS。本次未调整其安全边界。

具体输出保存在 `local/development`；接入材料尚未安装到全局 Agent 配置。
computer-use 界面调试按用户要求暂缓，环境准备和命令行验证已完成。
