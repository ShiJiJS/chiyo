<h1 align="center">知予 · chiyo</h1>

<p align="center">
  <img src="apps/desktop/assets/branding/chiyo-icon.png" alt="知予图标" width="220" />
</p>

<p align="center">把资料交给知予，让 AI 按需申请，由你决定。</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-171D35?style=for-the-badge&logo=apple&logoColor=white" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple_Silicon-arm64-69548C?style=for-the-badge" />
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.47.7-02569B?style=for-the-badge&logo=flutter" />
  <img alt="Dart" src="https://img.shields.io/badge/Dart-3.13.5-0175C2?style=for-the-badge&logo=dart" />
</p>

<p align="center">
  <a href="https://github.com/ShiJiJS/chiyo/releases/tag/v0.4.2-mac-preview">下载 Mac 预览版</a> ·
  <a href="#开始使用">开始使用</a> ·
  <a href="#能做什么">能做什么</a> ·
  <a href="https://github.com/ShiJiJS/chiyo/issues">反馈问题</a> ·
  <a href="#本机开发">本机开发</a>
</p>

---

知予是一个本地资料管理与 AI 授权工具。你把文档、服务器信息、服务账号等保存在 App 里，AI 可以帮你整理并提交录入提案。需要使用资料时，AI 再提出申请，你在 App 中查看用途、选择范围并批准。

**当前仅支持 macOS Apple Silicon，最低系统要求 macOS 14。** 当前为开发预览，日常开发和打包以 Mac 为主，Windows 适配后续安排。

## 能做什么

- **保存资料**。按目录、标签和模板整理信息，查看 Markdown、图片、PDF 与文件历史版本。
- **核对 AI 整理的内容**。新增看完整预览，修改看前后变化。一份提案检查齐全后一次保存。
- **管理账号和凭据**。登录密码可在提案里直接填写，支持显示与隐藏。Token 和密钥文件使用对应凭据模板保存。
- **审批 AI 的申请**。查看申请用途、资料范围和有效期，批准后可查看使用记录并撤销授权。
- **备份与恢复**。导出加密备份，使用单独保管的恢复密钥恢复资料。
- **扩展资料格式**。通过模板插件提供新的字段、填写例子和展示方式，AI 从运行中的 App 查询当前模板。

资料使用 SQLCipher 加密保存在这台 Mac 上，数据库密钥由系统钥匙串保管。本机服务随 App 运行，通过 CLI 为 AI 提供受控接口。当前使用流程不需要部署云端服务器。

开发预览使用本机签名，尚未公证。更新后 macOS 可能要求重新允许读取钥匙串；系统密码需要用户本人输入。

## 开始使用

1. 打开 Mac 安装映像，将 `chiyo.app` 拖到「应用程序」，然后启动「知予」。已经安装时，先通过应用菜单或 ⌘Q 退出旧版。
2. 在 App 中添加资料，或让 AI 根据你提供的文件提交录入提案。
3. 如果提案需要登录密码，在对应账号旁填写。检查各项预览，点一次「保存整份提案」。
4. AI 需要读取资料或使用凭据时，在「访问审批」中查看并处理申请。

红色关闭按钮会保留后台服务，⌘Q 会完全退出。已有资料的升级沿用原来的数据库和钥匙串标识。

### 让 AI 接入

运行中的 App、CLI 与 `agent-info-access` Skill 配合使用。Skill 说明如何查询模板、提交提案、申请资料及查看处理结果，CLI 负责与 App 通信。模板与例子来自 App 当前安装的插件。

在 App 的「设置 → Agent 接入」查看接入说明和诊断。首次接入 Codex 需要按说明配置会话连接；仅打开 App 尚不足以为任意聊天建立连接。已有连接的聊天按 Skill 使用。

详细步骤见 [Mac 接入说明](integrations/codex/MACOS-INTEGRATION.md)。

## 本机开发

需要 Apple Silicon Mac、完整 Xcode 和 Git。项目使用固定版本 Flutter 与 Dart，SDK 和缓存放在本机工作区。

```sh
git clone git@github.com:ShiJiJS/chiyo.git
cd chiyo
./scripts/dev-macos.sh setup
./scripts/dev-macos.sh doctor
./scripts/dev-macos.sh check
./scripts/dev-macos.sh run
```

构建当前提交的 Mac 包需要干净的 Git 工作区。

```sh
python3 scripts/qa/package-macos-isolated.py build/macos-adaptation/my-release
```

构建器核对 App 签名、配套 CLI、加密存储和解包后的文件。通过源码或打包检查不等于已经完成所有系统交互验收；具体任务状态见 GitHub Issues。

### 代码结构

| 位置 | 内容 |
| --- | --- |
| `apps/desktop` | Flutter App、Mac 界面和平台接入 |
| `packages/info_core` | 资料、提案、授权及模板规则 |
| `packages/info_storage` | 加密存储、系统密钥接口和备份 |
| `packages/info_cli` | AI 使用的 CLI 与会话接入 |
| `integrations/codex` | Skill 模板和接入说明 |
| `apps/desktop/macos` | Mac 原生窗口、通知、文件选择与钥匙串 |
| `apps/desktop/windows` | 保留的 Windows 原生适配 |

Windows 的资料库启动代码位于 `apps/desktop/lib/platform/windows_library.dart`。系统凭据执行、文件操作和密钥保管分别通过已有平台实现接入，共享业务规则保持在 Dart 包中。

## 文档

- [Mac 本机开发环境](docs/development/macos-local-setup.md)
- [Windows 本机开发环境](docs/development/windows-local-setup.md)
- [服务部署与维护](apps/server/OPERATIONS.md)
- [产品规格](docs/specs/0001-local-information-access.md)
- [领域术语](GLOSSARY.md)与[架构决策](docs/adr/)
- [图标原图与应用图标](apps/desktop/assets/branding/README.md)

欢迎在 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 反馈遇到的问题。
