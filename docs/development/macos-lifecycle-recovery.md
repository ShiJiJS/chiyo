# Mac 原生执行与应用生命周期恢复（#43 / #46）

2026-10-21 后续已解锁并补充 [实际应用菜单、⌘Q、设置退出与重开](macos-native-lifecycle-ui.md)。
下文“尚需实际 UI”保留此前轮次的边界；最新逐项范围以该补充为准，
状态栏/Dock 直接操作、启动错误窗口和睡眠唤醒仍未完成。

## 2026-10-21 #43 收口：签名 Flutter 与运行中 SSH / worker

QA 源码 `17faee8`，新增场景使用实际 Release/沙盒 Flutter 宿主、随包 ARM64
worker、系统 `/usr/bin/ssh` 及仅监听 loopback 的合成 SSH 服务。
审批和密钥是合成输入，不接触生产库、Keychain 或真实 Codex。
没有修改产品执行、审计、进程身份或材料回收逻辑。

最终 `issue43-app-worker-2` 两个联合场景通过：

1. 命令处于远端受控等待时，仅 SIGKILL 测试 Flutter 应用。
2. 先按已登记 PID/内核创建身份 SIGKILL 测试 worker，再 SIGKILL Flutter。

两种情况下，驱动侧的 `proc_pidinfo` 均确认原 SSH 目标的内核创建身份、
进程组和存活状态保持；恢复进程启动前后各观察一次，随后才放行远端。
实际重开后的沙盒应用查询旧进程组返回 `null`（无法确认），不是确定已退出。
应用因此保留凭据材料和 `needs_check`，独立回收旧普通附件副本。
旧私密会话再请求命令/文件分别被 `session_required` / `not_authorized` 拒绝。
远端放行后应用核对进程组确已结束，凭据材料才被回收。
执行仍为 `unknown`、无退出码或结束时刻；无法确认的旧结果未被编造为成功。
每种场景只有 1 条执行记录，SSH 接收端命令计数均为 1。
两个恢复应用均由 Cocoa 正常退出 0，两个旧应用为明确故障注入 -9；
没有超时强杀清理。

首轮 `issue43-app-worker-1` 的测试错误地要求新沙盒必须读到进程组存活，
而不是接受保守的“无法确认”；因此失败。保留该轮源码、日志和结果。
修正 QA 为独立驱动验证目标实际存活、应用验证“不确定时不删”后再运行，
未放宽产品身份检查或沙盒。首轮两个确属本次测试的残留目录，分别通过
原 worker 回执/内核 ESRCH 和生成的合成私钥字节核对后由 QA 清理，
不冒称产品清理通过。最终轮凭据材料由产品回收，两个不含凭据的 worker
暂存目录由 QA 在确切 worker/目标均已不存在后回收；这是不同清理范围。

最终 QA 二进制 SHA-256：
`cc9eeabde1f025ff394ad340efcc422ede02682cf16db1b879b0083ac38d00fa`。
11 个构建前源码/锁快照、构建后源文件和 `17faee8` 提交的字节摘要一致。
Flutter 严格分析、Python 语法检查通过；收口定向运行
`credential_execution_audit`、`credential_operations`、
`credential_history_retention`、`credential_supervisor_recovery`、
`macos_material_files` 共 **41 项通过、0 跳过**，不与旧全量计数累加。
开发目录已恢复默认产品入口且严格签名通过，#50 原 ZIP 不变。
60 份原始资料与收口映射见 [证据索引](evidence/macos-app-worker-recovery/verification.json)。

按 #43 原有 6 条验收条件核对：

| 条件 | 证据 |
| --- | --- |
| 终态落盘失败时保持 unknown，恢复补记首份事实 | 既有实际 SQLCipher/AOT 的 terminal-audit-recovery；本次 Core 审计回归 |
| 重复/降级/迟到登记、并发及备份/退出排空 | 本次 41 项定向检查；此前完整 Core 回归 |
| AOT 双门、短命令/信号、后代与内核身份 | 既有 Darwin AOT worker 5 项；本次实际随包 worker / SSH 身份观察 |
| 撤销/到期/轮换/根结束、应用/worker 终止重开 | 既有 8 项 SQLCipher 联合场景；本次两种签名 Flutter 故障恢复 |
| 附件和凭据独立回收，不误删活跃/不确定材料 | 本次两种真实应用联合场景；本次 Darwin 材料链接/未知子项/身份检查 |
| Mac 原生入口、失败与恢复日志、启动计数和边界 | 已提交 QA 入口及原始资料；两种 SSH 接收端计数均为 1 |

