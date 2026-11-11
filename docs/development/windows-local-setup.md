# Windows 本机开发

需要 64 位 Windows、Git、Visual Studio 2022 Build Tools 的 C++ 桌面工作负载、MSVC、CMake 和 Windows SDK。项目使用 Flutter 3.47.7 / Dart 3.13.5，固定提交 `abaf9c523780a608bd46686fd5e53740a07077f8`，与 Mac 一致。

同步与联网测试用 OpenSSL 创建临时证书。开发和完整检查脚本优先使用当前 PATH 的 OpenSSL，缺失时自动接入 Git for Windows 自带的 `usr/bin/openssl.exe`，仅影响当前进程及其测试子进程，不修改系统 PATH。这是测试依赖，运行已打包 App 不需要 OpenSSL。

## 常用命令

在仓库根目录的 PowerShell 中运行：

```powershell
.\scripts\dev-windows.ps1 setup
.\scripts\dev-windows.ps1 doctor
.\scripts\dev-windows.ps1 analyze
.\scripts\dev-windows.ps1 smoke
.\scripts\dev-windows.ps1 test
.\scripts\dev-windows.ps1 build
.\scripts\dev-windows.ps1 run
```

`setup` 准备固定 SDK、五个共享包、服务端及桌面端的锁定依赖。SDK 位于 `.tools/flutter`，包缓存位于 `.cache/pub`，下载位于 `.downloads`；脚本通过本机 Git exclude 排除这些目录。

`build` 生成 `apps/desktop/build/windows/x64/runner/Release/info_desktop.exe` 及配套 worker；运行时保留相邻 DLL 和 data。`run` 使用调试模式。

`analyze` 检查全部模块；`smoke` 运行加密存储、连接与界面控制器检查；`test` 运行各模块测试。部分集成场景需要 Linux/macOS 服务宿主或特定平台，按测试声明在对应环境执行，不以跳过代替通过。

原生 SSH 凭据检查可复用 `scripts/qa/macos-ssh-fixture.py` 的临时回环夹具，QA Python 环境使用现有的 `paramiko==5.1.0`。Windows 默认使用系统 OpenSSH 的 `ssh-keygen.exe`，也可通过 `--ssh-keygen` 指定准确路径；不需要 WSL 或 NAS 服务变更。传入全新的 `build/` 子目录，使用生成的 `fixture.json` 设置 `D7_SSH_FIXTURE`、`D7_SSH_PORT`，并将 `D7_SSH_EXE` 指向系统 `ssh.exe`，运行 `packages/info_cli/test/ssh_receiver_native_test.dart`。夹具仅接受本次合成密钥和固定测试命令。

夹具加 `--stop-file` 启动后，在调用方检查及材料清理结束时创建该夹具目录内的 `stop` 文件，等待正常退出，再清理本次合成文件；不停止系统 SSH 服务或使用个人密钥。

直接调用固定 SDK：

```powershell
.\scripts\dev-windows.ps1 flutter --version
.\scripts\dev-windows.ps1 dart --version
```

Python 构建工具可通过 uv 安装到项目的 `.tools/python`，uv 缓存放 `.cache/uv`；不要把工具缓存或一次性验收记录提交到源码。

## 联网与交付

正常入口支持本地加密资料库和独立 HTTPS 服务同步。Windows 连接配置保存在当前用户的 `%APPDATA%/Chiyo/online`，本地库及其 DPAPI 密钥位于该配置下的 `local` 目录；配置和密钥使用私有 ACL。各设备独立登记，不复制其他设备的加密状态。已有 NAS 配置在初次同步完成前继续连接原服务。

- [服务部署](../../apps/server/README.md)与[维护](../../apps/server/OPERATIONS.md)
- [Windows 打包、安装和清理](windows-delivery.md)
- [联网包使用说明](windows-online-delivery.md)
- [Codex 接入](windows-codex-integration.md)
- [连续核对范围](windows-online-acceptance.md)

当前任务、限制和完成状态从 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 读取；本页只维护可重复使用的开发步骤。
