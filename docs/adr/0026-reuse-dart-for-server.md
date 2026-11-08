---
status: accepted
---
# 优先复用 Dart 核心构建独立服务端

2026-11-08，用户在了解现有主体代码可复用及仍需改造的部分后，确认按 Dart 路线形成方案。多设备服务优先复用现有 Dart 领域核心与 SQLCipher 存储，新增无界面 Linux 服务入口及 Docker 部署；客户端继续使用 Flutter，设备端的 CLI 和执行程序继续保留。本记录确认技术方向，工单拆分另行审阅，不代表服务端已实现或 Linux 已验证。

现有 `packages/info_core` 与 `packages/info_storage` 没有 Flutter 依赖，资料模型、提案整体保存、授权核查、版本、历史及存储事务具备复用基础。相比 [ADR0003](0003-flutter-and-dart-local-stack.md) 中曾优先考虑的 Spring Boot，这条路线减少领域规则和存储行为的跨语言移植及重复验证；代价是后续服务端继续以 Dart 维护，而非采用用户原先更熟悉的 Java 技术栈。数据库优先保留当前加密 SQLite 方案，先验证单用户集中访问需求，不为抽出服务额外更换数据库。

复用不等于只开放现有端口。当前 HTTP 仅供 Agent 本机接入，App 直接调用 `OwnerAccess`；需分别补受认证的用户管理接口和 Agent 接口，并让 App 在既有 `WorkspaceSource` 接口处接入远程数据。还需替换本机系统密钥保管、验证 Linux SQLCipher、增加文件实际传输、变更提醒及重启后有效授权的恢复。SSH、密码填充和本机文件清理留在 AI 所在设备，不迁到服务器执行。

实施前先用合成资料验证独立 Linux 宿主的建库、重开、加密备份恢复与基本 API，再展开客户端改造；不得把静态代码复用判断当成 Docker 运行已经通过，也不直接开放现有仅限回环地址的接口处理真实资料。
