# Mac 原生执行与审计故障恢复（#43）

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

#43 暂保持 OPEN：独立执行宿主的实际终止/恢复已验证，但还需与 #46 合并验证
签名 Flutter 应用本体异常退出、重新启动的最终路径。这里的受控 hook 事件也
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
