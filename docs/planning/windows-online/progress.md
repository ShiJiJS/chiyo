# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-10（Asia/Shanghai）。持续目标已恢复为 active。
- 范围：#108–#116，父任务 #104；#105 后置。没有已完成开发票。
- 分支：codex/windows-online。基线 ac8960c；环境与九票发布归档提交 35690cf。
- 当前票：#108，本机安全保存。已有 WindowsPrivateFiles/DPAPI 草稿，尚未接入调用点、分析或测试，不能报完成。
- 最新授权：直接使用现有 NAS；computer-use 必要时可用；可用现有实际资料验证；允许正常重启知予服务。正式安装和需要用户认证的操作仍最后集中。
- 不扩入 WSL、新服务、密码填充、SSH 密码登录或跨电脑审批。保持旧 Windows 库独立；实际资料验证不等于可永久删除或恢复覆盖原库。

## NAS 接入已验证

- Mac 会话「配置 Mac 开发环境」刚准备的当前连接配置，经一次性 RSA-OAEP 加密交接到 Windows，四字段 address/token/serverId/certificate 完整。没有复制 Mac 设备 Token、聊天 association 或数据库密钥。
- 端点 https://192.168.8.132:47126。Windows 正式 Dart OwnerClient 验证私人 CA、管理 Token 和固定服务器身份成功，读取 42 条普通资料、57 项在用记录（15 项凭据），目录与插件可读。
- 本机配置仅以当前用户 DPAPI 保存在被 Git 排除的 local/private/nas-handoff/owner-profile.dpapi。所在目录禁止继承，只允许当前用户和 SYSTEM。
- 接续访问：运行 local/development/check-nas-production-client.ps1。它解封配置并经 stdin 传给正式客户端，输出仅为计数及核验事实。证据 local/development/nas-access-verification.json；不要输出配置或 Token。
- 首次辅助 Python TLS 探测因 Python 3.13 的严格 AKI 扩展要求拒绝旧证书；没有禁用证书验证，已改用产品实际采用的 Dart TLS 栈验证通过。临时 Python 探测脚本已删除。
- Mac 现有 fnos home-fnos 授权只读检查通过，当前不需用户重新登录。chiyo-server 正在运行，镜像 chiyo-server:sync-106-6e4e0ac0-amd64。重启时可联系原 Mac 会话，由其先核对唯一容器再正常重启；本次没有重启或修改 NAS。不要把只读检查当成重启已测。
- 当前没有需要用户在场的登录条件。正式安装和系统认证仍待最后集中。

## 当前代码与下一步

- 已保留 #108 的核心私有文件草稿：packages/info_core/lib/windows_private_files.dart 及 runtime_material_files.dart 中的 part/句柄校验复用。草稿未验证，不能先发布产品包。
- 下一步先分析并测试 ACL、DPAPI、原子替换和文件占用行为，再接 connection_profile、agent_connection、private_device_state 和 DeviceFileOperations；保留 Mac/Linux 格式及原状态失败规则。
- #108 所有完成条件满足后提交并回填 GitHub，再按依赖继续 #109；当前没有任何开发票可以关闭。
- 九张工单正文、父关系和 13 条前置发布结果见 publication.json；该文件是发布时审计，不代表开发完成。SDK/C++ 与开发入口见 windows-local-setup.md。
