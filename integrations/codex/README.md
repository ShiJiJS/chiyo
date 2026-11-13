# AI 与 CLI 接入

知予通过通用 CLI 向 AI 提供目录查询、动态模板、提案和访问申请。Skill 是调用说明，不授予权限；新增和修改由用户核对，读取或使用凭据另行申请。随包还提供 Codex 聊天适配器，用于关联当前聊天及处理结束事件。

## 选择同版本说明

| 场景 | 入口 |
| --- | --- |
| Mac 运行包与 Codex | [Mac 接入](MACOS-INTEGRATION.md) |
| Windows 运行包与 Codex | [Windows 接入](../../docs/development/windows-codex-integration.md) |
| NAS 服务器及设备配置 | [服务器接入](REMOTE-INTEGRATION.md) |
| chiyo 参数命令及旧协议兼容 | [CLI 参考](../../docs/cli.md) |
| AI 整理资料的调用方法 | [Skill 模板](skills/agent-info-access/SKILL.md) |
| 凭据与普通文件 | [凭据使用](skills/agent-info-access/references/credential-use.md) · [文件领取](skills/agent-info-access/references/information-files.md) |

平台接入文档同时作为打包模板，其中 `cli/` 等相对路径指解压后的完整运行包。使用同一版本的 App、CLI、worker 和 Skill，不把某个单独程序换进旧包；可用能力以运行中 `capabilities` 为准。

App 根据设置自动准备本地或服务器模式的受限连接。新聊天发现当前连接；已有聊天保留原服务。服务器模式中 App 退出后 NAS 仍可接收申请，本地模式完全退出 App 会关闭本机服务。服务器正常重启不延长原批准期限，也不单独结束仍有效的原许可。

**App 的管理 Token 不交给 CLI 或 AI。** 设备配置只能连接、查询公开目录并提交申请，不能审批。模板及填写例子从当前服务查询，不把模板清单复制进 Skill。

## 准备聊天接入

完整包中的 `info-prepare-codex`（Windows 为 `.exe`）向新的稳定目录生成程序、Skill 和 `hooks.json`。准备不修改个人配置，也不自动安装或信任 hooks；需要启用时按对应平台说明审查准确路径和命令，保留已有配置。

新入口为 `chiyo`，普通查询、申请和执行用子命令与参数，复杂批量业务才用 `--input`。先看 `--help` 和同版本 Skill；公开资料和模板动态查询。已有本聊天私有配置时复用，没有时用 `chat start` 新建未授权聊天。普通终端可用，不要求 hooks。

聊天配置是私密能力，通过本聊天的 `CHIYO_CONTEXT` 环境值或独立 stdin 交给 CLI，不放普通命令参数、日志或仓库。公开聊天 ID、请求 ID 和 Agent 名称都不是访问凭证。配置丢失时由 Agent 自动建立一次新的未授权连接，无需用户另行确认；不能按 ID 搜索磁盘恢复旧能力。

常规恢复或压缩保留有效的原引用，不延长许可。根聊天结束、撤销或到期后停止后续访问；普通 CLI 退出、切换聊天和子调用结束不自动结束根聊天。相关取舍见 [ADR0005](../../docs/adr/0005-end-only-codex-lifecycle.md)。

## 开发与验证

源码工具位于 `packages/info_cli/tool/`。`scripts/prepare-codex-acceptance.py` 可从已核对的同版本交付包生成独立测试项目，不操作已有项目或创建真实聊天。只使用合成资料；CLI 子进程测试不等于真实宿主事件已验证。任务及验收状态由 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 维护，不在接入说明中保留旧版本的待办列表。

下面保留本机适配器的凭据与结束索引规则，供实现和兼容维护。它描述本地服务生命周期；NAS 的持续运行和重启规则按上面的服务器说明执行。

## 本机聊天关联的实现约束

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
  不续期、不复活已结束或撤销的授权。若引用丢失，Agent 自动新建未授权连接，不搜索磁盘或恢复旧许可。
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
既有终态保持不变，用户仍能看到聊天标签及“会话已结束”的历史。

已确认的 [ADR 0005](../../docs/adr/0005-end-only-codex-lifecycle.md) 允许仿造或
延迟的本机公开 ID 结束事件导致提前断开；这只产生撤销，不能获取资料或审批。
结束回调使用单次 2 秒单调时钟预算，hook timeout 为 3 秒；不在结束路径创建
目录、执行 ACL 设置、启动 UI 或等待审计存储。失败保留仅撤销索引以便重试，
未送达事件依靠固定到期兜底。生成材料只注册 SessionStart、SubagentStart 和
SessionEnd；Stop、Interrupt、SubagentStop、CLI 结束及切换聊天均不结束根会话。
