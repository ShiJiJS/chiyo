# SSH 持续交互

多步远端命令需要保留 `cd`、`export`，或需要普通确认、sudo 时使用 `chiyo ssh`。本机后台在本地和服务器资料库模式下都维护同一个 Shell；CLI 每次退出不关闭连接。资料库只负责原申请、批准及记录，目标不需要部署知予。

先看 `ssh --help`、具体子命令的 `--help` 和 `ssh capabilities --json`。当前远端需具备 Python 3、Bash、控制 PTY、Unix 对端身份、内核后代收养与 `/proc` 子进程检查能力；缺少时明确报告该能力，不自动安装依赖或按系统名字猜测可用性。服务器身份使用原有已确认的 known_hosts，未知或变化时由用户处理信任。

以下值均为示例占位；使用本聊天的私有配置、实际目标与凭据 ID：

```sh
chiyo ssh request --host HOST --port 22 --user USER --auth password --credential LOGIN_ID --title "部署指定服务" --summary "连接服务器，完成服务部署和检查。" --validity session --operation login-request-01 --json
chiyo requests wait REQUEST_ID --timeout 60 --json
chiyo ssh open --request REQUEST_ID --operation open-01 --json
chiyo ssh run --session SESSION_ID --operation run-01 --command 'cd /approved/work && export MODE=test' --json
chiyo ssh status --session SESSION_ID --run RUN_ID --json
chiyo ssh output --session SESSION_ID --run RUN_ID --cursor 0 --json
```

私钥登录使用 `--auth publickey` 和文件凭据 ID；不自行领取私钥路径或编写 ASKPASS／Expect。登录、sudo 是不同使用范围，密码可不同。批准期限按实际结果判断；会话内不限时仍随撤销、变更、停用或聊天结束失效。

`run` 返回 `accepted` 只表示接收；以原 `runId` 的实际 `state`、`exitCode` 和业务检查判断结果。`busy` 时不排队。读取真实提示后，Agent 决定是否发送普通确认：

```sh
chiyo ssh input --session SESSION_ID --run RUN_ID --text y --enter --operation input-01 --json
```

`--key enter|tab|eof` 用于单独按键。每次输入绑定原运行和操作编号；响应丢失查原操作及状态，不换编号重发确认。输出为合并的终端文本，包含 ANSI；游标返回 `gap` 时说明旧片段已丢弃，不能把缺少输出当作成功。

## sudo 接收

使用会话提供的普通 `sudo command`（也可用 `chiyo_sudo`），软件管理专用 ASKPASS 接收，保留调用方管道与重定向。只有当前 `run.credentialReceiver` 给出的可信 `actionId` 才能申请密码；免密码 sudo 不会产生接收动作。绝对路径 sudo、`command sudo` 或外部脚本内自行调用的 sudo 不经过这个函数，普通 `Password:` 提示不证明可受管接收；此时报告具体条件，不把密码当普通 input，也不自动改读原文。

```sh
chiyo ssh credential request --session SESSION_ID --run RUN_ID --action ACTION_ID --credential SUDO_ID --title "为安装步骤认证" --summary "给当前等待输入的 sudo 命令提供密码。" --operation sudo-request-01 --json
chiyo requests wait SUDO_REQUEST_ID --timeout 60 --json
chiyo ssh credential use --session SESSION_ID --run RUN_ID --action ACTION_ID --request SUDO_REQUEST_ID --operation sudo-use-01 --json
```

已有相同目标、版本、接收用途和有效期的批准可复用，仍须为当前运行核对接收动作。审批后原运行或动作已结束，旧申请不能转投下一运行。交付结果不含密码，`delivered` 也不表示业务命令成功。

## 中断、撤销和断线

```sh
chiyo ssh interrupt --session SESSION_ID --run RUN_ID --json
chiyo ssh close --session SESSION_ID --json
chiyo ssh close --session SESSION_ID --force --json
```

中断发送后查询实际结束状态。普通关闭先拒绝新命令并等当前运行自然结束；force 明确断开，未完成结果保留未知，不保证杀死所有远端后代。撤销后不再输入或交付凭据，原控制者仍可查询、中断、关闭。

`lost`／`unknown` 不自动重连、不恢复目录环境、不补发命令。先用原会话及 `operations show OPERATION_ID` 核对；需要新 Shell 时是一次新的明确连接操作。若旧运行留下后代，软件不能证明终端已空闲，会以 `terminal_descendants_active` 停止复用，保留该命令实际退出码和关闭入口，不为复用 Shell 静默杀业务 daemon。全屏编辑器完整渲染不在当前范围。

单次程序交付继续使用 [exec](credential-use.md#业务程序使用凭据) 的 stdin/env/file。env 只进入获批本机子进程，不修改 Agent Shell 或自动发送到远端；普通 export 不承担远端敏感环境注入。
