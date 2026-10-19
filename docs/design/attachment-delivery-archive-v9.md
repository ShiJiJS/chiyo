# 普通附件交付归档：完整备份格式9

2026-10-19，扩展[格式8](attachment-backup-v8.md)，仍使用同一SQLCipher4双表分块容器及完整认证顺序。文本快照version为9时，tables在格式8全部表之外增加information_deliveries(id,payload)。存在任何交付事实才输出9；只有附件/文件模板输出8，纯文本输出7。新读取器兼容1–8；旧读取器必须拒绝9。

payload采用严格JSON对象和19成员显式白名单：id、operationId、requestId、grantId、field、fieldVersion、attachment、fileName、mediaType、byteLength、sha256、createdAt、expiresAt、state、targetState、reason、cleanupError、restoredAt、finishedAt。field为原四项名称/身份摘要，attachment为不可变版本引用。private lease、sessionBinding、runtime及路径均不是此格式的合法成员；不得以黑名单删除几个秘密字段后透传其余属性。

ID唯一，生命周期状态和时间组合须合法，归档引用的附件版本/名称/MIME/大小/摘要须匹配，历史中的字段归属不得矛盾。正文已按保留策略清理时仍可保留不可用版本元数据及事实，不伪装成空文件。延后恢复仍应用原审计截止；不会因恢复延长授权或重新赋予文件读取能力。

恢复仅安装历史事实：本地runtime=false、sessionBinding=null、lease=null，并记录本次restoredAt。ready等原状态表示当时事实，不代表当前存在可领取路径；不能据此重建文件或恢复会话。此前Windows受管副本仍由原实例私有登记管理，便携备份绝不用于清理源机器任意路径。

元数据完整验证及BLOB整文件校验通过后，所有信息/附件/历史/交付归档在同一接收事务提交；任一末段插入失败全部回滚。用户恢复确认重新验证原预览来源，使用同一已认证句柄。容量/JSON/重复键/时间戳/块结构等所有格式8约束继续适用。

实际SQLCipher、Windows占用重开、恶意归档、末段回滚及混合凭据历史证据见[实施记录](../development/issue37-delivery-storage.md)。本合同未宣告Agent文件能力，HTTP/CLI、最终预算余量及#38客户端仍待。
