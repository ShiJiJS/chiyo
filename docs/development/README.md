# 开发指南

[项目首页](../../README.md) · [English overview](../../README.en.md) · [文档导航](../README.md)

## 仓库结构

| 目录 | 职责 |
| --- | --- |
| `apps/desktop/` | Flutter 桌面 App，以及 macOS / Windows 原生窗口、通知、文件与输入接口 |
| `apps/server/` | 独立 HTTPS 服务、Docker 镜像和服务端集成测试 |
| `packages/info_core/` | 资料、模板、提案、授权与凭据使用规则 |
| `packages/info_storage/` | SQLCipher、系统密钥、备份、历史和同步持久化 |
| `packages/info_remote/` | HTTPS 客户端、连接发现与私有接入配置 |
| `packages/info_workspace/` | App 与服务器共用的界面数据合同、Owner 适配和传输格式 |
| `packages/info_cli/` | 通用 CLI、Codex 会话接入和设备执行 worker |
| `integrations/` | 开发包附带的说明及 Skill 模板 |
| `deploy/` | Docker Compose、服务配置和局域网证书示例；实际数据放在仓库外 |
| `scripts/` | 固定 SDK、构建、打包、安装及图标资源同步 |
| `scripts/qa/` | 可重复运行的隔离原生检查、合成服务和测试夹具 |
| `docs/` | 使用、部署、开发和仍有效的接口合同 |
| `third_party/` | 第三方许可与固定工具来源信息 |

## 配置和运行

项目固定 Flutter 3.47.7 / Dart 3.13.5。SDK 在 `.tools/flutter`，依赖缓存在 `.cache/pub`，下载在 `.downloads`；这些是本机工作文件，不进入版本管理。

Mac 需要完整 Xcode，Windows 需要 Visual Studio 的 C++ 桌面工具链。具体版本、可用命令和依赖安装以对应平台说明为准：

- [Mac 本机开发](macos-local-setup.md)
- [Windows 本机开发](windows-local-setup.md)

Mac 常用入口：

```sh
./scripts/dev-macos.sh setup
./scripts/dev-macos.sh doctor
./scripts/dev-macos.sh check
./scripts/dev-macos.sh run
```

Windows PowerShell：

```powershell
.\scripts\dev-windows.ps1 setup
.\scripts\dev-windows.ps1 doctor
.\scripts\dev-windows.ps1 analyze
.\scripts\dev-windows.ps1 smoke
.\scripts\dev-windows.ps1 run
```

Docker 安装和环境变量见[部署手册](../deployment.md)，接口与源码启动见[服务端说明](../../apps/server/README.md)。

## 修改和验证

资料规则由 `info_core` 负责，持久化、迁移和加密由 `info_storage` 负责。桌面 App 和独立服务复用这些规则；CLI 不持有用户管理身份。同步的是资料内容及可保留历史，不是可用聊天许可或待审批事项。业务术语见根目录 [GLOSSARY.md](../../GLOSSARY.md)，关键取舍见 [ADR](../adr/)。

- 普通 App 从 `apps/desktop/lib/main.dart` 进入。本地资料库和服务器待办分工见[使用指南](../usage.md)。
- 界面复用共用控件和插件展示，约定见 [UI 指南](ui.md)。`preview_main.dart` 与 sample 数据用于隔离界面检查，不能接入正式保存入口；本机预览不会代替真实功能测试。
- 在各 Dart 包目录运行 `dart analyze --fatal-infos` 和相关 `dart test`；桌面端用 `flutter analyze` 与 `flutter test`。通过平台启动脚本调用固定 SDK。
- `scripts/dev-macos.sh check` 覆盖核心、CLI、存储和桌面端；修改远程协议或服务时，另在 `info_remote`、`info_workspace` 和 `apps/server` 运行对应检查。
- 原生文件面板、系统输入、钥匙串和托盘行为用 `apps/desktop/integration_test/` 与对应隔离 QA 工具检查。合成 SSH / AWS 接收器只在回环地址运行，不需要真实账号。
- CI 为手动选择的平台检查，使用 Actions 额度前按现有 workflow 要求取得预算授权，不因整理文档启动付费 runner。

当前格式和兼容规则见[服务维护](../../apps/server/OPERATIONS.md)、[接口合同](../design/)及[模板插件 JSON Schema](../design/zhiyu-template-package.schema.json)。历史协议和迁移代码仍有兼容用途，不按文件年龄删除。

## 打包与资源

- [Mac 构建与接入](macos-local-setup.md#构建与接入)
- [Windows 打包、安装与清理](windows-delivery.md)
- [Windows 运行包说明](windows-online-delivery.md)及[接入说明](windows-codex-integration.md)
- [联合服务与 Mac 构建工具](../../scripts/package-server-first-stage.py)：固定源码、镜像和客户端交付

品牌资源保存在 `apps/desktop/assets/branding/`，App 顶栏与 Mac 图标使用现有 PNG 尺寸。更新 Windows 图标时运行 `python3 scripts/sync-windows-app-icon.py`，沿用已确认的 PNG，不重新绘制旧图案。

`chiyo-original.png` 保留原始图像，`chiyo-icon.png` 是整理后的透明背景版本；Mac 各尺寸位于 `macos/Runner/Assets.xcassets/AppIcon.appiconset/`。共用控件中的 `prototype_*` 是历史命名，仍被正式页面引用，不是可以直接删除的旧原型。

测试截图、日志、录屏和一次性工具放在 Git 忽略的 `build/`，用完清理。真实资料、密钥、接入文件、个人备份和 SDK 缓存不提交。任务进展及缺陷维护在 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues)，不新增逐次开发流水账。

## 本机生成文件

`.tools/` 保存仍使用的 SDK 和工具，`.cache/pub/` 保存依赖，开发时保留。`.cache/tmp/`、各包的 `build/` 与 `.dart_tool/` 编译输出是可再生成的缓存；任务结束后清理，保留当前依赖配置即可。再次构建按平台启动脚本准备环境。

个人资料、恢复备份、已配置的 CLI 运行目录和要交付的安装包放在仓库外，不以 `local/` 或临时任务目录长期堆在根目录。清理前核对是否仍被进程或已安装配置使用；Git 忽略只表示不提交，不表示文件必须保留。
