# Mac Codex 凭据复用、自然到期与真实重开

2026-10-21，继续 #49，所有改动只在 `codex/macos-adaptation`。本轮在[前一检查点](macos-codex-real-client.md)之后补齐第三、第五及记录条件，第 #49 现具备 5/6 条验收证据，真实主子 Agent 场景仍待用户安排；本票保持 OPEN。

## 真实模型与真实 SSH 接收端

宿主 `da226aa` 使用生产 DesktopLauncher/bootstrap、原生平台、SQLCipher、随包签名 worker 和 Apple `/usr/bin/ssh`，仍只使用独立合成库和 QA 主人控制器，不接触用户 Keychain 或资料库。新夹具的 bundle identity 与私密控制器标识分别随机生成，公开文件路径不再包含控制器值。三个已信任 hook 和六份准备材料摘要未变，剔除已批准的三个信任项后，其他用户配置规范化摘要仍与之前相同。

在同一已批准合成项目，真实 Codex 模型通过 SessionStart 取得本聊天关联，实际 ARM64 `info-codex` 每次从匿名 stdin 接收 JSON；发送前检查实际进程参数，只有程序路径，没有私密关联或业务 JSON。模型只看到公开凭据目录、类型化启动计划和运行状态，未得到私钥或其运行时材料路径。

主人对一个 `request-use` 批准合成 SSH 私钥和 Attachment，排除同时申请的 Username。真实模型读取到 `partially_approved` 和最终选中的单个文件字段；凭据授权固定 15 分钟，普通文件授权另有固定期限。随后：

| 检查 | 实际结果 |
| --- | --- |
| `codex-ssh-true-01` | 独立 worker/OpenSSH 执行，记录退出 0，清理 complete |
| `codex-ssh-false-01` | 同一授权、另一操作，记录退出 1，清理 complete |
| `operation-status` 重查首项 | 返回原执行事实，不启动新命令 |
| 原对象/原 operationId 再次 `run-use` | 原 executionId，`duplicate:true` |
| 服务端独立收据 | 仅收到 true、false 两条固定命令，没有第三次执行 |
| 同次部分批准的 Attachment | 领取 1024 字节，实际同机消费并校验摘要，关闭后释放 |
| 主人撤销后新 operationId | `revoked`，没有新增执行或命令 |

两次操作、重查、重放及附件消费未延长凭据授权到期。实际 capabilities 有 `credential-use-reuse.v1` 和 `information-attachments.v1`，没有焦点填充能力。首次公开能力/凭据目录查询收到 `invalid_request`，模型修正查询后成功；没有重发访问请求或自动增加执行。

这完成 #49 中 SSH 凭据复用/操作重查及附件部分批准消费的组合，不能据此宣称 #44 的外部 GH/AWS 目录授权、原生系统面板或 #50 最终安装包已通过。

## 自然到期与同库进程重启

使用生产允许的最短 1 分钟普通信息授权，没有注入或快进时钟。批准后实际模型读取成功；自然等待 62.029 秒后再次读取得到 `unauthorized`，授权历史不再 active，未重连、续期或创建替代请求。这是自然到期，不是睡眠唤醒验收。

另开真实聊天，批准固定一小时的 Address 并成功读取，然后经 QA 入口调用生产正常退出。宿主进程退出 0，随后以同一签名程序、相同 bundle identity、同一个 SQLCipher 资料目录启动新 PID。没有重新建库或重新播种：原信息项/附件 ID 以及之前两次 SSH 执行记录都保留。原模型上下文里的旧关联读取被拒绝；新聊天经真实 SessionStart、新请求和新批准后读取到原合成值。

这是真实应用进程重开和资料持久化，不能替代真实 Keychain 授权/升级、菜单栏/Dock/⌘Q 或最终安装包验收。QA 使用的固定测试数据库密钥公开且仅限独立合成库。

## 实际断线恢复和丢失关联

