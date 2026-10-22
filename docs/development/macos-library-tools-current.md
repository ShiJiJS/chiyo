# 新信息库审批界面的真实 GH/AWS 联合验证

后续已补[独立 Release 进程的工具历史重开](macos-tools-history-current.md)：
当前实现的 3 份授权／5 条执行保持、旧会话拒绝、接收端不重放通过。
后续轮采用合成 owner 决定，不替代下文已完成的真实 GUI 审批。

2026-10-22，#44/#48。冻结QA源码`dad1362945939f1069274223f3d2ebe85b21b42f`，
生产实现与候选`5a509968400b2d140a69a02f89935c5db4e935ee`相同。本轮没有修改产品代码。
[原始结果、构建输入及摘要](evidence/macos-library-tools-current/verification.json)。

## 实际运行与观察

运行既有`macos-tools-ui.py --bundled`，采用普通WidgetsFlutterBinding、生产启动器、
SQLCipher及真实沙盒worker；仅合成库、内存密钥和随机QA应用身份。不是tester审批，
不读个人GH/AWS登录，也不触发Keychain或系统权限申请。八项锁定依赖、严格分析、
Release构建、签名与entitlements步骤退出0；662份构建输入及副本逐项核对，唯一允许
的副本修改是QA bundle identifier。

先把完整应用移动到`移动 中文 空格/info_desktop.app`，再启动。GH2.102.0和AWS2.38.1
来自生产构建装配的App Resources，未在构建后补工具。工具字节、ThirdParty manifest
及沙盒entitlements与保留候选包对应项目一致；不是最终ZIP普通入口联合验收。

CUA在真实800×600内容窗口核对用途、工具路径、工作位置和本机接收端，完成三次
凭据使用批准：正确AWS合成秘密、错误AWS合成秘密、GH无效合成Token。审批正文的
CUA AX覆盖有限，实际依截图坐标与原生滚动条拖动操作；确认对话框能读到语义。
因此本轮不证明完整VoiceOver、中文物理输入或全部正反向键盘导航。截图已显示在
会话中，没有把它们称为落盘PNG证据。

| 实际工具操作 | 直接结果 |
| --- | --- |
| AWS GetCallerIdentity | 签名被独立本机接收器接受，退出0，返回合成身份。 |
| 同一授权 PutParameter、GetParameter | 均退出0，读取结果包含写入的公开合成值。 |
| 另一授权使用错误AWS秘密 | 接收器实际拒绝签名，AWS退出254。 |
| GH `api user --method GET` | 真实GitHub HTTP401、退出1；明确不是成功登录或普通网络失败。 |

独立接收器计数为3次认证成功、1次认证失败，动作与表中相同。五个操作ID分别重复
提交，均返回原executionId，未重新执行；授权截止时间保持。四次AWS材料清理均为
complete，GH为not_needed；各次输出检查未包含三个合成秘密前缀。原始CLI输出不
公开，仅保留夹具断言及不含秘密的结果。接收器配置和私密关联资料未归档进Git。

CUA随后实际查看授权历史中的三份授权。正确AWS授权显示三次使用，对应identity/
write/read，退出0，截止时间12:54:59不变，最新材料“已清理”；GH历史显示
gh-invalid、退出1。最后通过实际⌘Q正常退出0、库关闭一次，Flutter异常计数0，
没有强杀兜底。接收器由监督脚本terminate，不把其-15记成应用正常退出。

## 清理与未完成条件

驱动注销并删除测试App/dSYM、编译缓存及有归属标记的合成库；归档后额外移除剩余
源码副本与接收器合成配置，释放约22.9 MiB。再次逐项核对固定预览7971项载荷、
strict签名与PID53592，保持不变。项目测试/预览范围只剩固定预览一份完整App，
生成dSYM为0；SDK缓存、候选ZIP和私密备份/恢复密钥保留。

本轮只有一个应用进程，不算独立重开或最终普通换包。既有外部目录选择/重开、SSH、
容量和其他界面证明仍各有适用版本，不能把本次组合扩大成原复合条件全部完成。
GH真实账号正向场景仍缺专用凭据；不为模拟HTTP200放宽生产接收配置。
#44继续OPEN、3/6，#48保持3/6，#50保持2/6。系统通知、真实睡眠/唤醒、物理IME/
VoiceOver、最终普通包Keychain升级及用户提供的干净环境仍依原票据验收。