#43 的执行回执与 worker 生命周期范围已完成。它不代替 #46 的实际菜单、
快捷键和睡眠唤醒，不代替 #42/#47/#49/#50 的 Keychain、通知、真实 Codex
或安装升级，也不代表 #19 整体可用。#41 的共享修改 Windows 实机回归仍单独保留。

```bash
python3 scripts/qa/macos-lifecycle.py build/macos-adaptation/new-worker-recovery --workers
./scripts/dev-macos.sh build
```

## 2026-10-21 签名 Flutter 应用本体（#46）

QA 源码 `1fea9d0`，产品逻辑与 `cccc37e` 交付包保持一致；
只增加普通 Flutter 应用入口和项目内 Python 驱动，未修改产品退出逻辑。
使用 Release、实际 App 沙盒/原生桌面 channel、SQLCipher 和独立应用进程。
密钥、资料与退出事件为受控合成输入；不调用真实 Keychain，不打开生产库。
本机仍为 macOS 27.0.1 / ARM64 / Xcode 27.1，锁屏期间可运行这些进程检查。

最终 `issue46-lifecycle-2` 一轮 10 个应用进程结果通过：
9 个进程由真实 Cocoa `terminate` 正常退出 0，
1 个是明确的 SIGKILL 故障注入；没有超时强杀清理。
测试用 Release 二进制 SHA-256：
`ed354b463af809bbb20e06a1cf81111d7b447298e8f13d73a8595dbf3ffe5996`。
它是 QA 入口应用，不能当作最终产品 ZIP 的 GUI 验收。

- 两个独立签名应用争用同一个合成 SQLCipher 库：第二个进程启动失败，
  key-store read/create 都为 0，未到达密钥访问；第一个进程数据库字节保持。
  第二个进程通过真实原生退出正常结束。拒绝来自实际跨进程文件锁，
  不只是同一 Dart isolate 的目录集合。
- 持有者完整退出后，库 close 恰好一次、监听端口释放。
  新进程重开保留正文、既往允许读取记录及 applicationClosed 历史，
  旧授权凭证拒绝。
- 驱动只向自己启动并已就绪的应用 PID 发送 SIGKILL，端口随后释放。
  新的签名 Flutter 进程重新打开原合成库，资料/历史保留、旧授权拒绝，
  再走正常 Cocoa 退出。此场景没有正在执行的凭据 worker。
- 已有合成数据库而 key-store 返回缺失：出现 failed 启动状态，
  不创建新密钥，不保留未释放的启动资源，测试触发 quit 后正常退出。
  这只是合成 key-store 的故障路径，不替代真实钥匙串拒绝提示。
- 由本次测试先绑定实际 **47125** 端口，再启动同一 bootstrap：
  启动失败后恰好关闭自己打开的库，并能正常退出。
  第一轮探索用随机端口，最终这轮才覆盖固定端口。
- 在异步打开资料库的受控等待点发起退出，80 ms 内没有请求原生终止；
  放行后库关闭一次，再经原生终止退出。这不代表键盘或菜单操作。
- 真实 SQLCipher 第二连接持有 `BEGIN IMMEDIATE` 写锁时发起退出：
  `shutdownFailed` 成立、尚未原生终止、库未关闭，旧授权拒绝。
  解除写锁后重试保存并正常退出；另一个应用进程重开，正文、
  applicationClosed 及原允许读取事实均保留。

最终轮在构建前保存了 9 个源码/锁文件快照，执行后核对未变化，
又逐一核对与提交 `1fea9d0` 的原字节摘要一致。严格 Flutter 分析通过；
Python 语法检查通过。首轮是较少断言的 8 进程探索，日志保留但不与最终
10 项相加，也不冒称首轮源码有完整快照。最初静态检查的括号风格问题
已修正，原诊断保留。没有重新运行或累加 #50 的四包全量计数。

