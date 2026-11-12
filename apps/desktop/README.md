# 知予桌面客户端

Flutter macOS / Windows App，负责信息库、录入提案、访问审批、授权历史和设置。资料可加密保存在本机，也可与自托管服务器同步。

本地模式由本机服务处理申请；服务器同步模式浏览本机资料副本，但待办和审批来自 NAS。切换模式不搬运申请或复制聊天许可。业务规则由共享 Dart 包实现，平台接口分别位于 `macos/` 和 `windows/`。

- [安装与部署](../../docs/deployment.md) · [使用指南](../../docs/usage.md)
- [仓库结构与开发](../../docs/development/README.md) · [界面约定](../../docs/development/ui.md)
- [Mac 开发](../../docs/development/macos-local-setup.md) · [Windows 开发](../../docs/development/windows-local-setup.md)
- [AI 接入](../../integrations/codex/README.md) · [服务维护](../server/OPERATIONS.md)
