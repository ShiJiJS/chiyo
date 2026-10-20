# 隔离 Windows 原生授权验收

2026-10-17。此项为 #18 和 #23–#31 提供可重复的原生验证入口，不代表整套升级或全部 Windows 安装验收已经完成。

## 验收边界

`apps/desktop/integration_test/desktop_cli_test.dart` 通过真实 Flutter Windows runner/window、`InformationApp`、`DesktopBootstrap`、SQLCipher repository、当前用户 DPAPI、loopback AgentServer 和独立 Dart CLI 验证普通信息授权。测试先在新临时目录保存虚构资料，使用服务生成并由公开目录返回的信息/字段 ID，不假设正式库存在 demo 数据。

- 每次创建独立系统临时根 `aim-native-approval-*`；数据库和 DPAPI envelope 均在其中。
- `DesktopBootstrap(port: 0)` 由系统分配独立端口，子 CLI 使用显式 `--port`。
- 不调用正式 `app.main()`，不使用 `%LOCALAPPDATA%/AgentInfoManage`，不修改现有 Codex 配置或全局环境。
- 桌面托盘、通知和 terminate 使用测试专用 inert `DesktopPlatform`，防止测试隐藏窗口或退出 runner；Flutter 原生窗口和窗口 frame 为真实实现。因此本测试不证明托盘/系统通知已验收。
- CLI 结束后卸载界面，停止 runtime/service/server、关闭 repository；验证删除目标为本次创建的系统临时根后才递归清理。失败也执行 teardown。

测试断言：审批前拒读 → GUI 取消用户名勾选并部分批准 → CLI 领取的实际范围只有地址且不输出 bearer → 地址重复读取成功 → 未批准用户名拒绝 → GUI 撤销 → 后续地址读取拒绝。CLI 正常退出且 stderr 为空。

## 运行

从仓库根目录执行；此命令会显示真实测试窗口：

```powershell
./scripts/test-windows-native.ps1 -FlutterBin C:\Users\Todoki\.local\share\flutter\bin
```

脚本根据当前 checkout 自动传入 SDK 的 `dart.exe` 和对应 `packages/info_cli` 的绝对路径，不依赖另一个工作树。等价直接命令：

```powershell
# 工作目录 apps/desktop；CLI_DIRECTORY 使用当前 checkout 的绝对路径。
flutter test integration_test/desktop_cli_test.dart -d windows --dart-define DART_EXECUTABLE=<FlutterBin>/cache/dart-sdk/bin/dart.exe --dart-define CLI_DIRECTORY=<Repo>/packages/info_cli
```

无窗口检查仍使用 `scripts/check.ps1`；`scripts/test-windows-package.ps1` 验证打包、SDK-free CLI/hooks、SQLCipher/DPAPI，但不会验证 GUI，不能替代本项。

## 本次 red → green 证据

在 `codex/round05-native-fixture` 工作树，以 Flutter 3.47.7 / Dart 3.13.5 在 Windows 运行上述原生测试。

1. Red：先完成独立加密库/随机端口/真实 CLI fixture，尚未添加 seed。Windows executable 成功构建并运行，公开目录断言预期一条虚构信息、实际零条，`+0 -1`。这确认测试使用的是新的空库，并能发现资料准备遗漏。
2. Green：只通过 owner `createInformation` 向该隔离库写入两字段虚构信息，再运行同一个原生测试。输出 `+1: All tests passed!`，实际测试约 5 秒；测试窗口、真实 CLI 和存储均参与。

使用的直接命令：

```powershell
& 'C:\Users\Todoki\.local\share\flutter\bin\flutter.bat' test integration_test/desktop_cli_test.dart -d windows --dart-define 'DART_EXECUTABLE=C:\Users\Todoki\.local\share\flutter\bin\cache\dart-sdk\bin\dart.exe' --dart-define 'CLI_DIRECTORY=C:\Project\network_config\info-manage-worktrees\native-fixture\packages\info_cli'
```

托管凭据/文件执行、备份恢复、打包后 GUI、后台/通知、崩溃恢复仍须在相应任务实现后扩展验收。本项不要求也未执行 Mac 实际验收。
