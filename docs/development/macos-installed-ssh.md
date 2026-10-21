# 固定普通 Mac 包的 SSH、空附件与执行中退出验收（#44 / #46 / #50）

2026-10-21，独立 `codex/macos-adaptation`。同一固定目录、普通 `main.dart`
完整安装包 `0.4.0+12-mac-dev.4690e79357bb`，源码
`4690e79357bb728da22193d8dadd6dc8a8ce2ce6`，沿用此前已允许的生产 Keychain。
没有改应用身份、替换数据库、注入测试密钥或新增系统允许。App 只继承
HOME/USER/LOGNAME/LANG 和系统 PATH；公开 AgentClient 驱动仍需开发 SDK，不能
将它说成最终独立 AOT 客户端验收。

[完整结果、66 份原始资料及逐文件摘要](evidence/macos-installed-ssh/verification.json)。
这是列出的场景通过，不代表所有 Mac tickets 完成。

## 真实系统 SSH 和固定期限

真实 NSOpenPanel 从中文空格目录导入两份新生成的合成私钥，分别正确/错误；
三轮导入独立 known_hosts，逐次在实际 GUI 核对主机和摘要后确认。测试接收端
仅监听随机回环端口，完全隔离个人 SSH 配置、agent 和已有主机信任；零字节的
私钥和 known_hosts 均被拒绝。

普通 App 托管随包 worker，实际启动 `/usr/bin/ssh`，本机版本为
OpenSSH 10.3p1 / LibreSSL 3.3.6；工作目录是实际沙盒容器 Data。
批处理、独立空配置、仅指定私钥、禁用 agent/密码交互、严格主机校验、独立
known_hosts 均进入真实启动计划。没有关闭沙盒或借用开发终端认证。

| 操作 | 实际结果 |
| --- | --- |
| 未知主机记录 | 启动 SSH，严格校验拒绝，退出 255；接收端没有执行命令。 |
| GUI 更换主机信任后用旧许可发新操作 | version_invalidated / receiver_not_ready，operationClaimed=false；旧操作查询不重跑。 |
| 正确地址但错误主机公钥 | SSH 实际报告主机身份变化，退出 255；没有远端命令。 |
| 正确主机与正确私钥，先 true 再 false | 共享同一许可，分别退出 0 / 1，接收端仅记录这两次命令。 |
| 正确主机但错误私钥 | Permission denied (publickey)，退出 255，没有远端命令。 |
| 仅将 cwd 改为未授予的容器外合成目录 | start_failed / process_start_failed，processStarted=false，无远端命令、材料已清理。没有捕获具体 OS errno 或 sandboxd 拒绝行，不作更具体归因。 |
| 前六个操作重复查询 | 返回原 executionId，不重复执行、不延长许可。六个操作 cleanup=complete。 |
| 自然等待实际 15 分钟 | 固定截止 2026-10-21T15:34:03.920Z，之后新操作 grant_expired、operationClaimed=false；到期后查询旧成功操作仍是原 ID，无续期或重跑。 |

共 47 次公开命令、5 份实际 GUI 批准的凭据使用许可、7 个登记操作，其中 6 次
真正启动目标 SSH。第七个是下节执行中退出案例，不把 start_failed 或重复查询算成启动。
最初申请用途写了“一分钟”，实际菜单只有 15/30 分钟并最终批准 15 分钟；证据保留
菜单和确认页面，本轮自然到期验收明确按实际 15 分钟计算。

## 普通入口执行中正常退出、重开与人工核查回收

最后单独批准 `/fixture/wait`，接收端只允许一个受控等待、最多 120 秒。
内核直接观察到 App41097 → worker42755 → SSH42756；四份材料权限 0600、目录
0700，临时私钥摘要与合成原文一致。实际 CUA ⌘Q 后 App 原生退出 0、47125 端口
关闭；worker 与 SSH 继续执行，材料保留。

独立普通 App42786 无新增主人钥匙串操作即可重开。旧客户端访问 unauthorized /
session_required；实际历史中该操作为 unknown，没有伪造退出码或完成时间，提示
需要核查。活进程和四份材料仍在，没有重新执行命令。接收端释放后，核对 SSH 和
worker 均已结束；材料仍保留等待主人核查。随后通过实际历史回执的“核查并重试
清理”，四份文件和目录全部由产品清除，结果仍为 unknown，不补造成功事实。
接收端独立计数一直为 1。

