# 用户限定的 Agent 整理

用户在资料库的当前列表点击“Agent 整理”，创建任务时选择有效聊天及目的。
列表固定为最多 200 个信息项；只有该聊天的私密授权会话能读取任务元数据。
聊天名称和提交者标签由 Agent 自述，不是身份认证。任务有效期最长 30 分钟。

Agent 使用现有 JSON-lines CLI 会话发送：

```json
{"command":"organize-tasks"}
{"command":"organize-metadata","taskId":"TASK_ID"}
{"command":"organize-submit","taskId":"TASK_ID","changes":[{"itemId":"ITEM_ID","baseVersion":1,"directoryId":"EXISTING_DIRECTORY_ID","tagIds":[],"tagNames":["新标签"]}]}
```

`organize-metadata` 返回范围内的标题、公开说明、版本、当前分类/标签 ID，及现有
目录树和标签名称。返回值没有字段值、历史、token 或 session secret。普通公开目录
不因此增加分类名称。任务只能由用户创建，指定聊天之外的会话不能领取或提交。

新顶层分类使用 `directoryName`；已有分类优先使用 `directoryId`。`tagIds` 和
`tagNames` 是期望的完整标签集合；空集合会清除该项标签。每项最多 100 标签，
名称最多 200 字符，整批最多 200 项/240000 UTF-8 字节。额外内容修改键被拒绝。

提交返回 `proposed` 并结束元数据读取。用户在任务页查看分类前后方案，确认时
整批校验信息版本；任一冲突整批不应用。分类和标签与资料变化及修改版本在同一
事务提交。拒绝、取消、到期和冲突均不自动重提；任务不能扩张已有内容授权。

加密库 schema 12 新增任务表，从 schema 11 增量升级。任务的会话绑定不是凭据；
重启后的新会话无法复用旧绑定。已提交的方案仍可由用户查看和决定，但不再赋予
Agent 元数据访问。任务/方案不进入离线备份；恢复不重建其访问能力。

本功能由外部 Agent 配合 CLI/Skill 执行。创建任务后在对应聊天让 Agent 领取；
应用内不接入模型服务。真正的 Windows/Codex 接入仍须实机验收，自动测试不替代。
