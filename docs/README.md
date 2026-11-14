# 文档导航

[项目首页](../README.md) · [English overview](../README.en.md)

## 安装和使用

| 文档 | 内容 |
| --- | --- |
| [安装与部署](deployment.md) · [English](deployment.en.md) | Mac / Windows 安装、本地模式、Docker、证书与服务器连接 |
| [使用指南](usage.md) | 资料、目录、提案、密码填写、审批、同步和备份 |
| [跨应用填写机制图解](explainers/credential-filling/README.md) | Agent 怎样定位密码框、申请使用密码，以及浏览器和 Mac／Windows 原生应用怎样执行填写；含可在本机浏览器打开的交互页面 |
| [服务器维护](../apps/server/OPERATIONS.md) | 升级、停机备份、迁移、恢复与回退 |
| [AI 接入](../integrations/codex/README.md) | 配套 CLI、Skill 和聊天接入；链接同版本平台说明 |
| [CLI 命令](cli.md) | 查询模板、提交提案、请求与获准使用 |

## 开发

| 文档 | 内容 |
| --- | --- |
| [开发入口与仓库结构](development/README.md) | 模块职责、构建、测试及开发资料入口 |
| [Mac 开发](development/macos-local-setup.md) | 固定 Flutter / Dart、Xcode、运行和打包 |
| [Windows 开发](development/windows-local-setup.md) | C++ 工具链、加密本地库、联网和构建 |
| [Windows 交付](development/windows-delivery.md) | 打包、安装及产物清理 |
| [原生后台填写设计](design/native-background-fill-contract.md) | Mac AX / Windows UIA 按控件能力填写、目标身份与授权、错误处理及兼容迁移；区分目标设计与当前实现 |
| [界面约定](development/ui.md) | 共用控件、插件展示、浮层、输入与界面验证 |
| [服务接口](../apps/server/README.md) | HTTPS、用户与 Agent 接口、同步和运行约束 |

[领域术语](../GLOSSARY.md)和[架构决策](adr/)记录业务含义及关键取舍；[接口合同](design/)保留仍被代码和兼容流程使用的协议、存储与模板格式。任务状态与缺陷在 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 维护。
