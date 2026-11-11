# 知予桌面客户端

Flutter macOS/Windows 客户端。资料可加密保存在本机，连接自己的 HTTPS 服务作为可选同步方式；已有服务器模式保留。资料、提案和授权规则由共享 Dart 包实现。

本地库使用独立存储密钥。本机 AI 的申请和审批不依赖服务器在线，也不从服务器复制其他聊天的有效许可。设置中的「存储与同步」管理连接；关闭同步只停止传输，不删除任何一端资料。首次同步与后续变化的处理规则见 [资料同步决定](../../docs/adr/0028-local-library-replication.md)。

- [Mac 开发](../../docs/development/macos-local-setup.md)
- [Windows 开发](../../docs/development/windows-local-setup.md)
- [服务部署与维护](../server/OPERATIONS.md)
- [产品规格](../../docs/specs/0001-local-information-access.md)
