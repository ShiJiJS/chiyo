# 普通附件：HTTP/CLI、真实超时与进程中断

2026-10-19，源码`4850b712753ae330da5361de71608f424fc2fd6a`。接续[加密登记/归档](issue37-delivery-storage.md)，连接file-fetch/status/release与独立CLI，schema21/备份9、8、7选择不变。**仍是#37检查点：最终容量/RSS和全写入口预算余量未完成，正式bootstrap仍不注入文件驱动或宣告能力，#38真实界面另行接入。**

接口与不确定结果

Host显式启用且具备文件repository/驱动时才宣告information-attachments.v1；文件目录/申请要求明确v2，旧客户端失败而不丢弃文件。专用HTTP路由严格JSON、重复键和16KiB上限，不接受任意写入目标或私有租约。CLI默认2、显式1拒绝，先检查协议与能力，私密会话不进入公开JSON响应。

领取等待30秒，连接/响应丢失返回delivery_unknown及原operationId；释放丢失带原deliveryId。CLI不自动重放。领取丢失时可能没有deliveryId，故file-status可二选一提供原operationId或deliveryId；释放仍按deliveryId。按操作查询只观察所属会话已登记事实，不排在原文件IO后，不创建副本，也不返回路径、原文件名或摘要。not_found不证明原排队请求将来不会登记，不能自动换ID重试；ready事实也不授予新读取权。

实际验证

真实SQLCipher宿主和Windows驱动，启动独立JSON-lines CLI，混合申请只批准文本和附件、拒绝第三字段。批准前拒绝、目录无原文件名/内容、文本read与文件专用交付分开。测试让原生写入在登记后阻塞，实际等待30秒取得unknown，原操作查询立即返回preparing；另一会话看不到记录。放行后显式领取原副本，字节完全一致、重复ID仍为同路径/一次写入；释放/重复释放不重建，新ID沿用原授权，撤销清理并阻止新领取。

另启独立包/真实SQLCipher worker，在副本完整写入并核验后、ready保存前报告自己的VM PID并等待。测试终止这个PID，等待原launcher结束，再重新打开加密库：preparing身份仍在且六字节副本完整，核对后标unknown/restarted并安全清理，不重放，数据库原文件仍完整。探针依赖离线解析并核对与正式storage锁版本一致。它与此前人工构造孤立回执的检查不同，是实际进程中断。

首次崩溃测试被Dart构建进度stderr的过严断言中止，未执行恢复断言；随后只允许已知进度字样，并在后续断言前登记恢复清理，实际测试通过。原失败日志保留。该失败轮的一份六字节合成副本未自动回收，自动审批审查拒绝其非递归删除，理由blocked by policy；已保留且没有换途径删除，位置和已知字节见原始cleanup-rejection记录，不是真实资料。

完整`scripts/check.ps1 -Offline`退出0：CLI89/13、core259/0、storage148/6、desktop141/0，共**637通过/19原生opt-in跳过**，四包严格分析及四份原锁通过。新增6项覆盖核心2/CLI2/实际SQLCipher独立CLI1/真实worker中断1；[固定原始证据](evidence/issue37-delivery-cli/verification.json)包含各轮和完整日志、脚本及source/lock Git字节摘要。没有子Agent、Computer Use、用户资料/配置/整包更新或服务器同步。

下一步统一各持久化写入口的元数据预算，为已登记交付后续终态预留可证明的空间，再测完整库/保留版本/备份和副本组合峰值。#37七项整体验收仍未勾选，随后按#38→#30推进，#23/#18独立保留。
