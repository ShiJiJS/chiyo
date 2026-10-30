# 知予 Mac M05：真实备份与恢复接入记录

对应 [#74](https://github.com/ShiJiJS/agent-info-manage/issues/74)，归属 #69 后续功能。
本票不阻挡已准备的1443d358候选换包；本轮未替换App或请求系统授权。

## 2026-10-30：原生文件选择的Owner资源边界

新增 `OwnerWorkspaceBackupFiles`，复用 `NativeBackupFilePicker` 四类原生选择方法。
页面只接收随机不透明ID、显示文件名、种类和版本，路径留在Owner适配器内部。
每种选择保留一个当前对象；取消/失败保留先前选择，重新选择使旧对象不可解析。
解析校验完整资源和用途，不能通过猜ID、更换名字/版本或混用输入/输出获得路径。

绑定OwnerLibraryScope：选择前后均核对服务及原库代次，恢复成功或关闭后到达的
选择不能应用到新库。并发文件面板拒绝，原生异常仅映射为通用错误，不把包含私有
路径的系统错误直接传到页面。没有读取备份/密钥正文，没有发布文件或恢复资料。

`owner_workspace_backup_files_test.dart` 4项通过，覆盖中文空格同名文件/取消/重选、
篡改资源/种类混用、换库和关闭期间迟到、并发/原生异常/相对路径，以及实际
NativeBackupFilePicker的四种MethodChannel调用映射。输入为模拟原生通道，不是
真实NSOpenPanel/NSSavePanel验收。desktop静态分析通过；首次编译补齐OwnerInbox
扩展导入及测试用空MemoryInformationRepository，不涉及产品存储结构修改。

下一步：持久操作意图/结果和文件发布失败核对、实际WorkspaceBackupSource、
OwnerWorkspaceHost/picker组合、恢复后重绑与独立进程往返。本轮模块尚未挂入正式
组合，现有备份页继续如实显示未接入；不把文件选择边界称为备份功能完成。
