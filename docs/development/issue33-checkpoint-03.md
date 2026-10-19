# #33 检查点3：v2私密领取、CLI与Windows worker

本票仍在开发。核心与CLI路径已接通，**生产服务默认不开放v2**；本检查点不代表schema17、备份6、Flutter或新预览包交付。当前正式预览仍为v1；测试服务显式启用新能力。用户要求的#33→#35→#37→#38→#30顺序及无子Agent要求继续执行。

## 本次实现

- capabilities协商与显式能力开关；未启用服务拒绝v2，不自动降级或另建申请。当前新CLI需显式protocolVersion2测试；生产默认切换留待整个链路就绪。
- 私密操作领取、同输入查询与逐操作结果；公共返回不包含材料。operation-status及重复run-use只查旧事实，16槽满载亦可查询；并发领取仍由核心原子去重。
- 独立CLI及持续宿主执行各次冻结计划。v2错误用operationClaimed，不把整个授权说成已消费；原请求状态显示reusable/operationCount，v1保留旧事实。
- 行为红测发现并修复：私密领取响应没有绑定调用方请求/操作；宿主在提交后抛异常会误报普通未领取错误。现在错配/损坏/重复JSON成员视为领取未知，不启动；宿主异常按execution_unknown且不可自动重试，后续只查原事实。
- 核查发现旧输出仅有界、没有已知秘密打码，不能满足v2合同。新增流式字节遮挡，stdout/stderr各自匹配跨块原文，在Base64编码和保留前处理；完整字符串/文件原字节、AWS已知键值和有限PEM正文行，详情见协议。二进制其他字节保留；不声称抵御变形编码、截图或恶意外传，v1旧行为也不冒称具备此保护。

## 实际验证与限制

[原始日志、源文件哈希和编译物哈希](evidence/issue33-step3/verification.json)。最终核心157项通过、CLI73项通过及2项跳过，两个包严格分析通过，锁定依赖版本未变。跳过的是未配置的真实AWS/SSH外部接收器fixture，不能写成零跳过。中途JSON-lines测试漏导入扩展导致加载失败，及新增代码lint问题均已修复；以final-verified日志为准，不以之前计数冒充最终通过。

CLI/worker已编译，最终CLI回归设置D6_COMPILED_CLI为本轮info.exe，独立JSON-lines进程实际协商→申请→所有者批准→两条命令→重复查询→输出遮挡通过；编译CLI死亡测试也启用。另有真实Windows worker/Job测试：同授权连续三次结果0/7/0，固定期限、不同Job、重复不再启动；两个文件操作不同路径，原字节注入且各自完成清理。接收程序为受控Dart样本，用来核对OS执行机制，不能替代真实gh/SSH/AWS的v2接收配置验收。

新定向18项覆盖并发、满槽、两份文件、失败后继续、私密/宿主回执丢失及边界，并验证实际worker；输出匹配另有300组输入×5种分块和二进制/长前缀/及时输出对照。故障和输出均保留先行为红测记录。

复跑：设置本轮编译物路径后，从根运行 `python docs/development/evidence/issue33-step3/check-package.py --package info_cli --label replay-step3 --analyze`；核心可省略package或指定info_core。编译物当前保留在build/qa-issue33，不属于发布包；哈希对应本检查点生产源码。所有测试为虚构内容，无子Agent，本轮未使用Computer Use，测试HTTP服务、目标进程、worker和临时目录均由fixture退出/回收。

## 接续

下一步处理SQLCipher schema17及完整备份6：保存全部操作及计划，升级/恢复不复活许可，旧读者拒绝；检查归档保留不能只取最后一项。随后接Flutter申请/审批及一授权多操作历史，默认新CLI v2、正式能力启用与真实接收器/重启/多任务验证。本票保持OPEN，尚未通过整项验收不勾选、不开始宣称后续票完成。
