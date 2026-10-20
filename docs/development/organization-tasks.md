# Agent 发起的分类整理

用户在 Codex/外部 Agent 说要整理。Agent 使用现有公开目录选择资料身份，再用同一私密会话发起请求。用户只需在“访问审批”核对、缩小范围并批准；批准界面明确允许读取元数据和自动调整分类/标签。应用不创建外部 Agent，也不要求用户在应用创建任务后回聊天领取。

```json
{"command":"organize-request","purpose":"整理服务入口分类","itemIds":["ITEM_ID"],"agentName":"Codex"}
{"command":"organize-wait","taskId":"TASK_ID","timeoutMs":30000}
{"command":"organize-status","taskId":"TASK_ID"}
{"command":"organize-metadata","taskId":"TASK_ID"}
{"command":"organize-submit","taskId":"TASK_ID","changes":[{"itemId":"ITEM_ID","baseVersion":1,"directoryName":"服务入口","tagIds":[],"tagNames":["常用"]}]}
```

请求返回pending。organize-wait/status只查询同一请求，不续期或新建。批准后active，最长30分钟；元数据只包含所选标题、公开说明、版本、分类/标签ID，以及现有目录树和标签名称，没有字段值。指定会话之外的请求均拒绝。用户可撤销正在进行的整理。

Agent 提交后直接原子应用并返回confirmed，不再请求第二次确认。分类/标签、资料版本、修改历史和整理结果在同一事务写入。任一资料版本冲突整批不应用；异步写入最终提交前再次检查会话和期限。失败不回显值，可按原请求状态决定是否重试，绝不静默新建授权。

每次1–200项，每项最多100标签，名称最多200字符，整批changes最多240000 UTF-8字节。tagIds/tagNames是期望完整集合；额外字段修改键被拒绝。新分类只创建顶层，优先使用现有ID。全部任务/结果仍排除备份。

schema12与0.3.0数据兼容。旧active任务不具备autoApply标记，仍只能提交待确认方案，旧proposed方案仍由用户决定；新请求必须经批准才能取得自动写入能力。重启不恢复任何旧会话权限。完整实机及Codex验收仍未完成，不把离屏检查当作原生验收。
