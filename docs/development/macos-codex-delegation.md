# Mac 真实 Codex 主子 Agent 委托验收

2026-10-21，按用户安排在已批准的合成项目完成 #49 第四条。结合[先前真实聊天验收](macos-codex-real-client.md)和[运行时续验](macos-codex-runtime-continuation.md)，本票六项条件已有证据。最终安装包、真实主人审批界面、Keychain、系统通知及睡眠仍由各票和 #50 验收，不能据此宣布整套 Mac 软件可用。

所有改动在 `codex/macos-adaptation`。本轮只改 QA 驱动和记录；生产业务源码继续是 `01c1f141d876a9d3c49c61c7fc3d1e572c432c5a`。没有运行 Windows CI、改动 Windows 分支或合并 main。

## 真实事件及结果

Codex CLI 为 `0.158.0`，测试进程选用该 CLI 公布的默认模型 `gpt-6-astra`，不改全局模型。三个 hook 沿用用户正式批准、经 `/hooks` 逐条信任的准确命令，定义未改。本轮真实触发 SessionStart、SubagentStart、SessionEnd，均有 completed 回执。不是构造 hook payload 或驱动模拟子 Agent。

最终用例 `issue49-real-delegation-mcp-5` 的根聊天是 `01a15d8b-dbf9-7190-8655-d342ced14ce0`，实际唯一子 Agent 是 `01a15d8c-82b1-79b2-bba5-6c46a1558f82`。根模型调用客户端自身的 spawn/followup 委托工具；不是从外围给子 Agent 直接启动回合。合成主人控制器只批准 Address，排除同次申请的 Username，固定期限一小时。

| 操作与观察 | 实际结果 |
| --- | --- |
| 根模型领取并读取 Address | 成功；只有一个普通信息授权 |
| 根模型显式 `delegate` 到实际子 ID | 成功，新引用绑定该子聊天，根引用不交给子模型 |
| 子模型经自己的引用 `claim` | 与根相同 request、获批 Address 和 `expiresAt` |
| 子模型读 Address / Username | 分别 `ok` / `unauthorized`，未扩大范围 |
| 两项独立引用混用探测 | 子引用用于根、根引用用于子均 `association_unavailable` |
| 子任务实际完成后 | 根授权仍 active；根模型再次读取成功，期限未变 |
| 正式 `turn/interrupt` 中断根回合 | 实际回合状态 interrupted；未结束根授权，随后模型仍可读且不续期 |
| 正式 `thread/archive` 触发根 SessionEnd | 请求 revoked、会话 ended、授权 inactive |
| 根结束后的两项独立协议读取 | 各自正确引用均 `unauthorized` |

最终共 14 次实际 ARM64 `info-codex` 调用，所有进程退出 0；其中三次是子模型的真实 MCP 调用，引用混用和结束后探测明确标注为独立协议检查。每次都先检查真实 argv 只有程序路径，再通过匿名 stdin 交付 JSON；没有私密引用或 JSON 命令参数。中断通过正式 app-server 接口完成，不冒充手动点击客户端 Stop 按钮；子结束指实际子任务完成，不冒充用户手动关闭子聊天。

## 子 Agent 的工具通道

