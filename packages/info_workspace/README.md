# 共享工作区契约

从桌面端抽出的纯 Dart 数据契约和可信用户审批适配，不依赖 Flutter。原桌面 import 路径保留 re-export，已有界面继续使用同一类型和校验规则。

OwnerWorkspaceApprovals 只接收可信 OwnerAccess，复用核心的审批事务、版本核查、回执和历史。服务端在用户认证后调用；Agent 设备接入不能取得这个对象。RemoteWorkspaceApprovals 只负责经 HTTPS 传输，不再复制审批业务判断。

approval_transport.dart 传输工作区审批的元数据、范围和决定，不包含字段正文、会话私密证明或读取 token。当前只接文字/普通文件范围的结构；凭据和执行结果遇到尚未接通的情况会明确失败，后续按 #97/#99 补齐，不静默丢弃混合范围。

此包不创建资料库，不启动服务，不执行本机命令，也不安装或信任 hooks。原审批/附件/执行/工作区回归仍在 apps/desktop/test；独立 HTTPS 验证位于 apps/server/test/owner_approvals_test.dart。
