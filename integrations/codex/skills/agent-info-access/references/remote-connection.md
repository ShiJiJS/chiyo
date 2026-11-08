# 服务器连接与命令调用

使用当前运行包末尾列出的 `Bundle executable`、`Connection profile` 和可选 `Session state directory`。连接配置由 App 顶部的“AI 接入”生成，包含指定服务器和受限设备身份。配置路径可作为程序参数；其中内容由程序读取。管理 Token 不属于 Agent 的接入资料。

已从本聊天取得 association 时直接复用。首次连接可以按主说明手动连接；普通关闭 App 或服务器维护后继续用原关联，不能因连接失败而换会话、换申请或延长许可。身份、证书或连接不符时核对原服务器与配置，需要用户明确重新连接时再创建新关联。

下面是当前 Mac/Linux 的 Node 子进程调用方式。`cliPath` 是运行包给出的 Bundle executable；`connectionFile` 和可选 `stateRoot` 也取自该运行包，未给出 stateRoot 时将该变量设为 undefined。只使用当前聊天标识；Node REPL 从 `nodeRepl.requestMeta.threadId` 取得，普通 Node 可取 `CODEX_THREAD_ID`。没有当前标识就停止接入。子进程通过 `/usr/bin/env` 继承正常环境并设置这一个公开标识，不要求 Node REPL 提供 process 全局对象。

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

首次连接且用户已要求本次使用软件时，在同一私密脚本会话里保存新关联，不输出 hook 的完整结果或关联路径：

```js
const hookPath = cliPath.replace(/info-codex(\.exe)?$/, 'info-codex-hook$1');
const args = ['--connect', '--connection', connectionFile];
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
