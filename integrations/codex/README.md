# Codex 接入开发预览（Issue #6、#7）

这份接入用官方 SessionStart hook 提供当前聊天的私密关联。用户不需要
手工生成 token。它仍须真实桌面两聊天验收；当前实现不等于已安装或已验收。
来源：[OpenAI Hooks 文档](https://learn.chatgpt.com/docs/hooks)，2026-10-16 核对。

## 凭据边界

- 随机 256-bit 文件名指向不可变的会话凭据文件；文件在用户私有状态目录，
  Windows 设置仅当前用户继承 ACL，macOS 目录模式 700。创建权限失败则不交付关联。
- 文件只保存本机端口、聊天关联和随机会话能力，不保存全库密钥或授权 token。
  token 每次从服务按私密会话证明领取，读取不会续期。公开请求 ID、聊天 ID
  和 CODEX_THREAD_ID 均不能领取授权。
- 模型收到的随机文件引用本身也是敏感能力。它只用于该聊天 CLI 的 stdin，
  不进入普通响应、日志、argv、仓库或公开缓存。CLI 不接受按聊天 ID 寻找文件。
  调用工具必须将 stdin 与命令分开传入；不能将引用写进 shell 命令或 here-string，
  否则父 shell 的参数和命令日志仍会包含它。工具不支持独立 stdin 时停止接入，
  不以“CLI 自身没有 argv”代替端到端传递检查。
- CODEX_THREAD_ID 与记录的聊天 ID 比对用于防止误用继承的上下文，是附加关联
  检查，不是认证因素。可读同用户私有文件或已窃取能力的程序仍在 ADR 0002
  明确的安全边界之外。安装 hook 前应复核路径及命令。
- 不读取 hook 的 transcript_path，也不读取 Codex 登录认证或私人聊天历史。
- startup/clear/fork 创建新的未授权会话，重复启动也不会按 ID 复活旧授权。
  resume/compact 不新建关联，提示保留上下文已有引用；服务逐次核查是否仍有效，
  不续期、不复活已结束或撤销的授权。若引用丢失则需明确重新连接，不搜索磁盘。
  同根聊天每次 startup 的仅撤销凭据分别保留，SessionEnd 会结束快照中所有代际；
  恢复不会把已结束、过期、撤销或旧应用实例的权限变成有效。
- 应用退出或重启后，磁盘关联文件不会恢复服务端权限。连接失败、损坏文件、
  聊天不匹配分别给出 service_unavailable/association_unavailable，不自动申请。
  成功结束只清理已确认的仅撤销索引记录，保留无秘密的锁文件。读取关联文件
  留在原私有目录但不能复活服务权限；不在结束回调中按 ID 搜索或读取它们。

## 主子 agent 与自动结束

父 agent 通过现有私密关联调用 `delegate`，指定实际 childChatId，取得新的
随机 child-bound `privateAssociation`；只直接交给本聊天的该子 agent。子引用
携带同一服务会话证明，范围及到期时间不变。仅有父/子公开 ID 无法委托或领取
授权。SubagentStart 只提供使用指引，不通过父 ID 查询读取能力。

SessionEnd 使用独立随机 256-bit 仅撤销能力，由私有 `end-only/` 索引关联：
索引只有公开聊天 ID、随机代际、本机端口与仅撤销凭据，没有读取关联路径、
会话读取证明、字段值、token 或数据库密钥。文件名为有界聊天 ID 的 SHA-256，
每根聊天最多保留 64 个未确认结束的代际，文件上限 32 KiB；加锁更新、临时文件
落盘后原子替换。满额或损坏时停止创建关联，不静默丢弃旧结束能力。

服务验证仅撤销凭据后先不可逆结束内存会话，再异步保存历史。等待访问记录写入
的读取在交付前再次检查结束状态，结束先发生时不交付内容。已拒绝、已过期等
既有终态保持不变，拥有者仍能看到聊天标签及“会话已结束”的历史。

已确认的 [ADR 0005](../../docs/adr/0005-end-only-codex-lifecycle.md) 允许仿造或
延迟的本机公开 ID 结束事件导致提前断开；这只产生撤销，不能获取资料或审批。
结束回调使用单次 2 秒单调时钟预算，hook timeout 为 3 秒；不在结束路径创建
目录、执行 ACL 设置、启动 UI 或等待审计存储。失败保留仅撤销索引以便重试，
未送达事件依靠固定到期兜底。生成材料只注册 SessionStart、SubagentStart 和
SessionEnd；Stop、Interrupt、SubagentStop、CLI 结束及切换聊天均不结束根会话。

## 生成可审查安装材料

Windows 开发预览 ZIP 还提供无需 SDK 的 `cli/info-prepare-codex.exe`。它把编译的
CLI/hook 及 `info-runtime-worker.exe` 复制到用户选定的新稳定目录，生成最终路径的 hook 和 Skill，拒绝覆盖
已有目录；安装/信任仍需单独配合。详见 [Windows 交付说明](../../docs/development/windows-delivery.md)。

从 `packages/info_cli` 执行（先 `dart pub get`）：

```text
dart run tool/prepare_codex.dart ../../build/codex-preview
```

生成本机可执行文件、hooks.json 和 Skill。命令不会修改任何用户或项目的
`.codex`、不会信任 hook，也不会打开桌面。输出路径应选稳定位置，生成后
移动目录必须重新生成 hook 命令。Windows 命令编码只是安全传参，不含秘密。

准备用户实测时，再经用户明确授权：

1. 保留已有配置，只把 bundle 的 SessionStart、SubagentStart、SessionEnd 条目合入测试项目的
   `.codex/hooks.json`。先确认没有同一 hook 的重复安装。不要覆盖现有 hook。
2. 将 bundle `skills/agent-info-access` 放到测试项目 `.agents/skills/`，或按
   当前 Codex 的技能安装流程安装此目录。检查 Skill 中的可执行文件绝对路径。
3. 在 Codex 审查并信任准确的 hook 定义；官方 CLI 文档提供 `/hooks`。桌面端
   实际信任入口待用户现场验证，不能据此宣称桌面安装成功，也不要绕过信任。
4. 用户启动信息应用后，新建一个测试聊天。默认服务端口 47125。
   若服务尚未启动，hook 明确报告失败；启动后需重新连接，不能按聊天 ID 补领。
   已存在的聊天若从未收到引用，用户明确要求重新连接后运行 bundle 的
   `info-codex-hook --connect`，它使用当前 CODEX_THREAD_ID 创建未授权会话并交付
   hook 格式上下文；不读取历史，不查询旧凭据。普通 resume 保留已有引用。

目前不会自动执行上述安装步骤。用户只需要配合真实 UI 验证，不要求透露 token。

## 用户配合的两聊天验收

只用虚构资料，避免把关联引用、文件内容和 token 放入报告或截图。

1. 新资料库为空，用户先在“我的信息”创建一条虚构服务器信息，包含“地址”和
   “用户名”两个字段。聊天 A 用 catalog 获取实际生成的信息项及字段 ID，再请求
   这两个字段。用户确认桌面展示聊天关联、用途及字段，仅批准“地址”。记录公开
   请求 ID、字段及到期时间；不要假设固定的 demo-server/host ID 存在。
2. A 退出一次 CLI 进程后，再启动 CLI 两次读取同一字段，应成功且无新审批，
   到期时间不变；读取未批准的“用户名”字段应失败。
3. 聊天 B 独立启动，只提供 A 的公开请求 ID 和聊天 ID，领取/读取均应失败。
   B 自己提交请求后应出现独立审批。不得把 A 的私密引用交给 B 做演示。
4. A 正常恢复聊天时有效引用仍可使用且不续期；手动撤销后再次读取应失败。
   恢复已撤销/过期会话或 fork 成新的聊天后不能复活原授权。
   自动压缩后验证原引用保留；丢失时应明确重新连接，不静默扩大访问。
5. 完全退出信息应用后读取失败；重启再用旧引用/请求 ID 仍失败。重新连接后
   新申请才能获准。记录 Windows/macOS、Codex 版本、信任入口和实际结果。

CLI 一次 stdin JSON 的内容见 Skill。通用 `info` 仍支持 JSON-lines；Codex 适配
独立于业务命令。wait/cancel 由 #4 提供；主子 agent 与结束适配的实际 Codex 验收
使用 [Issue #7 检查清单](../../docs/development/chat-lifecycle.md)。

## 已验证与未验证

Windows 自动化测试启动真实 Dart CLI 子进程、核心服务和 hook payload，覆盖多次
CLI 的复用、固定到期、撤销、已知 ID 无法领取、同 ID 重新启动不复活、其他
聊天引用误用、缺失/错误关联、服务端会话失效、不读取 transcript_path。
这些测试不创建真实 Codex 聊天，不打开应用窗口。

真实 CLI 子进程还覆盖子引用委托、同一范围与固定到期、多个启动代际结束、
结束后子读取失败、忽略非根结束事件，以及服务无响应时的预算和失败后重试。
这些是适配器和受控 payload 验证，不代表真实 Codex 发送过事件。

尚未验证：真实 Windows Codex 桌面安装/信任、两聊天及压缩体验、主子 agent
上下文交付、SessionEnd 送达/顺序与 fork 上下文。先完成 Windows 验收；用户自有
Mac 的验证后续安排，不运行托管 macOS 验证。Issue #6/#7 的真实接入验收在必要
用户步骤完成前保持未完成。
