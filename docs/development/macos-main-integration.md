# Mac 主分支整合与回归基线（#41）

2026-10-21，在 `codex/macos-adaptation` 执行。没有更新 `main` 或 Windows
开发分支。GitHub 票据 #41–#50 是当前执行范围；#51 焦点填充仍为后续能力。

## 固定来源

- 原 Mac 来源：`085512060b5cf5fe7f1e45abea52f17d253141bb`。
- 现有适配先保存为 `2966634`，包含 ADR0013、原生运行时、同卷另存、测试及开发入口。
- 整合上游：`b37f96a089d6d4a0a9f872bd667be0c6b037f975`，33 个上游提交。
- 被验证的合并提交：`093d60d1a966c2ce1c9527849a77503fd22ba80b`。
- 补丁、未跟踪源码归档和文件清单保存于本机忽略目录
  `build/macos-adaptation/issue41-20261021/`，整合前未重置或丢弃工作。

## 重叠检查

五个重叠文件文本合并无冲突，并核对合并结果：

| 文件 | 合并后保留的行为 |
| --- | --- |
| `desktop_bootstrap.dart` | 上游启动失败退出/资源排空与 Mac worker 路径、附件/复用能力并存；焦点填充仍只在 Windows 开启 |
| `credential_runtime_access.dart` | 结束回执首次校验、排队补记和 unknown 投影保留；Mac 进程组命名及 worker 身份参数保留 |
| `credential_material_access.dart` | 回执未稳定时拒绝清理；恢复后按 Mac worker 创建身份及实际进程组核查 |
| `credential_history_access.dart` | 审计写入排序和未补记记录保留，与 Mac 进程组存活检查并存 |
| `info_core.dart` | 上游审计模块、延迟初始化写队列、删除字段显示快照与 Mac 工具探测并存 |

删除字段名称/历史显示、文件对话框焦点恢复、启动失败退出和普通附件 Codex
Skill 均由固定上游带入。Windows `app status/quit` 的原生实现没有移植或宣告
为 Mac 能力。Windows 原生目录及 Codex 集成目录与固定上游逐字节一致。
Mac 双门握手、Darwin 身份检查和同卷另存实现没有在此次合并中被覆盖。

## 本机验证

在上述合并提交运行 `./scripts/dev-macos.sh check`：

| 模块 | 严格分析 | 通过 | 跳过 |
| --- | --- | ---: | ---: |
| info_core | 通过 | 283 | 7 |
| info_cli | 通过 | 69 | 41 |
| info_storage | 通过 | 148 | 19 |
| desktop widget | 通过 | 162 | 4 |
| 合计 | 四包通过 | 662 | 71 |

Core 的新增结束回执故障回归已实际执行。71 项跳过不算通过：

- Core：旧 Windows Job/宿主清理、Windows 文件占用、焦点生命周期和 Windows 控制探针。
- CLI：Windows worker/宿主/文件协议、旧 CLI opt-in、未提供实际 GH/AWS/SSH
  接收器路径及原生焦点 broker；新增普通附件 Codex 用例仍有 Windows 限制。
- Storage：DPAPI、Windows 进程中断/恢复/联合流程及未提供的旧版存储探针。
- Desktop：Windows 随包焦点 broker 两项、宿主执行 bootstrap、文件运行时恢复。

这些缺口分别继续由 #42–#49 的原生与旧版兼容验收承担，不能以本轮绿色汇总替代。
完整测试日志和跳过条件源码清单见
[证据清单](evidence/macos-main-integration/verification.json)。

`./scripts/dev-macos.sh build` 成功；随包 worker 已重新 AOT 编译。
`codesign --verify --deep --strict` 返回 0。Runner 仍含 ARM64/x86_64 壳体，
worker 仅 ARM64，所以本轮仅支持本机 ARM64，不能宣告通用发行包；#50 将处理
架构一致性与最终安装交付。应用包含 SQLCipher framework，但是否实际加载及
真实 Keychain 故障/升级行为继续由 #42 实测。

工具链固定为 macOS 27.0.1（26A434）、ARM64、Flutter 3.47.7
`abaf9c523780a608bd46686fd5e53740a07077f8`、Dart 3.13.5、
Xcode 27.1（27A9275）、macOS SDK 27.0。四份依赖锁保持不变；
工具版本、锁文件及产物摘要保存在 `environment.json` 和
`release-verification.json`。

## 尚未关闭的门槛

#41 的新 Mac 基线可用于后续票据。共享 Mac 适配后的 Windows 实机回归仍缺少
当前分支证据：Windows 会话主机本次无法读取；上游已有的 Windows 回归只证明
上游版本，不等于当前 Mac 分支。未运行收费 CI，也没有修改 Windows 开发现场。
因此 #41 暂保持 OPEN，同时继续执行不依赖该实机证据的 Mac 工作。

这份记录不宣告 #19 已可交付，也不把受控自动化当成真实 Codex、系统通知、
Keychain 或干净环境安装验收。
