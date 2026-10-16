# 通用 CLI 申请与等待

CLI 使用标准输入逐行 JSON，标准输出每行一个结果。保持同一个 CLI 进程，授权会话凭据和已领取的访问凭据留在进程内；不要把凭据写入命令参数、日志或聊天。启动入口是 `dart run packages/info_cli/bin/info.dart`，默认连接本机应用端口 47125，可用 `--port` 指定开发端口。

按顺序发送（示例字段仅适用于虚构演示资料，真实字段先查询目录）：

```json
{"command":"catalog"}
{"command":"session","chatLabel":"当前聊天的说明"}
{"command":"request","purpose":"检查服务器地址","fields":[{"itemId":"demo-server","fieldId":"host"}]}
```

保存 `request` 返回的 `requestId`。返回值还包括创建时间 `createdAt` 和待审批到期时间 `requestExpiresAt`，均为 UTC。默认待审批 30 分钟；用户可以在桌面设置中调整新请求的有效期，已提交请求的截止时间保持不变。

以下示例的 `REQUEST_ID` 替换为原来的请求标识：

```json
{"command":"status","requestId":"REQUEST_ID"}
{"command":"wait","requestId":"REQUEST_ID","timeoutMs":30000}
```

`wait` 每次只查询原请求，默认等待 30 秒，`timeoutMs` 可为 0–300000 毫秒。0 表示只查询一次。单次通信额外受 5 秒网络超时限制，所以最坏返回时间为等待时长加 5 秒。返回 `pending` 且 `waitTimedOut: true` 表示这次等待结束，**不表示申请取消或过期**。可以先做不依赖资料的工作，再使用原 `requestId` 查询或等待。查询不产生新申请或新的待办通知事件。

| status | 下一步 |
| --- | --- |
| pending | 仍待用户决定；稍后查询同一请求。 |
| approved | 使用 `claim` 领取用户批准范围，然后 `read`。 |
| denied | 用户已拒绝。停止等待，不自动重新提交。 |
| expired | 待审批或授权已到期。不自动重新提交；确有需要时向用户说明。 |
| cancelled | 申请已取消，不再批准。 |
| revoked | 用户已撤销授权，停止读取。 |
| unauthorized | 当前会话或授权不允许这次访问，不能靠换请求标识绕过。 |
| service_unavailable | 服务不可用；检查应用状态。不要用重提申请处理网络错误。 |
| invalid_request | 输入不合法或操作与终态冲突；检查原请求状态。 |

```json
{"command":"claim","requestId":"REQUEST_ID"}
{"command":"read","requestId":"REQUEST_ID","itemId":"demo-server","fieldId":"host"}
```

授权仅包含用户批准时选中的字段，新增信息或字段需要另行申请。已经批准的请求不能再取消；如需停止已有访问，由用户撤销授权。放弃尚未处理的申请时可显式发送：

```json
{"command":"cancel","requestId":"REQUEST_ID"}
```

桌面上的聊天名称及用途是 agent 自述，不能作为可信身份凭据。CLI 没有批准或拒绝入口。收到拒绝或过期时，agent 不得自动循环重提、自动扩展范围，或将重新提交当作轮询手段。

自动化已覆盖核心公开接口、真实 CLI 子进程及 Flutter 无窗口组件测试。真实桌面手动执行“等待超时后批准，再查询原结果”的验收仍需用户配合；本任务没有操作用户桌面。
