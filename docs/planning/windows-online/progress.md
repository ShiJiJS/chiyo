# Windows 九张工单当前进度

## 当前快照

- 日期：2026-11-10（Asia/Shanghai）。持续目标已恢复为 active。
- 范围：#108–#116，父任务 #104；#105 后置。#108、#109 已完成并关闭，#110 进行中。
- 分支：codex/windows-online。基线 ac8960c；环境与九票发布归档提交 35690cf。
- 当前票：#110，Windows AI 申请、审批和读取。#109 实现 2e86359 已推送并回填/关闭；证据 docs/development/evidence/windows-online/w109.md。#108 实现 f454927。
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
- 正式产品配置已另存到 local/private/windows-appdata/Chiyo/online/，含独立 Windows Agent 设备、设置及注册原操作记录；全部是生产存储格式。不要重新登记设备或抹除原事实。交接用配置仍保留在 nas-handoff/owner-profile.dpapi；一次性交接密文、公私钥已清理。
- #108 对 NAS 只读及正常登记 Windows 设备，没有改资料正文、NAS 设置或重启服务。全包/原生 UI 未由本票声明完成。
- 当前 #109：正式 Windows Release 已在工作目录隔离 APPDATA 下打开并自动连接 NAS，正常界面显示原 57 项、真实目录和资料详情。进程 15320 已经同包控制协议正常退出，未强杀。
- 发现并修复：Windows 搜索仍绑定/显示 Mac Cmd K；阅读模式移除原焦点后快捷键丢失。现在按平台使用 Ctrl K / Cmd K，并在阅读切换后恢复工作区焦点。macOS/Windows、保存/取消的四个快捷键场景和其余同文件回归共 7 项通过；桌面 fatal-infos 分析通过。
- CU 输入诊断：普通按键可进入输入法候选，sky.type_text 未产生可确认的完整文字；Flutter UIA SetValue 返回 E_FAIL。未据此断言软件不能输入，也未把真实表单保存算通过。未保存诊断表单已正常关闭，无 NAS 资料变化。
- #109 已完成：仅新增并修改《Windows 知予接入说明》，原资料未改。当前 43 条普通资料和 15 项凭据，共 58 项。真实 NAS 中文表单/搜索/目录标签关联/重开/丢失回执原编号查询两次通过；串行检查 28 项通过，提案和顺序 3 项通过（Mac 原生排序 3 项跳过），扩充已连接 App 断网/恢复检查单独通过。
- #109 恢复修补：原回执查询未刷新内存资料投影，已补与正常保存相同的只读同步；查询失败继续保留未知结果，不重放保存。连接页错误 Token、陌生 CA、错误固定服务器身份、不可达端点及改回原地址重连已通过一次。新增显式真实 NAS 检查不在默认测试中自动接入私人资料。
- #109 修复版构建通过；原生主入口 PID 17736 显示真实 58 项和新文档/关联，控制 CLI 正常退出，登记状态 exited。Sky 原生 Ctrl K/文字注入结果未确认，已明确加入 #116 的同版本桌面条件，不能当成通过。
- 下一步 #110：按 Windows manifest 识别同包 CLI/Skill，补齐引用并构建最新 AOT 工具；使用新建、隔离的验证聊天身份对现有 NAS 检查申请/审批/限定读取及失效，不搜索本聊天丢失的 association、不改全局 hooks。
- #110 当前：Windows 同包观察器与四份引用打包已实现，6 项包检查和两包分析通过；真实 AOT 会话/hook 9 项、桌面观察/状态回归 27 项通过。当前 App 已退出。
- #110 真实 NAS：全新隔离验证身份完成申请、等待原编号、仅批准字段读取、未批准字段/无关聊天拒绝、子身份共享范围、主人能力隔离；原 NAS 正常重启一次后根/子继续读取且截止时间不变；撤销与根结束后拒绝。首次结束未及时确认，只沿原 end-only 凭证接续，最终 completed。见 docs/development/evidence/windows-online/w110.md。
- #110 待办：同提交实际 App/CLI 载荷包识别与损坏负向检查；尚未关闭，不把合成文件检查替代实际载荷。私有验证流程已完成，资料引用仅保存在本票私有检查目录，未改全局 hooks 或本聊天 association。
- 辅助测试尝试：现有 remote_settings_test 的本机服务器夹具受 POSIX secrets 和 /bin/chmod 限制。临时 Windows 测试夹具改动已撤回；没有修改生产服务平台边界，失败不计通过。测试失败时创建的隔离 Temp 合成夹具未做宽泛前缀清理。
- 旧 POSIX 权限用例在 Windows 按平台跳过；未冒充已在 Mac/Linux 机器重跑其原生检查。此前 UI 服务器集成夹具依赖 POSIX 服务密钥，后续要适配测试装配而不放宽生产服务密钥边界。
- 九张工单父关系和 13 条前置的发布核对见 publication.json；SDK/C++ 与开发入口见 windows-local-setup.md。#104 和 #110–#116 仍开放。
