# Mac 工具版本拒绝、程序变更和支持版本重审（#44 / #50）

2026-10-22，仅 `codex/macos-adaptation`。本轮补真实工具版本变化的独立证据，
生产业务、工具版本声明、打包和已允许的普通预览均未改变。
[31 份分轮资料与摘要](evidence/macos-tool-version/verification.json)。

## 版本与边界

生产仍仅声明 GH2.102.0、AWS CLI2.38.1 和本机系统 OpenSSH10.3p1 的 ARM64 路径。
本轮下载 [官方 GH2.103.0 Release](https://github.com/cli/cli/releases/tag/v2.103.0)
中的 ARM64 ZIP；发布方资产摘要和实际下载均为
`54be566e9f614bea5de8021e95b9ad33dfee3b9d2ea120c9c294c00defaa5014`，
14,105,033 字节。其可执行文件为38,914,960字节，SHA256
`1ffcdcff76db02ff4f9de0fbf784ed4b6d18e434e89450db314b3f77d0f9443b`。
它用于**未声明版本的拒绝测试**，不据此宣传支持2.103.0。

隔离 Release 使用生产 GH/AWS 组装器、App Sandbox、继承沙盒的随包 AOT worker，
额外只在 QA 资源目录放入两个真实 GH 副本；生产 ThirdParty 清单和入口保持。
可变槽原始副本与固定 GH2.102.0 的39,834,784字节、摘要
`8a4258433c81106343144857750316241759d06dcf16265cf3c4864a8f2f2ad6` 一致。
App/worker entitlements、初次深度严格验签和恢复后的验签均入证。

本轮测试入口注入一个检查器包装：**先真正调用生产 `inspectCredentialExecutable`**，
只在一次操作中暂停返回已经取得的身份，让监督脚本原子替换自有可变槽，再返回该真实
身份。没有伪造摘要、版本、时间、进程启动器或执行结果。此时默认生产托管执行器再核对
程序身份，验证检查与启动之间的变化。它是受控时序测试，不能说成普通安装中的自然升级。
新旧真实二进制大小不同；本轮不宣称验证了相同大小/mtime下的纯摘要变化。

独立身份
`org.shijijs.agent-info-manage.qa.tool-version.146474335bf14c7fbdd600e87ac81100`，
使用真实 SQLCipher 和内存合成密钥，系统 Keychain 调用与主人系统确认均为0。
只向 App 传 HOME/USER/LOGNAME/LANG 和系统 PATH；实际 GH 使用生产创建的空配置、
临时 HOME 和无效合成 Token，不读主人 GitHub 认证。两个凭据申请均由 CUA 在生产审批
界面审阅确认，默认15分钟；没有用 QA owner API 代替批准。

## 第二轮完整结果

| 步骤 | 实际结果 |
| --- | --- |
| 基线 | GH2.102.0 的 `api user --method GET` 经真实托管 worker 启动，GitHub返回HTTP401/退出1；不是网络失败，也不是成功登录。 |
| 已批准范围内请求较新版本 | 用同一许可指向真实2.103.0，生产检查返回 `unsupported_tool_version`、`operationClaimed=false`；没有新执行占位。直接生产检查和新的 request-use 也拒绝2.103.0，没有新增申请历史。 |
| 未领取操作恢复 | 将上一次被拒绝的同一 operationId 改指向支持的2.102.0，成功领取并实际运行，HTTP401/退出1。符合 ADR0010 的逐操作核查；不错误要求整个期限只能运行一条计划。 |
| 检查后换程序 | 真实检查已记录2.102.0身份后，由监督脚本把同一自有槽换成完整2.103.0。操作先登记，随后实际 `prepare_failed / executable_changed`，`processStarted=false`，退出码为null；没有凭据目标启动。 |
| 恢复和重复查询 | 原程序字节、mode和mtime精确恢复，App再次deep/strict验签通过。恢复前后查询同一失败operationId仍返回原executionId及失败事实，不重放。第一份许可固定截止03:39:04不变（界面显示至秒，代码另核对完整时间值）。 |
| 撤销和重新批准 | 显式撤销旧许可后，新操作返回 `grant_revoked / operationClaimed=false`。重新通过GUI批准支持版本的新申请，再次真实GH调用HTTP401/退出1；随后也撤销新许可。新许可有自己的截止，不把它说成旧许可续期。 |
| 退出重开 | App58633正常⌘Q/退出0；App59368独立重开，SQLCipher中两条许可、四个操作的状态/退出码/结果代码逐项相同。实际历史两条分别3/1次操作，失败回执仍是“尚未创建进程、无退出码、executable_changed”。再次⌘Q/退出0。 |

第二轮共有4个登记操作，3次实际凭据目标启动，均为预期无效 Token 的 HTTP401/退出1；
另1次准备失败、没有退出码。实际进程采样观察到 App58633→worker58839→GH58840、
worker58865→GH58867、worker59109→GH59110。App直接启动的版本探测单列，不能算
凭据目标执行；未采到每个短暂探测，不由采样缺失推定它们没有运行。

四个操作的重复查询、恢复后的失败查询均不重跑；未支持版本失败不占用operationId。
14条留档语义命令不包含轮询、版本探测或全部清理调用，不能称为全部API请求数。
四个操作的文件清理实际为 **`not_needed`**，字符串凭据没有文件材料；不改写为complete。
所有实际输出均未含合成Token原文。内存输出只保存在本轮测试报告，不能把报告中的输出
当成数据库/授权历史持久化了完整命令输出。

## 首轮失败与复跑

第一轮完成真实GUI批准及一次GH HTTP401后停在QA清理预期：脚本只等待complete，
实际字符串凭据为not_needed。保留首轮报告、实际回执、日志和源码摘要；通过⌘Q结束，
库关闭一次、Flutter异常0，监督程序因complete=false失败，没有用强杀结束应用。
没有将该轮加入最终4个操作/3次启动的通过计数。

QA修正只调整该状态预期，并让监督程序显式记录子App退出码。第二轮完整通过，
两次App均退出0、库各关闭一次、Flutter异常0，无强杀兜底。严格Flutter分析、Release
构建及三次签名/恢复相关检查通过。生产代码和工具版本锁相对5ddda3c没有变化，
没有为仅新增QA而重复累计上一轮196项桌面测试。

复跑前先将上文官方ZIP下载到项目`.downloads/gh_2.103.0_macOS_arm64.zip`，
QA会强制核对固定SHA256。已有生产官方归档由组装器核对；不安装到系统：

```sh
python3 scripts/qa/macos-tool-version-ui.py build/macos-adaptation/NEW-tool-version-run
```

按controller.json选择准确隔离应用，只批准合成基线与恢复支持版本两个请求。
程序替换/恢复由监督脚本自动完成，完成后正常⌘Q、独立重开核对历史，再正常⌘Q。
不要在主人稳定安装或生产ThirdParty中替换工具，也不要把真实凭据放入这个夹具。

## 清理与票据状态

两轮临时 App/dSYM、Flutter编译缓存、独立库/材料、额外工具副本和原程序备份均清理，
测试应用取消LaunchServices注册；官方约14MB验证归档作为可复跑输入留在项目下载缓存。
本机稳定4690e79/PID53592、生产空v1目录设置未改变。7971项字节/模式/链接及strict签名
再次核对，项目（不含固定SDK/工具缓存）只剩1份可用App、0生成dSYM。

本轮证明较新未声明版本拒绝、操作身份变更拒绝、支持版本恢复与GUI重审路径。
**没有将2.103.0纳入支持版本，也没有完成其独立正向验收或普通安装升级。**
#44仍OPEN、3/6：第3项的完整版本升级/重新验收及最终同包门槛保留，不以负例整体勾选；
第2/6项及#50最终批量换包、Keychain、通知/备份恢复/Codex和干净用户验收继续开放。
Windows/main/CI未操作。