根据[官方 app-server 文档](https://learn.chatgpt.com/docs/app-server)的连接初始化、`thread/resume` 和订阅生命周期，驱动使用仅监听 loopback 的实际 WebSocket app-server，并启用 capability-token 握手认证。临时令牌只放在 0600 文件和内存，不放在命令参数，结束后删除。

真实模型获批并读取后，驱动关闭客户端连接、等待两秒、确认 Codex 服务仍是同一 PID，再建立新的认证连接、重新 initialize、正式 resume 原聊天。模型没有从父驱动补入关联，而是使用保留在原聊天上下文的同一关联再次读取成功，到期保持不变，期间没有 SessionEnd。这覆盖服务仍存活、订阅宽限期内的真实传输断线恢复；不冒充关闭服务或 SessionEnd 后仍有旧授权。

随后仅将这个合成聊天已持有的准确关联文件移至不可用状态，不读取内容、不搜索任何其他关联。模型实际调用收到 `association_unavailable` 后停止，明确要求显式重新连接，没有按公开聊天 ID 补领、自动 `--connect` 或发起替代请求。测试拥有的暂存关联文件已移除，真实 SessionEnd 仍可用独立结束能力结束授权。

该 CLI 在主动客户端关闭时没有返回 WebSocket close frame，库报告 `ConnectionClosedError`。首轮业务已通过但读取线程打印了回溯；修正驱动后重复同一范围，最终轮将它记录为类型化关闭回执，线程正常结束、服务保持可重连、最终 Codex 退出 0。不把未收到 close frame 写成完整关闭握手成功。

## 证据、复现与剩余条件

[27 份证据索引](evidence/macos-codex-runtime-continuation/verification.json)保留宿主源码/构建/签名、四轮准确客户端源码、公开结果、关闭观察、秘密排除检查及生产源码对照。宿主与旧 CLI 的 core/CLI/storage 业务源码一致，生产 Dart/macOS 源码与先前 `01c1f14` 包一致；本轮只新增 QA 能力。客户端为 `codex-cli 0.158.0`，模型继续只在测试请求中选取 CLI 公布的默认 `gpt-6-astra`，全局模型配置未改。

项目 QA venv 增加固定 `websockets==15.0.1`，SSH 夹具继续使用 `paramiko==5.1.0`。只有传输恢复场景需要 websockets。宿主和用例均拒绝复用输出目录，hook 信任仍由正式入口和用户已有的明确授权约束：

```sh
.tools/qa-python/bin/python scripts/qa/macos-codex-live.py \
  build/macos-adaptation/<新的宿主目录> --ssh

.tools/qa-python/bin/python scripts/qa/macos-codex-client.py \
  build/macos-adaptation/<新的用例目录> \
  --project 'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目' \
  --host build/macos-adaptation/<新的宿主目录> \
  --case credential
```

另两个用例是 `--case expiry-restart` 和 `--case transport-resume`。按顺序运行，主人控制器不支持多个并发写入者。`expiry-restart` 实际正常退出/重开宿主，传输用例只重连自己的 Codex 客户端。所有请求都限合成资料，批准仍是 QA 控制器，不是物理审批界面。

结束时两次应用退出码均 0，资料目录、SSH 密钥及控制器已删除；有效普通/凭据授权、占用附件副本和 Flutter 错误均为 0。对完整私钥、其转义/编码及私密关联路径的检查没有在公开记录中发现内容；不提交数据库、密钥、控制器、传输令牌或原始模型/hook 私密上下文。

#49 剩余第四条明确要求用户安排真实主子 Agent 场景。此项已准备单子 Agent 方案并询问用户，未自行触发 SubagentStart、委托或伪造其结果。其他票的实际 Keychain、系统面板/输入/通知、睡眠、Windows 回归/迁移和最终安装环境边界继续保留。Computer Use 本轮再次确认 Mac 锁屏，已请求用户方便时手动解锁；自动验收没有等待解锁。
