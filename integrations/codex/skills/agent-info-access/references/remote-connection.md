# 聊天、连接与恢复

使用本包给出的 Bundle executable 或公开描述中已核对的 cliPath。先 `chiyo --help`，再用具体命令 `--help` 查看参数；不要求记住协议 JSON。命令示例里的路径和 ID 都是虚构的，运行时取实际值。

## 复用已有上下文

宿主可为本聊天提供 `CHIYO_CONTEXT`，或通过独立 stdin 使用 `chiyo --context-stdin ...` 传入仅含 association 的私有引用。CLI 读取文件，不在正常输出里返回证明。引用保留在当前工具的私密调用环境中，不打印、不写普通脚本参数、提交或无关聊天。业务 `--input -` 和私有上下文不能同时占用 stdin；业务需要 stdin 时通过受保护环境提供上下文。

已有 Codex 引用继续核对当前 CODEX_THREAD_ID；公开 ID 只是误用检查。Node 工具没有继承环境时，从本次工具元数据取真实聊天 ID，并保留本机正常环境；不要把环境不完整误判成需要新许可。不能扫描关联目录、读取客户端登录文件或按公开 ID 找回证明。

## 没有上下文时

本次任务确实需要知予且没有有效私有引用时，Agent 自行创建一个初始未授权聊天，无需用户单独确认。先看 `chat start --help`，例如：

```sh
chiyo chat start --agent "Example Agent" --id actual-chat-id --label "整理资料" --context-out /absolute/private-chat/context.json --json
```

context-out 必须是新文件的绝对路径，放在本聊天专用私有目录；程序不覆盖旧聊天文件，也不修改一般用户目录的权限。公开聊天 ID 由当前任务真实来源取得，没有宿主 ID 时为本次独立聊天生成唯一标识，不用其他聊天 ID 取权限。调用方在后续子进程环境设置 CHIYO_CONTEXT 指向自己刚指定的文件，再用 `connection show` 或 `chat show` 核对库、审批位置与设备；不要输出私有配置内容。

默认发现 App 已确认的 Agent 设备配置，不读 App 的管理密码或 Token。本包另给 Connection profile 时，chat start 使用 --connection 传其准确路径，由程序自己读取。它是接入配置，不授予业务内容访问。本地模式需要 App 在后台运行，服务器模式的申请由服务器接收；具体填写仍需要同一电脑的 App 执行能力。

原配置固定资料库，不随 App 切换默认库。网络断开保留原上下文、申请和操作编号，恢复后先查原记录。证书或服务器身份不符时停止核对，不关闭校验、扫描其他入口或换成本地库。明确会话失效时最多自动新建一次未授权聊天，新聊天不继承旧批准；业务被拒绝、到期或撤销不是重连理由。

## 提交与结果不确定

每次创建或执行可用 --operation 指定稳定编号，省略则软件生成。新业务动作与故障恢复分开：保存返回编号，丢失编号时从本聊天 requests／proposals／operations 列表找回；不按参数相似判断两次调用是不是同一次。

```sh
chiyo requests list --json
chiyo requests show REQUEST_ID --json
chiyo requests wait REQUEST_ID --timeout 60 --json
chiyo operations show OPERATION_ID --json
chiyo operations retry OPERATION_ID --json
```

retry 恢复原事实；未知填写或程序执行不重放。服务尚未找到记录也不证明网络中原提交永远不会到达。对于预检后提交，CLI 固定来源和模板摘要；普通本地记录不保存密码材料。stdin 来源未另存，必要时需要原内容和原编号，不靠摘要重建正文。

JSON 公共外层为 schemaVersion=1、ok、data，失败另有 error.code/message。退出码 0 表示本次命令按约定成功，2 输入错误，3 连接／上下文／能力不可用，4 执行未获准，5 执行失败，6 等待超时，7 结果未知，8 版本或操作内容冲突。查询读到 denied 或 failed 可以仍为退出码0；要看业务状态，不把查询成功当作执行成功。普通诊断不输出原始异常、配置或密码。

通用聊天结束用 chat end；宿主有真实结束事件时可由适配器结束。CLI 命令退出不是聊天结束，不因等了一分钟就自动结束已批准任务。
