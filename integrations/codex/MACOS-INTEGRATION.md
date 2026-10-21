# Mac 开发预览：接入 Codex

这份说明位于 Mac 整包根目录。App、CLI、worker 和模板的版本、来源与摘要见
`manifest.json`；保留完整目录。先打开 `app/info_desktop.app`，确认资料库正常可用。
应用和随包命令不需要 Xcode、Flutter、Dart 或 Python。

## 生成固定路径的材料

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

每次调用以服务实际 `capabilities` 为准。Mac 开发预览提供普通信息、普通附件和已支持
工具的凭据使用；当前 Mac 没有 Windows 专用的本机焦点填充能力。GH/AWS 应使用服务
发现的准确随包路径。详见随包模板参考：

- [凭据申请、逐次操作与清理](cli/template/references/credential-use.md)
- [普通附件申请、领取与释放](cli/template/references/information-files.md)

模板中的执行路径需要生成器补全，实际调用使用生成后的 Skill。普通附件副本只表示
文件已交付，不表示网站上传完成；凭据文件继续由获准的执行流程注入。

红色关窗会保留后台服务；使用应用菜单或 ⌘Q 完全退出。应用退出或重启后旧会话能力
不会恢复，新连接仍须重新申请。实际客户端事件、聊天隔离和完整工作流程需分别验收；
生成文件或能够启动命令不等于这些场景全部通过。
