# Windows 完成状态超时排查

2026-10-18；主会话单独处理，服务器同步暂停。

旧D8原生失败只留下20秒未完成，无法区分启动、退出或清理阶段，因此不能唯一归因。0.4.0+7随包AOT程序的带诊断原生三轮通过；每轮60次短SSH的旧版本压力测试第一轮通过。随后为避免新旧worker协议混用，主动中止后续轮次并移除本任务确切标记的localhost容器，不将中止轮计为通过。300次并发快速命令探针没有发现进程身份丢失；没有据此加入未经证实的进程创建重写。

定位并红测复现了一条完成回执丢失路径：Windows读取ready文件的句柄保持打开时，后续started/exited原子替换同一文件会失败；原实现两秒重试后worker以70退出。目标仅执行一次，但监督方无法取得可信完成事实。修复改为ready、started、finished各发布一次、之后不覆盖。真实Windows读句柄保持至worker结束的回归通过，既覆盖ready也覆盖started，不延长超时、不重试启动、不降低身份和清理检查。

内部worker握手增加receiptVersion=2。合成旧worker回归在缺少校验时收到了不应收到的启动确认；修复后放行前拒绝、未启动、许可不重放且有明确start_failed。该变更不改变公开协议v1或数据库schema16，更新时必须整包替换应用、CLI和worker。

开发阶段14项原执行回归、6项协议/锁/启动门控/提前崩溃回归通过。旧超时日志保留，不以本机制的复现冒充旧事件唯一原因。测试编写中的编译/分析失败也保留；确定的业务红测分别是receipt-red和protocol-red3，不将测试草案故障冒充产品红测。

固定f3e3472完整检查351项（CLI56/Core130/Storage61/Desktop104）及严格分析零跳过通过。a76629d只增加版本元数据/交付说明；其同版本AOT适配器/worker与真实窗口完成三轮，每轮配置60次重复审批/短SSH，再验证主任务输出、重放拒绝、历史和运行中Runtime停止/DPAPI重开。配置通过HOSTED_SHORT_RUNS=60传入，原始日志记录整项完成，不逐次打印数量。

实际通知探针第三次有界尝试：Shell accepted/READY，Computer Use一次窗口枚举与一次应用枚举均没有返回目标通知，未发出输入操作。60秒无真实点击，探针非零退出、无VERIFIED。用户随后确认不在电脑前，保留人工验收，不自动重复。控制会话已reset，隔离测试窗口结束；不改变系统通知设置，不据此推断OS是否展示或权限故障。

用户随后明确允许由Computer Use点击，第四次配合临时Debug诊断草案再次有界尝试。仍没有可点击通知目标，且一次捕获画面与选定窗口不符，未发送任何输入，停止该通道并reset。60秒无真实回调、无VERIFIED；未取得可核对的原生阶段日志，不能据此断言Shell未展示。该诊断草案未保留到发行源码，不再重复通知。#23仍开放。

另一次压力轮在Computer Use读取Flutter辅助功能树后，业务断言走完，但框架结尾报SemanticsHandle仍活动；此轮保留为失败，不放宽断言。之后三轮没有外部UIA观察，全部通过。

## 实际GUI进程死亡与随包程序

QA源码2918010增加独立入口tool/windows_hosted_crash_probe.dart，生产main不导入它。仅显式WINDOWS_HOSTED_CRASH_QA=true及指定synthetic配置才运行；临时SQLCipher/DPAPI库、port0、合成localhost密钥。自动批准仅为准备OS故障场景，不冒充用户审批。

第一GUI在实际SSH运行后直接结束自身，跳过runtime.stop/finally/仓库关闭；外部控制器确认退出，再启动同一GUI二进制的核验模式，重开原加密库并执行与正式启动相同的维护。确认原SSH/Job仍活跃、文件保留；unknown且无exitCode/finishedAt；旧会话拒绝；实际Job结束后文件清理、仍unknown、不恢复次数。7项事实通过。之后换成0.4.0+8包内worker再次通过，形成两次进程死亡验证，而非仅关闭runtime。

2918010干净源码构建0.4.0+8，再次351项零跳过、严格分析及Release编译通过；中文/空格解压、无SDK/Git子进程PATH的11项CLI/hooks与SQLCipher4.19.0/DPAPI检查通过。包内实际CLI/worker另跑一轮真实Windows审批、10次短SSH、主任务及重开闭环通过。它与三轮压力分别记录，不合并计数。

原始日志、GUI探针二进制清单、包manifest与各SHA见evidence/windows-timeout-fix/verification.json；临时GUI私密会话、数据库/密钥及VM日志不归档。主会话自检实现与规格，无独立Agent评审。测试窗口、worker/SSH和本任务容器均退出，Computer Use会话已reset。未改UI样式、用户资料库或Codex配置；服务器同步暂停。

## 重跑GUI进程死亡探针

先在desktop目录编译专用入口（不能作为正式应用分发），再由根目录的SSH夹具控制器运行：

```powershell
# cwd apps/desktop
flutter build windows --debug --no-pub --target tool/windows_hosted_crash_probe.dart --dart-define=WINDOWS_HOSTED_CRASH_QA=true
# cwd repository root; worker取自所指定CLI旁
python scripts/qa/ssh-fixture/run.py --crash-probe apps/desktop/build/windows/x64/runner/Debug/info_desktop.exe --cli-executable <absolute-info.exe>
```

GUI探针配置/旧私密会话及运行库保留在忽略的synthetic目录，仅布尔结果可以导出。失败也只结束控制器自身启动的GUI进程，外层验证具体容器标签后关闭夹具，不调用默认profile、47125或个人infos。
