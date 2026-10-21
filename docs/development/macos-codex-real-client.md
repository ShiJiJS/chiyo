# Mac 真实 Codex 合成资料验收

后续检查点已补齐自然到期、同库进程重开、实际传输恢复和真实 SSH 凭据复用，见[最新续验](macos-codex-runtime-continuation.md)。以下保留前一轮当时范围。

2026-10-21，继续 #49，只在 `codex/macos-adaptation`。用户明确允许为准备好的独立合成项目接入并信任 SessionStart、SubagentStart、SessionEnd。没有把此许可扩展到其他项目，也没有安排真实主子 Agent 委托场景。

本轮已从“材料准备”推进到真实客户端与模型工具调用。正式 CLI `/hooks` 逐条审查并信任三个准确命令；`hooks/list` 随后显示三项均 `trusted`，定义摘要与审查前一致。剔除这三个指定的 `hooks.state` 信任项后，用户配置的规范化摘要与审查前完全一致。没有直接写入信任摘要或使用绕过信任参数。正式信任和项目访问确认来自 Codex TUI，业务测试来自同版本独立 app-server。

## 测试条件与边界

- 客户端为 `codex-cli 0.158.0`。本机配置的 `gpt-6.1-sol` 被这个独立 CLI 的 ChatGPT 服务拒绝；失败记录保留。后续仅在测试请求中选择 `model/list` 返回的默认 `gpt-6-astra`，没有改变全局模型设置。分叉和恢复也需传入该临时选择，不能假定分叉继承。
- 宿主源码为 `d83f65a`，QA Release Flutter 入口使用生产 `DesktopLauncher`、bootstrap、SQLCipher、原生附件交付及 worker。它有随机独立 bundle identity、固定合成数据库密钥和 QA 文件控制器，不读取用户资料库或 Keychain。严格分析、Release 构建、深度严格验签均通过。
- CLI/hook/Skill 使用先前核对的 `cccc37e` ARM64 bundle，位于包含中文、空格、单引号和 shell 字符的稳定目录。已比较该提交与宿主的 core/CLI/storage 业务源码，差异为空。宿主与 `01c1f14` 最近交付包的生产 Dart/macOS 源码差异也为空。这仍不是对最终安装包及 Keychain 的联合验收。
- 模型从真实 SessionStart 得到本聊天私密关联；动态工具把 JSON 送入实际 `info-codex` 的匿名 stdin。子进程没有业务参数，设置实际 `CODEX_THREAD_ID`。文件与生命周期轮次还在发送 stdin 前检查了真实 `ps` 参数。没有读取 Codex 的认证文件或聊天记录，也没有保存原始模型上下文或 hook 私密输出。
- 主人选择通过仅限合成资料的 QA 文件控制器执行，不代表鼠标操作审批界面通过。普通附件消费是同机工具实际读取并关闭文件，不代表网站上传或外部文档软件通过。

## 已验证的读取和附件流程

聊天 A 从公开目录申请 Address、Username 两字段。主人只批准 Address；真实模型使用同一请求 `status`、`claim`，两次独立 CLI 调用读取 Address，值均符合合成数据。授权期限与主人批准时一致。额外负向协议探测读取 Username 返回 `unauthorized`。聊天 B 仅得到 A 的公开请求 ID，用自己的真实关联查询被拒绝。主人撤销后，A 的真实模型继续读取也被拒绝。

另一组真实聊天检查附件能力，提交附件请求，批准后 `claim`、`file-fetch`，将返回的准确路径交给同机消费工具。工具读取并关闭 1024 字节，摘要为 `ffbad8f947474cfdd5b2bb22d7e0bf5ee8ba2b7af859d0c2bb28622db6a4be47`，与夹具逐字节一致。随后真实模型 `file-release` 成功，受管路径消失。只产生一次交付，最终不占副本。

跨聊天 `claim` 负向协议探测返回 `unauthorized`；将 C 的关联置于 D 的线程绑定下、以及缺失关联均返回 `association_unavailable`。这些负向探测由驱动执行，单独标注 `negative-protocol-probe`，不冒充模型主动调用。真实 `thread/archive` 触发 SessionEnd 并结束 C 仍有效的授权；结束后的领取被拒绝。

附件首轮夹具只提供了 `codex_info`，未允许消费工具且不能读取附件引用说明，流程停在 `claim`，没有交付；补齐白名单、公开参考说明和工具 schema 后通过。最终附件轮的首次能力查询收到 `invalid_request`，模型修正公开能力查询后继续；没有重发访问请求、重复批准或重复交付。失败及修正记录均保留。

## 生命周期与剩余工作

真实模型压缩完成后，原聊天再次读取原授权成功，授权期限不变。正式 `thread/fork` 和 `sessionStartSource:clear` 分别创建新聊天，真实模型用最新关联查询父聊天请求均被拒绝。clear 的证据范围是正式 app-server 参数，不冒充手动操作 `/clear`。

根聊天另外提交一条待批请求；真实 `thread/archive` 触发 SessionEnd 后，原有效授权撤销，待批请求取消，二者均标记 `sessionEnded`。直接恢复归档聊天被客户端拒绝，返回必须先取消归档；此轮整体退出 1，前面已通过的组件仍保留。补充轮实际执行 `thread/unarchive`、`thread/resume`，模型使用原上下文关联查询得到 `unauthorized`，没有重新连接、提出新请求或复活原授权。补充轮和客户端退出 0。正在运行的聊天上的 `thread/resume` 只作为 rejoin 记录，不等同完整断开/恢复通过。

失败的首轮分叉因临时模型选择未传入而在工具调用前终止，未算隔离通过；后续修正轮才完成上述分叉检查。全部组件通过、失败重试及剩余范围见证据索引，不将整轮失败改写为成功。

#49 不因这组结果关闭。仍需覆盖有效会话的完整断开/恢复、自然到期、应用退出重开后旧授权不复活、用户安排的真实主子 Agent 显式委托与 Stop/Interrupt/子结束边界，以及真实聊天中的凭据多次执行/原操作重查。附件还需联合最终包与真实系统操作。SubagentStart 只完成发现、审查和信任，未触发真实子 Agent。

SessionEnd 的 `additionalContextLimit` 被客户端忽略并产生警告；本轮保持已审查定义不变，没有在信任后悄悄改写配置。此事件无需发送上下文，实际结束通知与历史结果分别记录。

## 复现

保留已批准项目及其同级 bundle 原路径。先运行 `scripts/qa/macos-codex-live.py`，等待隔离宿主就绪；只在已明确批准且经正式入口信任的合成项目运行驱动：

```sh
.tools/qa-python/bin/python scripts/qa/macos-codex-client.py \
  build/macos-adaptation/<新的输出目录> \
  --project 'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目' \
  --host build/macos-adaptation/<宿主输出目录>
```

该驱动会实际调用模型并操作合成批准，不安装 hook、不修改信任；拒绝复用输出目录。`--resume-ended <本项目已结束聊天的公开ID>` 只补充测试正式取消归档及结束后恢复。文件与读取轮次的准确执行源码保存在证据中，作为历史执行记录，不应原路径重跑覆盖。本轮宿主经 QA `quit` 正常退出 0，本轮拥有的资料目录和控制器已删除，最终有效授权、待批请求、占用副本均为 0，Flutter 错误为 0。

[证据索引](evidence/macos-codex-real-client/verification.json)区分未经修改的原始文件和移除 QA 控制标识的公开派生记录；不提交私密关联、控制器、数据库或任何密钥。正式信任行为参照[官方 hook 文档](https://learn.chatgpt.com/docs/hooks)。
