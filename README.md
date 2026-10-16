# Agent 信息访问授权

为 Agent 提供按聊天申请、由用户批准的信息访问方式。Flutter 桌面端负责管理和审批，Dart CLI 通过本机接口申请与读取，核心服务逐次检查实际批准的字段范围。

当前正在实现第一版，尚不能作为真实个人资料的正式存储工具。具体已验证能力及剩余工作见 [实施进度](docs/planning/implementation-status.md)。

- [产品规格](docs/specs/0001-local-information-access.md) · [GitHub 父 Issue](https://github.com/ShiJiJS/agent-info-manage/issues/1)
- [18 张实施任务与依赖](docs/planning/ticket-breakdown.md)
- [领域术语](GLOSSARY.md) · [架构决策](docs/adr/)
- [第一条授权流程与运行方法](docs/development/first-authorization-slice.md)

## 开发

使用 Flutter 3.47.7 / Dart 3.13.5。Windows 桌面构建还需要 Visual Studio 的 C++ 桌面工具链；macOS 构建需要在 Mac 上准备 Xcode。

无可见窗口的检查可以分别在各包目录运行：

| 目录 | 检查 |
| --- | --- |
| `packages/info_core` | `dart pub get`、`dart analyze`、`dart test` |
| `packages/info_cli` | `dart pub get`、`dart analyze`、`dart test` |
| `apps/desktop` | `flutter pub get`、`flutter analyze`、`flutter test` |

`flutter build windows --release` 只编译。`flutter run`、运行桌面可执行文件及指定桌面设备的 `integration_test` 会打开可见窗口，应安排好手动验证后再执行。

Windows 也可以运行 `./scripts/check.ps1 -FlutterBin <Flutter安装目录>/bin`，统一检查各 Dart 包和桌面 widget 测试。添加 `-WindowsRelease` 会编译发行包，仍不会启动窗口；依赖已缓存时可添加 `-Offline`。

CLI 不直接打开资料库，也不提供批准申请的管理接口。开发与测试使用虚构资料；真实资料迁移需要先完成加密、系统密钥保管和备份恢复验收。