驱动清理了自己创建的合成库和私密关联，仅保留安全结果、日志和源码快照。
QA App 独立保留在项目 build 目录；测试后重新构建默认产品入口并核对签名，
避免开发构建目录留在 QA 入口。原 #50 ZIP 未修改。
证据见 [#46 记录索引](evidence/macos-app-lifecycle/verification.json)。

复现命令（创建新的输出目录，需 47125 可供本次测试绑定）：

```bash
python3 scripts/qa/macos-lifecycle.py build/macos-adaptation/new-lifecycle
# QA 构建使用专属入口；结束后恢复开发构建目录中的产品入口
./scripts/dev-macos.sh build
```

**#46 保持 OPEN。** 仍需实际关窗/菜单栏/Dock/⌘Q、可见错误窗口、
菜单栏不可用回退和实际睡眠唤醒。正在执行的凭据 worker/附件材料与
签名 Flutter 宿主异常重开的联合场景已在上方 #43 收口补齐。合成退出事件不能替代这些 UI 操作，
锁屏下运行测试也不等于睡眠/唤醒验收。通知、真实 Codex 和 Keychain 升级
分别继续由 #47/#49/#42 验收。

## 2026-10-21 独立 AOT 执行宿主（#43）

2026-10-21，源码 `1534135`，基于 #41 的固定合并基线。
本轮使用合成资料、实际 SQLCipher、独立 AOT hook/适配器/执行宿主/worker、
Darwin PID/创建身份与 POSIX 进程组。工具分类和焦点输入为受控探针；
Mac 生产应用仍不宣告焦点填充。测试密钥仅保存在测试进程内，不代表 Keychain
或真实 Codex 已验收。

## 已证明的场景

`mixed_lifecycle_macos_test.dart` 复用原 Windows 联合场景的断言，并保留 Windows
入口及 DPAPI 行为。Mac 使用原生文件与进程适配，AOT 程序不使用 `.exe` 后缀。
新增 Mac worker 强制结束场景，最终独立运行 **8 项通过**：

- 撤销、到期、凭据轮换、根会话结束分别阻止新使用；旧批准事实及期限保留，
  不重放已有命令。普通附件与凭据材料独立回收，活跃进程的材料仍保留。
- 真正终止独立宿主后重新打开加密库，旧授权不复活；运行中的子进程材料保留，
  之后按原身份释放。未收到持久化回执时保持 unknown，没有编造退出码。
- 核对 worker PID/创建身份后 SIGKILL，再终止宿主并重开；后代仍运行时不误删
  材料，结束后回收，目标启动次数仍为 1。
- 实际 SQLCipher `BEGIN IMMEDIATE` 写锁阻止未记账的附件、命令和受控填充，
  会话结束仍生效；解除写锁后补记而不交付此前失败的操作。
- 已观察到目标退出但终态写入失败时，CLI 与主人列表都显示
  unknown/audit_unavailable。解除写锁后补记 exited/0、cleanup=complete，
  材料不存在，目标启动次数为 1，新操作仍被拒绝。

`macos_worker_lifetime_test.dart` 改为编译并执行真实 AOT worker，共 **5 项通过**：
登记门前 EOF 不启动；第二道门仍保持目标暂停；同组后代存活时等待；
worker 强制结束不等于后代结束；短命令退出 0、退出 7 和信号退出 -15
保留实际结果。它们与核心短命令/创建身份测试共同覆盖快速退出竞争。

以前仅因 Windows 条件跳过、实际已具备 Mac 实现的五项回归现在在 Mac 执行：
宿主登记前终止后的材料回收、worker 持久登记失败不启动、加密库重开的私有材料
登记、桌面启动清理终态材料、生产 bootstrap 的 v2 可复用能力。
保留所有断言；没有用跳过掩盖失败。

上游 Core 回执回归同时覆盖非法/重复/降级回执、迟到登记、并发写入、
保留清理、备份/恢复/退出排空。Mac 材料测试保留链接、未知子项、不确定身份
的保护；POSIX unlink 和主动脱离进程组的边界继续遵循 ADR0013。

## 验证范围与剩余工作

四包严格分析通过。全量结果为 Core 284/6、CLI 72/40、Storage 156/18、
Desktop 164/2（通过/跳过），合计 **676 通过、66 跳过**。这次全量包含最初
7 项联合场景；随后只增加 worker 强制结束重开场景，并再次严格分析存储包、
完整运行最终 8 项联合场景通过。重叠测试不累加成一个全量数字。

本轮没有产品运行时代码修改，Release 对应 #41 已构建的同一产品源码。
Windows 分支没有更新；当前共享测试适配仍缺新 Windows 主机执行证据。

#43 在本阶段曾因签名 Flutter 的联合路径保持 OPEN；该缺口已由上方
`17faee8` 两种实际应用场景补齐。#46 已补普通读取授权场景的应用本体故障重开。
这里的受控 hook 事件仍
不能替代 #49 的真实 Codex 生命周期。Keychain、系统通知及最终安装包分别由
#42、#47、#50 继续处理。

复现命令：

```bash
./scripts/dev-macos.sh check
cd packages/info_storage
../../scripts/dev-macos.sh dart test test/mixed_lifecycle_macos_test.dart --reporter expanded
```

[证据清单](evidence/macos-lifecycle-recovery/verification.json)保留首轮、全量和
最终联合日志、工具来源及源码摘要；不包含测试密钥、私密会话索引或数据库。
