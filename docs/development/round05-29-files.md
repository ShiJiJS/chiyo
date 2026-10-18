# D7 Windows 文件凭据实施进度

2026-10-18，当前主会话单独实施，不使用子Agent；服务器同步已按用户要求排除本轮，先完成Windows。复用已存在且干净的 `codex/round05-29-files` 工作区，从集成6657429及Windows范围修订4be0796接续。

## 首条 AWS 纵向流程

公开核心服务提交固定AWS计划，服务附加可展示的空配置/禁用metadata、pager、自动提示常量；拒绝非静态default文件、其他profile、credential_process、SSO、重复键。普通字面占位符不替换。类型化内部引用只在服务生成的有效计划/存储读取中接受，Agent输入不能提交内部材料。

服务占用后创建具有受限DACL的空目录，路径/目录身份只进入加密仓储的执行私有字段及私有领取DTO，不进入公开执行响应。CLI独占创建空材料文件，经私有能力接口登记真实文件身份，审计成功后才写入凭据；应用会话证明不交给子进程。正常终态的清理核对目录和文件身份，通过打开句柄删除，拒绝重解析点、硬链接、外来文件，不递归遍历删除。

受控真实子进程已验证：接收到准确AWS文件字节、私有空config、字面参数保持原值、没有继承其他认证变量。子进程另用Windows ACL提供程序独立确认文件及目录protected DACL，只允许当前用户和SYSTEM；退出后两个文件和材料目录均不存在，执行状态exited/exit0与cleanup complete分别核对，不能重放。

红/绿记录在工作区 `.d7-aws-plan-*.log`、`.d7-aws-file-policy-*.log`、`.d7-aws-runtime-*.log`；核心16项与CLI11项定向回归及两包fatal-infos分析通过。这包含既有Token测试，不是新增27项。仅虚构材料，没有真实账号/密钥或正式库。Computer Use未使用，没有持久打开的测试应用。

## 尚未完成

真实AWS产品执行链、SSH参数交付/已确认主机快照及对应原型页面、清理失败/异常/重启核查、SQLCipher重开、完整协议负例和全套主集成回归均待后续。当前未知状态保守保留材料并标needs_check，不冒充自动恢复清理完成。未合并到主集成，#29保持OPEN，不能将此版本作为正式文件运行或凭据备份交付。

文件权限与清理集中在受管材料模块；实现核查依据：[CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)、[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)、[SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle)。真实DACL检查与子进程行为作为验证，不以“调用过权限函数”代替结果。
