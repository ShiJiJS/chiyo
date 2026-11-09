# #99 验收证据：服务器批准，设备执行凭据操作

2026-11-09。#99 实现与本票自动验收已完成，代码a027defe已推送，GitHub完成评论与Closed状态已回读确认。#100–#102 尚未完成，没有统一候选、日常安装或真实资料迁移。以下全部使用隔离合成资料、TLS、SSH账号/密钥和无外部权限接收程序，没有个人钥匙串或 Windows CI。

## 实现及验收对应

| 工单要求 | 实际实现和证据 |
|---|---|
| 复用原执行程序，App退出仍可使用 | 正常JSON-lines CLI和逐命令info-codex接原CredentialExecutionHost、原生worker及受保护设备后台。服务端不执行命令。正常App分别批准SSH和Token，退出App后实际执行并清理。 |
| 命令在AI设备运行 | DeviceCredentialLaunch在设备核对程序版本/摘要、cwd和原计划；设备保存文件/进程身份。系统/usr/bin/ssh连接独立Docker账号，Token/静态AWS文件由合成gh/aws接收程序读取；不接真实GitHub/AWS账号。 |
| 材料私有、成功失败均清理 | 首次材料私有交付，后续只返回原操作元数据。设备先记700/600清理登记再写材料/启动；服务器不查设备PID或创建明文材料。正常结束、启动失败、CLI崩溃、服务完全离线后的清理与补报告均有实际检查。普通CLI输出过滤，登记不含材料、聊天读取证明或输出。 |
| 原许可跨普通重启，不延长或复活 | SQLCipher保存事实，私有设备/原聊天绑定核对后恢复；混合字段保持原范围、证明及独立期限。SSH会话内不限时跨重启，原聊天结束失效；固定到期、撤销、停用、换材料、备份恢复均不复活。旧单机打开/关闭行为保留。 |
| 断线不重复启动 | 原操作先查状态；丢首次材料回复、SQL提交与私有快照间崩溃、设备后台接受回复丢失、活跃连接记录被移除均不产生第二次执行。结果无法确定则标明未知。两个独立Codex进程竞争首次操作，只形成一个后台、同一执行和一次操作。 |
| 审批保存结果不明可准确恢复 | credentialRuntime3加密保存准确原审批命令；重开只核对同一回执及已存事实。失败查询继续禁止相关申请使用；确认未提交不生成许可，确认原提交只结算原范围/期限。错回执、矛盾的缺失回执、损坏私有对应关系不能放行或覆盖原证据。旧inner1/2可读，但没有原命令的旧禁用记录仍禁用。 |
| 聊天结束、断线、服务重启各自准确 | 普通重启保留原有效许可；撤销/聊天结束阻止后续命令，不假装收回外部已发生结果。结果不明期间结束/过期，再关闭重开后核对，保留终态与准确历史，不让旧进程闭包覆盖。 |
| 正常App和能力说明齐全 | 复用纯Dart OwnerWorkspaceHosts和原插件设置/指纹预览/确认/撤销；仅客户端选择文件，服务器不探测网络。原审批元数据显式v2，旧v1遇到凭据拒绝。声明device-execution、reuse及SSH session-validity；不声明Mac焦点填充。 |

设备后台沿用16条执行/输出上限和完成后30分钟输出保留；控制接口仅回环、准确Host、拒绝Origin并核对私有证明。设备配置摘要与原聊天逐次核对；其他聊天不能读取保留输出。活跃执行拒绝停止，活跃或状态不明时不因超时另开后台。

正常App的主机文件导入复用原解析/插件/版本/回执规则，预览逐条核对来源、指纹和替换范围；原始文件最多1MiB，最多32份选择、固定30分钟清理。丢上传回复查原选择，丢导入/撤销回复查原回执。服务变化标记已包含凭据申请，App开着时新待办能刷新。

## 最终检查

日志均在 `local/server-first-stage/`，不能将重叠回归数累加成独立场景数。

| 检查 | 实际结果 | 日志 |
|---|---|---|
| Mac服务整组＋审批异常恢复核心＋加密存储 | 76项通过（服务43、核心16、存储17） | a09-uncertain-final-mac.log |
| Linux ARM64同组 | 67项通过、9项Mac原生条件跳过 | a09-uncertain-linux-full.log |
| 正常App主机信任、SSH会话许可、Token固定期限、退出App后原生使用；实际TLS丢回复恢复 | 5个场景通过，SSH/Token为其中1个连续场景 | a09-uncertain-app-final-tests.log |
| 最后结算修正后的App原批准/撤销丢回复、加密重开核对及原审批回归 | 4个场景通过，与上一组重叠 | a09-uncertain-final-app-recovery.log |
| 32个首次锁文件并发、原凭据复用/设备宿主/输出过滤 | 19项通过、6项原平台条件跳过 | a09-private-lock-race-fixed.log |
| 修复后两个独立Codex进程竞争、Token/文件、原许可重开、原操作不重放 | 2个完整场景通过，随后包含于最终服务整组 | a09-host-startup-race-fixed.log |
| 原核心凭据/文件/SSH/复用及期限规则 | 30项通过、1项原条件跳过 | a09-uncertain-core-legacy-regression.log |

相关Core、Server、Storage、App、CLI文件和测试静态分析无问题，见a09-uncertain-core-related-analyze.log、a09-uncertain-server-final-analyze.log、a09-uncertain-storage-analyze.log、a09-uncertain-app-analyze.log、a09-private-lock-analyze.log。全Core分析另有未修改的builtin_information_definitions.dart:7原有大括号提示，没有将其说成全包零诊断。

较早的独立二进制检查使用5391519e的info-codex/info-runtime-worker，ps验证后台确为独立worker；文件命令运行中关闭整个服务，本机先物理清理，重开补交准确exited和清理回执，不重跑。见a09-device-host-standalone-tests.log、a09-device-host-offline-standalone-tests.log及隔离manifest。这些只是阶段二进制，不是#102统一候选；本轮正常App流程另编译当前worker，最终统一匹配出包仍待#102。

## 发现并修复的实际问题

- 凭据申请未参与服务变化标记，App开着时看不到新待办；已修复并由正常App连续流程验证。
- 结果不明只保存禁用标记、原审批结算闭包留内存，重开无法准确结算；现保留准确原命令。混合撤销期间发生聊天结束时，旧闭包还可能覆盖终态历史；已用关闭重开及真假提交组合验证修复。
- 两个首次CLI都观察到锁文件不存在，第二个exclusive create因errno17失败。新增32并发专项在旧代码复现；修复只接受另一创建者留下的普通文件，仍拒绝链接及其他错误、不截断已有锁。未放松双进程“同一执行、一次启动”的原断言。

失败日志保留：a09-private-lock-race-before.log、a09-uncertain-mac-full.log、a09-uncertain-revoke-terminal-before.log。早期测试属性名/错误类型断言错误亦未计作通过。此前长场景默认30秒不足已明确设置场景时限，逐步骤观察及原操作检查不放宽；没有因观察超时重启后台。

## 明确未交付的范围

Mac系统文件面板、个人钥匙串与正式安装集中留#103；Mac焦点填充仍属#51，Windows设备执行及原生能力属#104。Linux仅证明独立服务，Mac专用跳过不算Linux设备执行通过。当前没有#102统一候选，没有迁移真实资料。接下来完成#100回收/历史、#101完整备份/迁入演练、#102匹配候选及无开发上下文Agent试用。
