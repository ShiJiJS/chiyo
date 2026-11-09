# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-10（Asia/Shanghai）。持续目标已恢复为 active。
- 范围：#108–#116，父任务 #104；#105 后置。#108 已完成并关闭，#109 进行中。
- 分支：codex/windows-online。基线 ac8960c；环境与九票发布归档提交 35690cf。
- 当前票：#109，Windows App 正常连接和资料管理。#108 实现 f454927 已推送并回填/关闭；逐项证据 docs/development/evidence/windows-online/w108.md。
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

- #108：管理/Agent 配置、控制事实、SQLCipher 设备库已接入 Windows ACL + DPAPI；四包 fatal-infos 分析、定向检查、AOT 并发及 NAS 独立进程重开通过。
- 正式产品配置已另存到 local/private/windows-online/，含独立 Windows Agent 设备、设置及注册原操作记录；全部是生产存储格式。不要重新登记设备或抹除原事实。交接用配置仍保留在 nas-handoff/owner-profile.dpapi；一次性交接密文、公私钥已清理。
- #108 对 NAS 只读及正常登记 Windows 设备，没有改资料正文、NAS 设置或重启服务。全包/原生 UI 未由本票声明完成。
- 当前 #109：读取 GitHub 正文及评论完成。下一步用当前源码构建 Windows Release，启动工作目录内隔离配置，使用 computer-use 检查正常 App 入口与现有资料、保存及重开。
- 旧 POSIX 权限用例在 Windows 按平台跳过；未冒充已在 Mac/Linux 机器重跑其原生检查。此前 UI 服务器集成夹具依赖 POSIX 服务密钥，后续要适配测试装配而不放宽生产服务密钥边界。
- 九张工单父关系和 13 条前置的发布核对见 publication.json；SDK/C++ 与开发入口见 windows-local-setup.md。#104 和 #109–#116 仍开放。