重开保留共 13 条历史，新五份 SSH 许可及七个登记操作均可追溯，早先八条历史保留。
退出结束会话后，历史许可显示已撤销，固定到期时间没有变化；不能把最终撤销标签
当作此前自然到期没有发生。

## 原生空附件面板和现有输入

实际普通表单新建 `MacSshAcceptanceEmptyAttachment` / `ZeroByteAttachment`，
NSOpenPanel 接受 `空 普通附件.txt`（0 字节），保存后显示 0B、v1。NSSavePanel
先取消，再另存中文空格路径，导出仍为 0 字节。第二次选择已有目标并点击系统
“替换”，产品明确拒绝已有文件；源文件和目标的字节、inode、mtimeNs 全部保持。
独立 App 重开后再次导出，仍与空文件原文相同。

此前主人录入的 `777` 在实际 GUI 中保留，没有覆盖。Escape 关闭未修改的表单；
⌘A 和系统 Edit→Select All 没有取得明确视觉选区，因此不宣称键盘选择或 IME 验收
通过，也没有依据这次不确定观察改产品。

## #46 历史证据逐项复核

这次普通包补上执行中**正常退出**；之前隔离原生实验已经覆盖其他故障分支。
本轮重新按不可变清单验证六份原始结果的字节和摘要，逐项映射验收项：

- 第 3 项：上述普通 ⌘Q/重开，以及 [原生生命周期 run-02](evidence/macos-app-lifecycle/raw/run-02/result.json)
  的正常退出/重开、端口释放、旧会话拒绝和信息/已批准访问记录保留。
  [audit-failure](evidence/macos-app-lifecycle/raw/run-02/audit-failure.json)
  使用实际 SQLCipher 写锁，证实审计失败阻止退出、保留资料库供重试，旧授权失效；
  重试正常退出 0、库关闭一次。[独立重开](evidence/macos-app-lifecycle/raw/run-02/audit-reopen.json)
  证实原信息、已结束许可及获准访问记录落盘。
- 第 4 项：本轮普通执行中退出和实际回执核查清理，加上
  [隔离原生 worker run-02](evidence/macos-app-worker-recovery/raw/run-02/result.json)
  的应用异常终止、worker 与应用异常终止两类自建合成进程故障。两份
  [应用故障重开](evidence/macos-app-worker-recovery/raw/run-02/app-crash-reopen.json) /
  [worker 与应用故障重开](evidence/macos-app-worker-recovery/raw/run-02/worker-and-app-crash-reopen.json)
  都保留活材料，进程组结束后回收材料和普通附件副本；回执 unknown、exitCode/
  finishedAt 为空，执行计数 1、旧能力拒绝。故障注入的 -9 始终是异常实验，不算正常退出。

历史两轮实际记录源码为 `0fd328566e73f8b50dd901da9e947e89625668de` 和
`d97a8c54c93f32b7326a6f4c48b1bcd7079a581e`。分别与当前安装源码比较 core/storage/
CLI 的 lib 和 desktop_runtime.dart：只有新增只读 stopped getter、可选公开工具位置
发现和新工具定位模块；本次所依据的审计、授权、worker/材料/附件回收、SQLCipher
退出逻辑未改。两份原始 diff 已归档，不称整个二进制或所有原生源码相同，也没有
对生产资料库注入崩溃/写锁。

因此 #46 第 3/4 项可以依据明确分轮证据勾选；直接 Dock/菜单栏重新打开及菜单栏
不可用回退、真正系统睡眠/唤醒与刷新仍待，整票保持 OPEN。

## 清理与剩余范围

导入源与两份导出均核对后，已移除这轮私钥夹具目录和包含受管路径的私有观察控制
文件；回环服务器按自有 PID SIGTERM 结束 143、公开客户端退出 0。测试服务器的
信号退出不算产品正常退出。两份合成 SSH 凭据已在实际 GUI 停用并隐藏，原本为空的
主机信任列表恢复为空；没有更改个人 SSH 配置、钥匙串全局策略或原资料库。

固定普通包再次核对 7,971 个清单项及 strict 签名，保持不变。项目只保留一份预览
App，零生成 dSYM（工具链除外）；App42786 保持打开，不宣称它已退出。

#44 尚有工具版本变化/重新验收、普通附件旧新版本及授权/回收复合条件、容量与
最终整包影响复验；容器外 cwd 失败没有具体系统 errno。#48 的凭据“最近使用”
修正尚未进入本包，完整键盘/IME 等继续待验。#50 最终升级、通知、备份、Codex、
干净用户和签名分发仍待；自然到期不替代实际 OS 睡眠。本轮未改 Windows/main/CI。
