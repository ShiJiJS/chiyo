# 当前普通包的 GH 联合复验与 #44 条件核对

2026-10-23，#44/#50。继续使用固定 package23、产品 `7b19d34b61cf`，
生产 Keychain、原资料库、沙盒和 App 路径保持。此前同包的
[AWS／目录权限／文件](macos-final-ordinary-tools.md)和
[SSH／主机记录／私钥](macos-final-ordinary-ssh.md)分别保留来源。
没有换入候选24，没有新增钥匙串动作，也没有操作 Windows/main/CI。

## 实际 GH、拒绝及重开

通过真实原生安全输入表单新增一份专用无效合成 Token；安全字段仍为遮蔽值，
外层显示“已填写”。真实 GUI 批准15分钟，确认框列出随包 GH 的完整位置、
独立配置、环境变量接收及禁止交互登录。公开 AgentClient 采用 App-hosted 执行，
驱动由开发 SDK 编译，不能称作随包独立客户端。

| 场景 | 实际结果 |
| --- | --- |
| 随包 GH2.102.0 `api user` | 实际退出1，GitHub HTTP401／Bad credentials；不算成功认证。 |
| 仅把工作目录改为未选择的容器外合成目录 | start_failed／process_start_failed，processStarted=false，无退出码、无输出。没有具体 OS errno，不进一步归因。 |
| 将程序换成开发目录的同版本官方 GH | 原许可下新操作及单独新申请均 invalid_plan，operationClaimed=false；新申请指出 launch.executable。没有登记新操作，不算执行了外部 GH。 |
| 重交首次操作 ID | 同一 executionId、duplicate=true；前后授权决定、操作数2和固定截止完全一致。没有 GitHub 服务端请求计数，不作独立服务端次数承诺。 |
| 真实 GUI 撤销后提交新操作 | grant_revoked、operationClaimed=false。 |

共两个登记操作、一次实际 GH 目标启动；两个终态均为 cleanup=not_needed，
不是 complete。公开日志与解码后的输出检查不含合成秘密原文。
外部 GH 在普通 App 检查程序位置时不可用；源代码检查器会将解析、stat、版本探测
或读文件异常统一转成 invalid_plan。因此不把该结果写成已证明某一 OS 错误、
“固定程序绑定”或协议允许列表限制。外部程序在代理自身进程中确为 GH2.102.0，
这也不代表沙盒 App 能访问它。

独立只读采样捕获 App6826 → 随包 worker7394 → 随包 GH7396，
目标参数为 `api user`，与版本探测分开。没有读取进程环境或凭据。

实际撤销、确认停用新合成凭据、关闭发现并保存后，App6826 经应用菜单正常退出0，
端口关闭；同一普通包7539在最小环境独立重开，无新增系统提示。旧客户端 status
被拒绝，旧执行查询 session_required，公开凭据目录为空。GUI历史总数26，
本轮记录仍是版本1、两次操作、已撤销、固定截止03:22:11；退出1和启动失败分别
保持，显示“无需文件清理”。原两条信息、` 777`及1024字节附件v1再次核对保持。

随包 AOT CLI 在仅系统 PATH、工作目录 `/` 下执行 capabilities/catalog/
credential-catalog，三项均 ok、退出0。五个相关载荷的字节和模式匹配 package23
manifest，deep/strict签名退出0；本轮没有重复声称重查了全部7,971项，完整检查
保留在紧前的 SSH 证据。临时驱动收到 qa-close 后句柄消失，进程清单也已无它；
工具未返回驱动退出码，因此记录为未知，不能补写成退出0。驱动二进制和空的
未选择目录已删除，保留普通 App、加密原资料及恢复材料。

## #44 第2、6项的证据映射

第2项要求沙盒宿主实际启动已声明版本的 SSH/GH/AWS，并核对程序位置、工作目录、
读写授权、不足权限和环境独立性。同一普通 package23 的三份记录现在补齐：

- AWS2.38.1：14个实际启动操作；未授权读取/写入、只读/读写目录、独立重开恢复、
  移除后拒绝分别核对，真实 NSOpenPanel 选择与生产书签生效。
- 系统 OpenSSH10.3p1：七个登记操作、六次实际启动；严格主机检查、正确/错误私钥、
  无授权外部 cwd、实际 App→worker→SSH 及材料权限/清理分别留证。
- GH2.102.0：本轮实际随包目标及进程链、外部程序检查拒绝、外部 cwd 启动失败。
  GH成功认证归第3项，未用401替代。三者均未关闭沙盒、未继承开发认证环境。

第6项原文明确要求“保留旧已通过证据的来源，新整包变更部分独立复验”。
对[既有容量结果](macos-tools-history-current.md)重新核对34份容量及22份工具历史
原始文件摘要，并核对同包 AWS／SSH 的各19份原始资料。容量冻结源 `7ed2de0` 到
安装源 `7b19d34`，core/storage/CLI及桌面容量、附件、原生文件和历史实现无改动；
产品差异只有 Dart 与 AppKit 通知状态刷新/提交，完整 patch 归档。
这部分通知改动已在[普通安装包补验](macos-ordinary-system-followup.md)及
[系统状态修正](macos-notification-stale-permission.md)中独立核对。

容量仍沿用原来的真实 Debug 沙盒／SQLCipher4.19.0／原生文件、146次 CLI 断言、
44份交付结果：10MiB/+1字节、100MiB原件/草稿、200暂存、32草稿及共享100MiB/
32活副本边界。不是重跑普通 Release 容量、性能指标或完整普通设置页。
两版 SQLCipher二进制相同；两版 CLI 源码相同但二进制不同，摘要分别保留，
不能声称二进制完全等价。当前普通包 AWS／SSH／GH 的历史均已真实独立进程重开，
不再用旧合成入口的重开替代当前普通包历史。

据此第2、6项可完成，#44为 **OPEN、5/6**；第3项至少仍缺专用 GitHub 测试凭据
的成功认证，GH_HOST 固定 github.com，不能用无认证的本地200冒充。没有缩减原条件。
#50仍3/6，候选24安装、系统交互、最终同包客户端及干净环境范围继续保留。

[17份本轮公开协议、实际进程/载荷检查、CUA明确转录、来源差异及摘要](evidence/macos-final-ordinary-gh/verification.json)。
截图仅在会话观察，没有另存；本轮没有重跑四包全套或生成新 App/dSYM。
