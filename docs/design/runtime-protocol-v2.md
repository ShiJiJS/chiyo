# 凭据复用协议v2 · #33实施合同

2026-10-18，目标合同，尚未实现；v1历史事实保留。#36已冻结普通附件合同，附件能力在#37实施，本票只声明协商机制，不提前宣告附件或焦点填充可用。

## 协商与旧客户端

新增`capabilities`命令返回服务/随包CLI实际共同支持的`protocolVersions`和能力标识。v2复用能力标识为`credential-use-reuse.v1`；`information-attachments.v1`、`local-focused-fill.v1`在对应票通过并接入后才出现。新CLI先协商，未支持时返回`unsupported_capability`，不得偷偷降级为一次性申请或自行生成新的审批。

v2请求包含整数`protocolVersion:2`，字段类型、未知key、重复key、输入字节上限、标识/UTC沿用v1。旧的v1请求/许可保持v1单次语义，不能仅凭公开requestId或改变请求版本把旧许可升级。程序中新请求默认使用v2，旧格式记录和旧请求必须明确标记其原语义；不增加用户“单次/多次”开关。旧客户端请求v2专有能力明确失败。

## 授权范围与逐次计划

`request-use`保留凭据数组（首版一个凭据）、用途、首条launch和可选readFields，增加v2封套。批准绑定私密会话、凭据ID及固定版本/使用代际、批准的接收配置和固定截止；首条launch作为用途参考，不能被解释为此授权唯一允许的命令。首版接收配置仍为gh_token、ssh_identity、aws_shared_credentials，并按凭据形式和既有接收器约束验证；未批准配置不能借新命令进入。

```json
{"protocolVersion":2,"command":"run-use","requestId":"opaque-request","operationId":"operation-1","launch":{"receiver":"gh_token","executable":"C:\\Program Files\\GitHub CLI\\gh.exe","argv":["repo","view","northstar/agent-skills"],"cwd":"C:\\Work\\northstar","env":{"GH_TOKEN":{"secret":"github_token"}}}}
```

每次run-use都由Agent显式提供operationId和本次完整launch，凭据alias由获准申请固定。每次检查真实接收程序、类型化引用、argv/env/cwd及已有SSH主机规则，不开放通用shell。exe身份在该次计划中捕获并在真正启动前重新核验。第一条命令也要提交自己的操作ID，批准不自动执行。

操作去重键为`(私密会话,operationId)`，另绑定requestId与规范化原输入指纹；一个会话内不能将同ID改绑另一授权。指纹覆盖完整调用launch（字典键排序、数组顺序保留）与requestId，不能只比较最终exe或命令字符串；服务附加材料及exe身份另形成有效planHash，均不可变。响应丢失重试相同ID只返回原事实，不提供第二份启动材料。同ID改变任意输入为`operation_conflict`；新操作用新ID。

服务原子持久化操作/有效计划之后才交付秘密。第一次私密领取返回执行记录及一次启动材料；重复领取返回原记录和`newlyClaimed:false`，不再次返回材料或重新启动。未能确认首次领取是否启动时查询原executionId；超时不是新执行许可。新run-use响应包含`protocolVersion:2, requestId, operationId, executionId, executionState, grantState, duplicate`，没有外部秘密、能力证明或材料路径。

单次操作的准备失败、启动失败、非零退出不使整个授权consumed；同ID仍不能重做。修正后使用新的ID，在有效授权内不再审批。结果未知不能自动换ID重放；CLI只报告事实，由Agent核查后明确决定是否提交新的操作。

授权默认15分钟、可选30分钟，使用不续期。普通字段独立默认8小时（可按普通读取选项缩短）；组合申请批准/撤销/期限分别记录，不把普通字段误绑到凭据15分钟。轮换、停用、删除、撤销、到期、会话结束和服务重启阻止新操作；历史恢复不恢复许可。重试查询不能绕失效重新交付材料。

## 执行、清理与历史

每个操作有独立executionId、冻结计划、材料租约、worker/Job及身份事实。旧v1的request.executionId仅代表单次执行；v2的执行集合必须按requestId查询，不能以“最后一条执行”替代全部事实。历史先展示授权固定范围及期限，再列各次操作、命令、状态和清理；填充稍后会有独立结果类型。

撤销不默认终止已运行命令；一个操作结束只清理其自己的材料。相同授权下同时运行的任务互不误删；宿主崩溃/恢复保留现有Job事实和unknown，不重放。审计保留/备份选择必须检查该授权下全部执行：任一仍运行、结果无法确立或清理未完成均阻止整体删除，不能只看最后一条。输出继续有界、只在持有授权的本机执行宿主内保管并脱敏，不写入执行历史/备份。

## 持久化兼容与测试门槛

请求持久化显式保存protocolVersion，旧缺失值解作1；执行记录为v2时保存operationId、输入指纹、有效计划及协议版本。旧单次attemptConsumed信息保留，v2不得借该位推导整个授权已用完。JSON虽可扩字段，旧程序会误读其含义，因此数据库从schema16升级17、新完整备份从5升级6；旧读取器须明确拒绝新库/新格式，而非丢字段后报告恢复成功。

新读取器兼容旧备份1–5，并将v2完整历史投影写入6，恢复时许可/私密会话/执行能力全部失效。#37附件将进一步扩展schema/备份，须兼容本票6，不再只测试到5；该衔接在本票实现定稿时同步附件文档和工单。不得为了避免格式升级而把新操作历史丢出“完整备份”。

完成需真实核心公开接口、CLI、存储重开/迁移/备份、Windows多次启动/独立材料与桌面状态证据。用v2独立操作测试两条不同命令、同ID并发/响应丢失、失败后继续、跨会话/未批配置/失效、审计失败及恢复不复活；v1旧证据不计作v2通过。此文件与原型不是生产完成证明，#33仍OPEN。
