<h1 align="center">知予 · chiyo</h1>
<p align="center"><img src="apps/desktop/assets/branding/chiyo-icon.png" alt="知予图标" width="160" /></p>
<p align="center">把资料交给知予，让 AI 按需申请，由你决定。</p>
<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
<p align="center"><a href="https://github.com/ShiJiJS/chiyo/releases">下载</a> · <a href="docs/deployment.md">安装与部署</a> · <a href="docs/usage.md">使用指南</a> · <a href="docs/README.md">文档</a> · <a href="https://github.com/ShiJiJS/chiyo/issues">反馈</a></p>

知予是一个面向个人的**资料管理与 AI 访问审批工具**。把文档、个人档案、服务器信息和账号凭据整理在一起；AI 需要内容时提出申请，你在 App 中查看用途、选择范围并批准。

你也可以把几个文件交给 AI，让它按现有模板整理成录入提案。新增看完整内容，修改看前后变化；需要你填写的密码就在提案中输入，确认后整份保存。

## 能做什么

- **整理资料**：目录、标签、关联、拖动移动和批量回收；支持 Markdown、图片、PDF、普通附件及历史版本。
- **管理凭据**：按账号保存密码、Token 和密钥文件，关联对应的服务器或应用；获准后由 AI 所在电脑的程序使用。
- **审批申请**：核对 AI 的用途、聊天来源、字段或文件范围及期限，查看授权和使用记录，撤销后续访问。
- **本地使用或连接 NAS**：本机独立运行，也可以与自己部署的服务器同步资料；有冲突时保留双方内容，供你选择。
- **备份与扩展**：完整加密备份、独立恢复密钥，以及提供字段、填写说明和示例的模板插件。

## 开始使用

1. 从 [Releases](https://github.com/ShiJiJS/chiyo/releases) 获取对应平台的开发包，按[安装手册](docs/deployment.md)启动 App。
2. 首次打开选择「本地使用」或「服务器同步」。连接服务器只需填写 IP 或域名、端口，再按提示设置或输入知予连接密码；证书自动配置。
3. 手动添加资料，或按同版本接入说明让 AI 使用随包的 CLI 和 Skill 提交提案。
4. 在 App 中核对提案、补填密码；AI 申请使用资料时，到「访问审批」处理。

源码支持 **macOS 14+ / Apple Silicon** 和 **Windows x64**。当前为开发预览：发布页目前提供较早的 Mac 包，Windows 适配和最新功能已合入 `main`，可按[开发指南](docs/development/README.md)构建。下载包的实际版本和平台以附件及其 manifest 为准。

### 两种模式

| | 本地模式 | 服务器同步 |
| --- | --- | --- |
| 资料 | 加密保存在本机 | 本机加密副本与 NAS 同步 |
| 申请、提案和审批 | 由本机服务处理，App 需要运行 | 由 NAS 接收，在 App 中审批 |
| 网络 | 不依赖 NAS | 同步和服务器审批需要连接 NAS |

切换模式不会把旧申请搬到另一处，也不会复制可用的聊天许可。新聊天使用当前模式；已有聊天保留原来的连接，切回相应模式可以处理原申请。详见[使用指南](docs/usage.md)。

## App、CLI、Skill 和服务器

| 部分 | 用来做什么 |
| --- | --- |
| **App** | 管理资料、核对录入提案、审批申请、查看历史 |
| **CLI** | AI 查询资料目录和动态模板、提交提案及访问申请、在获准范围内使用资料 |
| **Skill** | 配套使用说明，指导 AI 如何调用 CLI；具体模板和示例从当前运行的软件查询 |
| **服务器** | 可选，Docker 自行部署到 NAS 或 Linux 主机，保存同步资料并持续接收申请 |

CLI 与 Skill 随开发包提供，接入步骤见[AI 接入说明](integrations/codex/README.md)。Skill 不替代审批，Agent 的设备接入凭证也没有用户的管理权限。

## 数据保存

资料使用 SQLCipher 加密。本机数据库密钥由 macOS 钥匙串或 Windows DPAPI 保护；服务器使用独立持久保存的密钥。服务器具有解密能力，应部署在你信任的设备上。

备份文件与恢复密钥分开保管；升级、迁移和恢复步骤见[部署手册](docs/deployment.md)及[维护说明](apps/server/OPERATIONS.md)。

## 文档与开发

- [安装、Docker 部署与连接](docs/deployment.md) · [English](docs/deployment.en.md)
- [资料、提案、审批和同步的使用方式](docs/usage.md)
- [AI / Codex 接入](integrations/codex/README.md) · [CLI 命令](docs/cli.md)
- [开发入口与仓库结构](docs/development/README.md) · [完整文档导航](docs/README.md)

欢迎通过 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 反馈问题或提出需求。