当前客户端的子 Agent 不继承父回合动态工具。参考[官方子 Agent 配置](https://learn.chatgpt.com/docs/agent-configuration/subagents)、[app-server](https://learn.chatgpt.com/docs/app-server)与 [MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)接口，本轮给独立测试 app-server 临时配置一个可继承的 stdio MCP 通道，转发到同一个匿名 stdin CLI 桥。它是验收工具，不是已经装入产品的默认 MCP 集成。

通道只允许这一实际子聊天、这一合成请求的 `claim/status/read`，读取目标限于同一合成信息项的 Address/Username，拒绝额外参数和其他命令。驱动必须先收到真实 app-server 的 `mcpToolCall`，核对真实 caller thread 与完整规范化参数后才运行 CLI；不能仅靠调用者自报 chatId。CLI 的 `CODEX_THREAD_ID` 也取实际调用聊天。子模型只得到自己的委托引用。

MCP 工具标注与实现均只读；仅本次进程通过 `-c mcp_servers.agent_info_synthetic.tools.codex_info.approval_mode="approve"` 允许这一个合成工具，不改配置文件或其他工具策略。父回合仍是只读沙盒、never 审批策略。并发子 Agent 和深度均限 1。桥只监听测试拥有的 `/tmp/aim-mcp-*/bridge`，目录 0700、socket 0600，最终删除。未写持久 MCP 配置，未读取 Codex 原始 transcript 或认证文件。

## 调试记录

按顺序保留每轮真实结果和准确源码，不把失败结果重写成通过。每轮最多一个子 Agent；调试中实际创建过多个先后独立的子 Agent，不能宣称整个过程只创建过一个。

| 用例 | 结果与处理 |
| --- | --- |
| `client-1` | 在创建子 Agent 前中断以适配新事件格式；正式 thread/list 的 parent 筛选确认无子聊天。不是通过 |
| `client-2` | 新客户端使用 `subAgentActivity`，旧驱动只识别 `collabAgentToolCall`，读取子 ID 失败；扩展真实事件解析 |
| `client-3` | 子模型没有继承父动态工具，无法执行预期读取；保留失败，增加临时 MCP 通道 |
| `mcp-1` | 根模型未将内存中私密引用送入子上下文，子未调用；修正委托提示和私密上下文传递 |
| `mcp-2` | 外围直接向 v2 子聊天 `turn/start` 被正式 API 以 -32600 拒绝；移除此路线，使用根模型自己的 followup 工具 |
| `mcp-3` | 工具原本支持较宽命令，现有 never 策略拒绝子调用；将工具缩为上述只读操作，并仅为本合成工具配置进程内策略 |
| `mcp-4` | 完整流程成功，12 次 CLI；随后识别到还需显式核对引用混用负向条件 |
| `mcp-5` | 增加两项真实绑定负向探测，完整成功，14 次 CLI、子模型 3 次调用 |

## 来源、清理与复现

宿主源码 `2c5f4569656647c2edcfdedd433dbc1b9425b4f3`，最终驱动 `b6ff5c8`。宿主是独立 bundle identity 的签名 Release，使用生产 DesktopLauncher、平台渠道、SQLCipher 和 worker。合成数据库用公开固定测试密钥，主人批准由 QA 控制器执行；不接触个人资料和个人 Keychain，也不代替物理审批验收。159 份生产源码输入与 `01c1f14` 及当前文件逐项摘要一致，驱动及 MCP 快照与记录摘要和已提交 blob 一致。

[39 份证据索引](evidence/macos-codex-delegation/verification.json)保存八轮公开结果、标准错误、准确驱动/MCP 源码、宿主构建/签名/退出日志和来源核查。JSON/日志检查没有私密关联路径或 SSH 私钥；驱动另逐一检查本轮所有已知私密引用不出现在公开证据。原始私密模型/hook 上下文、数据库、控制器和关联文件不提交。

最终 Codex 服务退出 0，临时 MCP socket 删除。宿主正常退出 0，拥有的合成资料目录和控制器删除；最终 Flutter 错误为 0，没有有效授权、凭据执行或占用附件副本。失败轮也结束自己的根会话，不保留有效授权。

复现需要用户安排真实子 Agent，且仅在已有明确授权和正式 hook 信任的合成项目执行。输出目录必须全新，宿主与客户端按顺序操作，不能并发写主人控制器：

```sh
.tools/qa-python/bin/python scripts/qa/macos-codex-live.py \
  build/macos-adaptation/<新的宿主目录>

.tools/qa-python/bin/python scripts/qa/macos-codex-client.py \
  build/macos-adaptation/<新的委托用例目录> \
  --project 'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目' \
  --host build/macos-adaptation/<新的宿主目录> \
  --case delegation --delegation-mcp
```

此独立真实客户端证据补齐 #49，不将 #44 外部工具目录许可、#46 菜单/Dock/睡眠或 #50 最终安装包联合验收自动视为通过。Windows 回归与迁移依照用户要求留待后续，不在本次触发。
