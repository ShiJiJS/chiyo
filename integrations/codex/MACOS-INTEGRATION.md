# Mac 开发预览：接入 Codex

Mac 安装映像中的 `chiyo.app` 可以拖入「应用程序」独立运行。App 内已经包含同版本
CLI、worker、Skill 模板和摘要清单，位置是 `Contents/Resources/AgentIntegration`。
开发 ZIP 也保留 `app/chiyo.app` 和外部配套工具。先打开知予，确认资料库正常可用。
应用和随包命令不需要 Xcode、Flutter、Dart 或 Python。

## 在 App 中核对接入材料

在“设置 → Agent 接入 → 查看诊断”中核对配套文件。安装版优先核对 App 内的完整配套
资源，独立复制 App 仍可核对。诊断显示已核对的位置，接入命令使用该位置的工具。

“配套文件已核对”表示 App 主程序及身份文件、五个 CLI 程序、Skill 模板与接入说明
符合随包清单的大小、权限和摘要。此检查不执行命令，不是签名/公证检查，也不证明
宿主已经安装 Skill、信任 hooks 或 CLI 已经连接服务。诊断页不能观察到的宿主状态
显示“无法核对”；已有服务会话也不能替代安装和信任确认。

提示缺少清单或文件不一致时，恢复完整同版本交付包后重新检测。不要从其他版本、
PATH 或个人安装中拼凑文件。普通刷新复用未变化文件的摘要，打开诊断会重新计算摘要。
本机资料服务可用与 CLI 网络连通性分别核对；服务端口仍按下文和实际交付说明配置。

会话列表包含服务端当前公开关联及保留的普通资料申请历史。先明确选择要查看的会话，
同名会话用公开标识区分；软件不会按最新申请猜测当前聊天。列表统计仅含普通资料申请。
会话已结束时可查历史，不能因此恢复授权；名称和用途仍属于 Agent 自述。

## 生成固定路径的材料

已经配置过本机 Skill、需要把公开工具位置更新到安装版时，可运行以下命令。它只登记
路径与摘要；保留已有聊天配置、hooks 和信任状态。

```sh
"/Applications/chiyo.app/Contents/Resources/AgentIntegration/cli/info-prepare-codex" \
  --register-existing "/Applications/chiyo.app/Contents/Resources/AgentIntegration/cli"
```

在整包根目录打开终端，用随包生成器指定一个尚不存在的稳定目录：

```sh
./cli/info-prepare-codex "/你的稳定目录/agent-info-codex"
```

生成器会准备 `info-codex`、`info-codex-hook`、`info-runtime-worker`、`hooks.json`
及 `skills/agent-info-access`。它拒绝覆盖已有目录，生成的 hook 和 Skill 引用最终
绝对路径。移动材料后需要重新生成并审查路径；不要把输出留在准备清理的构建目录。

## 在项目中启用

先选择合成资料测试项目，审查生成的三个 hook：`SessionStart`、`SubagentStart`、
`SessionEnd`。保留项目已有配置，避免重复注册相同 hook；将需要的条目合入项目的
`.codex/hooks.json`，将生成的 `skills/agent-info-access` 放入该项目 `.agents/skills/`。

通过 Codex 的正式入口审查并信任准确的 hook 定义。CLI 可使用 `/hooks`，桌面端
以实际界面提供的入口为准。Codex 按当前定义记录信任；定义变化后需要重新审查，
项目受信任不代替具体 hook 的审查。参见 [OpenAI Hooks 文档](https://learn.chatgpt.com/docs/hooks)。
材料生成只是准备步骤，不能当成客户端已安装、已信任或已验收。

## 使用流程

应用默认服务端口是 `47125`。在已启用上述 Skill 和 hook 的新测试聊天中，让 Agent
先查找合成资料的公开目录、说明用途并申请所需字段，再在应用中批准选定范围。
请求本身不授予读取或凭据使用许可。已有聊天的明确重新连接按生成 Skill 的说明操作。

私密关联由 hook 提供给对应聊天，适配器通过独立 stdin 接收。不要把关联、授权凭证
或秘密值放入命令参数、shell 拼接、报告或普通日志。调用工具不能独立传递 stdin 时，
按 Skill 的限制处理，不能用公开聊天 ID 找回读取能力。

每次调用以服务实际 `capabilities` 为准，同时核对当前交付的支持范围。Round09 新界面
首批目标是普通资料保存、AI 申请和主人审批；尚未交付完整闭环前不能把界面预览当作
可用版本。底层协议已支持的附件、凭据等能力，不表示新界面已接入相应管理/审批流程。
这些后续功能仍按 tickets 交付，未接通入口应明确不可用。本机焦点填充保持关闭。
后续凭据流程中的 GH/AWS 使用服务发现的准确随包路径。随包模板的协议参考保留：

- [凭据申请、逐次操作与清理](cli/template/references/credential-use.md)
- [普通附件申请、领取与释放](cli/template/references/information-files.md)

模板中的执行路径需要生成器补全，实际调用使用生成后的 Skill。普通附件副本只表示
文件已交付，不表示网站上传完成；凭据文件继续由获准的执行流程注入。

红色关窗会保留后台服务；使用应用菜单或 ⌘Q 完全退出。应用退出或重启后旧会话能力
不会恢复，新连接仍须重新申请。实际客户端事件、聊天隔离和完整工作流程需分别验收；
生成文件或能够启动命令不等于这些场景全部通过。
