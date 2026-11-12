# 资料库连接与命令调用

使用当前运行包末尾列出的 `Bundle executable` 和可选的 `Connection profile`、`Session state directory`。App 打开本地库或成功保存服务器连接后自动准备受限配置；CLI 默认自动发现，用户不需要生成配置。运行包明确指定配置路径时传给程序；配置内容只由程序读取，管理 Token 不属于 Agent 的接入资料。

本地模式使用 App 发布的本机连接，保持 App 在后台运行即可；显式退出后本地服务停止。重新打开库不会恢复已结束的聊天许可。已有聊天关联始终指向原库，不随默认库切换；原库不再可用时报告具体状态；关联确实无效时按主说明自动建立未授权连接。

已有有效 association 时直接复用。首次连接、引用丢失或确认会话无效时，Agent 自动执行一次下方连接调用，无需用户单独同意；结果是新的未授权会话，不恢复旧许可，也不自动重发原业务申请。普通网络中断或服务器维护继续保留原关联和操作编号，连接恢复后查原结果。身份或证书不符时停止并核对原目标，不关闭校验或改连其他库。

下面是当前 Mac/Linux 的 Node 子进程调用方式。`cliPath` 是运行包给出的 Bundle executable；可选 `connectionFile` 和 `stateRoot` 取自该运行包，未提供时设为 undefined。只使用当前聊天标识；Node REPL 从 `nodeRepl.requestMeta.threadId` 取得，普通 Node 可取 `CODEX_THREAD_ID`。没有当前标识就停止接入。子进程通过 `/usr/bin/env` 继承正常环境并设置这一个公开标识，不要求 Node REPL 提供 process 全局对象。

```js
const { spawn } = await import('node:child_process');
const chatId = (typeof nodeRepl !== 'undefined' && nodeRepl.requestMeta?.threadId)
  || (typeof process !== 'undefined' && process.env.CODEX_THREAD_ID);
if (!chatId) throw new Error('缺少当前聊天标识');
async function invoke(executable, args, input) {
  const child = spawn('/usr/bin/env', [`CODEX_THREAD_ID=${chatId}`, executable, ...args], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let out = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => { out += chunk; });
  child.stderr.resume();
  const ended = new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => code === 0 ? resolve() : reject(new Error('CLI 未完成')));
  });
  child.stdin.end(input === undefined ? '' : JSON.stringify(input));
  await ended;
  return JSON.parse(out);
}
```

本次任务需要连接且没有可用关联时，自动执行一次下面的调用，将新关联保留在同一私密脚本上下文；有效关联不重建，单纯网络失败不触发本步骤。不输出 hook 的完整结果或关联路径：

```js
const hookPath = cliPath.replace(/info-codex(\.exe)?$/, 'info-codex-hook$1');
const args = ['--connect'];
if (connectionFile) args.push('--connection', connectionFile);
if (stateRoot) args.push('--state-root', stateRoot);
const opened = await invoke(hookPath, args);
const context = opened.hookSpecificOutput?.additionalContext;
if (typeof context !== 'string') throw new Error('未取得新的聊天关联');
const association = JSON.parse(context).association;
if (typeof association !== 'string') throw new Error('聊天关联不可用');
const execute = command => invoke(cliPath, [], { association, ...command });
```

后续命令的结果按任务需要返回；association 继续只留在私密调用上下文。先用 `execute({command:'capabilities'})` 核对实际能力，再查询 `catalog` 和 `directory-list`。从查询结果选择准确 ID，普通文字申请格式如下：

```json
{"command":"request","operationId":"read-001","purpose":"本次需要这些字段的用途","fields":[{"itemId":"查询所得资料ID","fieldId":"查询所得字段ID"}]}
```

保留返回的 requestId，使用 `status` 或 `wait`（可给 timeoutMs）等待原申请。获批后 `claim` 核对 fields 和 expiresAt；`read` 提供 requestId、itemId、fieldId。CLI 私下领取读取凭证，不在结果中返回它。收到 request_unknown 或没有拿到 requestId 时，用 `request-status` 提供原 operationId 查询；等待、CLI 退出和服务器普通重启均不重新提交。

申请编号、状态和批准范围可以报告；配置内容、hook 完整结果、association 以及私密证明不进入普通日志或 shell 命令。文件、凭据和模板能力以 capabilities 为准，没有相应能力时暂缓对应任务。
