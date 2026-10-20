# Mac 本机开发环境

本页保留环境准备阶段的历史检查点；2026-10-20起的分支、代码适配与当前验证状态见 [Mac 适配记录](macos-runtime-adaptation.md)。

本机目录为 `/Users/jiangxinyi/Documents/Project/agent-info`。2026-10-18 从
`git@github.com:ShiJiJS/agent-info-manage.git` 拉取，使用本机已有 SSH 认证。
`main` 当前只有早期规格；本机 `codex/macos-development` 分支从已提交的
`origin/codex/round05-windows-sync` / `916fd2a24b6f909113741a7344bca49eb633f72c`
建立。Windows 尚未提交或推送的更改不在此副本中。

2026-10-19 本机分支已快进到 Windows 当时已推送的
`9af7a8d16bf82e8c7cb683143982bbc8f5e67da8`，保留本机环境文件的更改。
Windows 正在继续 #38 附件审批与历史界面；本次固定在上述提交验证，不修改或推送
Windows 分支，也不修改 `packages/`、共享界面或 Windows 原生实现。

## 目录与命令

- `.tools/flutter`：官方 Flutter 3.47.7，固定提交
  `abaf9c523780a608bd46686fd5e53740a07077f8`，包含 Dart 3.13.5。
- `.cache/pub`：本项目的 Dart/Flutter 依赖缓存。
- `.cache/tmp`：启动脚本使用的本机临时目录，采用解析符号链接后的绝对路径。
- `apps/desktop`：Flutter 界面与 macOS/Windows 原生工程。
- `packages/info_core`、`packages/info_cli`、`packages/info_storage`：核心、CLI 与加密存储。
- `build/macos-development`：本机准备与验证日志。

SDK、缓存通过 `.git/info/exclude` 在本机排除；启动脚本不会修改全局 PATH。
SDK 使用固定 Git 提交安装，显示 `channel [user-branch]` 不影响版本匹配。
依赖安装使用 `--enforce-lockfile`，不会为了安装环境升级项目依赖。

在仓库根目录执行：

```bash
./scripts/dev-macos.sh setup
./scripts/dev-macos.sh doctor
./scripts/dev-macos.sh check
./scripts/dev-macos.sh build
./scripts/dev-macos.sh run
```

`check` 运行三个 Dart 包的静态分析与测试，以及桌面端静态分析与 widget 测试；
每个模块失败后继续检查其余模块，最终返回失败状态，不会启动桌面窗口。
`build` 编译 macOS release，`run` 启动可见的调试窗口。
`flutter`、`dart` 子命令可在当前工作目录调用本项目 SDK，例如：

```bash
cd packages/info_core
../../scripts/dev-macos.sh dart test
```

## 完整 Xcode

机器为 Apple Silicon / macOS 27.0.1。2026-10-18 首次准备时只有 Apple Command Line Tools，
`xcode-select -p` 指向 `/Library/Developer/CommandLineTools`，`xcodebuild -version` 失败。
在新机器上准备完整 Xcode 的步骤如下：

1. 从 Mac App Store 安装 Xcode，打开并完成首次初始化及系统要求的组件安装。
2. 如开发者目录仍指向命令行工具，在终端执行：

   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```

3. 重新执行 `doctor`、`build`、`run`。这些步骤可能要求本机管理员验证或 Apple 账号。

启动脚本会在 `/Applications/Xcode.app` 存在时为本项目设置 `DEVELOPER_DIR`，
无需为选择工具链修改系统设置；调用者显式设置的 `DEVELOPER_DIR` 优先。

2026-10-19 已通过本机 App Store 安装 Xcode 27.1（27A9275）到标准目录。
用户已自行接受 `Xcode and Apple SDKs Agreement`，随后使用 computer use 完成欢迎流程；
External Agent Access 选择 `Never`，当前 Flutter/终端开发无需 Xcode 内部的外部 Agent 接口，
以后可在 Settings > Intelligence 修改。首次启动状态检查已返回 0，系统开发者目录也已指向
`/Applications/Xcode.app/Contents/Developer`，macOS 27.0 SDK 可用。
`doctor-after-xcode.log` 中模拟器和 CocoaPods 的提示仍存在，本项目没有相应插件或移动端运行要求，
此次不额外下载移动设备模拟器；桌面构建结果单独记录。

当前工程没有 CocoaPods 插件依赖或 Podfile，不为本次环境准备额外安装 Ruby/CocoaPods。
Flutter doctor 中与其他目标平台有关的缺项不影响本项目的 macOS 开发；具体构建错误应单独处理。

## 2026-10-18 本机验证

SDK 与所有顶层包的锁定依赖安装成功，四个模块静态分析全部通过。
统一检查在核心测试失败后停止，随后分别运行其余包的分析与测试，未跳过失败用例。

| 检查 | 通过 | 跳过 | 失败 | 日志 |
| --- | ---: | ---: | ---: | --- |
| info_core | 125 | 4 | 1 | `build/macos-development/check.log` |
| info_cli | 26 | 26 | 4 | `build/macos-development/cli-test.log` |
| info_storage | 55 | 6 | 0 | `build/macos-development/storage-test.log` |
| desktop widget | 101 | 1 | 2 | `build/macos-development/desktop-test.log` |
| ARM64 AOT Codex 子进程 | 7 | 0 | 0 | `build/macos-development/aot-codex-test.log` |

这些结果是当前提交在这台 Mac 上的基线，不能作为完整 Mac 版本已通过的结论。
跳过数为原有测试条件产生。七项失败集中在凭据执行相关路径：

- `packages/info_core/test/credential_use_test.dart`：执行回报重试测试强制解引用进程身份，
  `CredentialProcessIdentity.capture` 当前没有 macOS 分支，因此返回 null。
- `packages/info_cli/test/runtime_json_lines_test.dart`：预期 `session_mismatch`，
  Mac 默认执行路径提前返回 `unsupported_tool_version`。
- `packages/info_cli/test/credential_runtime_test.dart`：消费响应丢失、运行审计失败后继续监控、
  实际 Token 子进程回报三项失败，分别为断言不符、超时、实际状态 `unknown`。
- `apps/desktop/test/credential_use_widget_test.dart`：同样缺少 macOS 进程身份。
- `apps/desktop/test/file_credential_approval_test.dart`：AWS 文件使用准备失败；
  当前 `ManagedCredentialFiles` 明确只支持 Windows。

以上为环境准备中发现的现有适配缺口，本次没有修改业务实现或测试来掩盖失败。

`build/codex-macos-preview` 中三个程序均已编译为 Mach-O ARM64，
`build/macos-development/info` 为另行编译的通用 CLI。
编译后的 Codex 子进程测试通过，仅代表受控适配器测试，未进行真实聊天或 hook 安装。
`doctor.log` 记录完整工具链状态，`build.log` 记录构建入口因缺少完整 Xcode 拒绝继续；
本次没有成功编译或启动 Flutter macOS 应用。

## 2026-10-19 自动检查基线

日志位于 `build/macos-development/2026-10-19`。依赖仍按锁文件安装，四包严格静态分析均通过。
第一次全量检查中，存储测试有 25 项额外失败，原因是默认 `/var` 临时路径解析后成为
`/private/var`，不满足测试清理前的路径一致性保护。改为项目内规范化 `TMPDIR` 后，
完整复验存储包，保留原有安全检查，结果如下：

| 模块 | 通过 | 跳过 | 失败 |
| --- | ---: | ---: | ---: |
| info_core | 238 | 15 | 7 |
| info_cli | 52 | 40 | 10 |
| info_storage（规范化临时目录） | 135 | 12 | 12 |
| desktop widget | 140 | 2 | 5 |
| 编译后 ARM64 Codex 子进程 | 7 | 0 | 0 |

原始全量输出为 `check.log`，存储复验为 `storage-canonical-tmp.log`；
没有为了通过检查跳过失败用例或修改共享业务实现。
核心及 CLI 失败涉及进程身份、凭据文件、可复用执行和非 Windows 接收路径。
存储剩余 12 项均在 `information_delivery_storage_test.dart`，调用 Windows 文件交付实现。
桌面端失败为 Windows 焦点填充包的三项检查、进程身份和 AWS 文件材料各一项。

新编译的 CLI/hook 材料在 `build/macos-development/2026-10-19/codex`；
受控 AOT 子进程测试的 7 项通过不代表真实 Codex hook 已安装或验收。

## 2026-10-19 原生编译与开发循环

安装和初始化完整 Xcode 后，实际完成以下检查：

- `./scripts/dev-macos.sh build` 成功，产物为
  `apps/desktop/build/macos/Build/Products/Release/info_desktop.app`（Flutter 报告 68.9 MB）。
  原生可执行文件包含 ARM64 和 x86_64，为本机 ad-hoc 签名；不代表发行签名或公证完成。
- 通过 computer use 打开 Release 应用，访问审批、空信息库和设置页面均能显示。
  “应用运行”显示本机服务已连接、托盘可用，系统实际监听 `127.0.0.1:47125`。
- 使用应用的退出流程结束 Release 后，进程及 47125 监听消失。
- `./scripts/dev-macos.sh run --no-pub` 成功编译 Debug，Dart VM 调试服务建立。
  Flutter 曾报告无法自动将窗口置前，使用 computer use 打开已运行的 Debug 窗口后显示正常；
  核实实际进程来自 Debug 目录，复用同一个本机资料库并监听 47125。
- 向 Flutter 调试终端发送 `r`，返回 `Reloaded 0 libraries in 152ms`；
  没有修改源文件，验证编译、调试连接与热重载流程。之后用 `q` 结束测试进程。

本次启动只产生空信息库，没有导入真实资料。运行数据按 macOS sandbox 放在
`~/Library/Containers/com.example.infoDesktop/Data/Library/Application Support/AgentInfoManage`；
数据库密钥由现有系统钥匙串桥接保管，未读取或导出。读取数据库前 16 字节仅核对其不是
明文 SQLite 文件头，不输出字节内容；这项检查不能替代完整加密及备份验收。

原始记录为 `macos-release-build.log`、`debug-run.log` 和 `doctor-after-xcode.log`。
编译保留了现有 Swift 弃用警告与 Xcode 构建阶段提示，没有为了消除警告改动原生实现。
完整 Xcode 已可用于本机开发；34 项平台相关测试失败、真实通知、文件选择器、
凭据执行/焦点填充/附件交付移植、Codex 实际接入与发行验收仍需后续处理。

## CLI 与 Codex

以下命令仅生成可审查的本机 CLI/hook 材料；目标目录必须不存在：

```bash
./scripts/dev-macos.sh bundle build/codex-macos-preview
```

生成本地二进制不等于安装接入。环境准备不修改用户 `.codex`、不安装或信任 hook，
也不迁移真实信息库。实际接入流程见 [Codex 接入开发预览](../../integrations/codex/README.md)。

## 环境准备阶段的后续工作（历史）

以下为准备阶段记录；当前实现和未完成门槛以 [主分支整合记录](macos-main-integration.md)、
[Mac 适配记录](macos-runtime-adaptation.md) 及 GitHub #41–#50 为准。

macOS 工程已有钥匙串、菜单栏、通知、文件面板及退出流程的原生桥接。
这些代码仍需完整 Xcode 编译和本机 UI 验证，尤其是应用身份、sandbox、系统通知权限、
升级后的钥匙串访问及备份恢复。

当前凭据执行宿主与默认运行适配器仍含 Windows 专用实现，非 Windows 默认路径会返回
`unsupported_tool_version`。SDK 和普通 Dart 测试可用不代表这项能力已完成 Mac 移植。
签名、公证、独立设备安装以及真实 Codex 生命周期验收也应分别记录。

继续 Windows 的更改前先执行 `git fetch origin`，检查相关提交，再合并到本机分支；
不要用 Windows 的 `.dart_tool`、SDK、构建产物或本机数据库覆盖 Mac 副本。
