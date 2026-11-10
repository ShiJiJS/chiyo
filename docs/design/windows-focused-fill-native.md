# Windows焦点填充输入端

2026-10-19，#35的Windows输入端已实现，见[完成记录](https://github.com/ShiJiJS/chiyo/issues/35)。业务边界以[填充合同](local-focused-fill-contract.md)为准；[338445a/3e98ec6](https://github.com/ShiJiJS/chiyo/issues/35)已配置构建绑定driver并生成较早QA整包，Windows源码按束校验成功条件启用；用户旧包未变。支持记录覆盖一个真实Win32密码控件和当前可见、系统前台中的Codex内置浏览器合成页面，不能推广到所有工具/页面。

Agent经私密会话调用`focus-target`，只得到应用规范路径、当前文件SHA-256和当时是否就绪；无PID、窗口/控件身份、网页标题、字段值、DOM或截图。需要协议2及`credential-focused-target.v1`、既有填充/复用能力。查询不固定之后的焦点、不审批、不输入；批准后仍由Agent点击空密码框。

桌面EXE编入同一配置broker的SHA-256，由本地MethodChannel给出同目录固定路径/摘要；启动前校验，失败先于资料库打开。构建sidecar和分发JSON不作为运行时信任源。配置后的`WindowsFocusedFillDriver`只启动固定程序`info-focus-broker.exe --broker-v1`，申请不能更换辅助进程或环境。启动前后核对文件；子进程再次核对自身SHA并持有文件句柄。初始环境仅SystemRoot/WINDIR，没有授权证明或托管凭据。秘密不经CLI参数、环境、文件、普通JSON响应或日志。

内部stdin传长度帧，stdout只回严格元数据JSON；意外stderr、额外字段、坏JSON和尾随内容使通道失效。Dart默认分别限制写入和回执等待为4秒；取消先终止子进程，关闭共享同一排空Future。原生进程另有30秒上限和真实父进程退出观察，隔离UIA阻塞，不在审批队列里等待控件。

私有帧以小端uint32长度开头（2–16384字节），随后version=1/opcode：

| opcode | 内容 | 允许结果 |
| --- | --- | --- |
| 0 观察 | 父PID、辅助程序SHA的32字节 | ready/application或refused/原因，然后退出 |
| 1 准备 | 同上，再加应用SHA、uint16路径长度、UTF-16路径 | prepared/application或refused/原因 |
| 2 输入 | uint16单元数和UTF-16单元，最多16单元 | sent、refused、partial或unknown |
| 3 关闭 | 无载荷 | 退出，不输入 |

一进程只准备一次操作，最多接收4096个UTF-16单元；不解释控制字符、快捷键或Enter，不拆代理对。私有缓冲和INPUT数组尽力清零，不声称抹除Dart不可变字符串或抵御内存取证。

核验WTS活动/解锁会话、Default输入桌面、实际前台/原生焦点、UIA密码Edit的启用/可见/可写/键盘焦点及稳定RuntimeId。使用CUIAutomation8/IUIAutomation2，关闭自动置焦，连接和单事务超时各500ms。仅查询ValueIsReadOnly技术属性，不查询Value。

核对进程报告的镜像路径对应文件当前SHA，并持有拒绝写入/替换的共享读句柄；不是内存映像或程序行为的沙箱证明。冻结应用/提供者PID及创建时间并保留句柄；提供者为应用自身或通过未复用父进程链到达应用，同用户/会话且不高于输入端完整性级别。

同用户桌面使用受限DACL的Local命名互斥量；另一进程返回busy，不等未来焦点。准备及每批前复核目标、进程、桌面和修饰键；核心逐批核验最新授权/版本/期限并完成审计。每单元发送KEYEVENTF_UNICODE按下/释放；零事件为refused，部分为partial，完整接受后检测到目标变化记unknown并停止后续批次。SendInput不是对控件原子定向，仍有最后核验与事件送达之间的竞态。

未解决的partial/unknown（含审计失败保留的checking）阻止同会话换操作ID或换另一项已批申请重填；活动操作优先返回busy。同ID仍查原事实，所有者确认不续期、不改成未输入；不使其他方式的命令操作失效。

[原生检查点](https://github.com/ShiJiJS/chiyo/issues/35)记录真实CLI/Win32、互斥、未知恢复、无粘贴/剪贴板不变及正常工具文字扫描。只有测试接收器读取自己的假密码作独立比对，生产broker不读回控件。后续[完整用户流程](https://github.com/ShiJiJS/chiyo/issues/35)补齐实际Flutter审批/历史/人工确认、SQLCipher/DPAPI、独立CLI、活动许可重启失效及真实broker父进程退出。当前内置浏览器的正常AX/value遮挡和明文截图反例已有实际观察；DOM聚焦无法切换系统前台时需先切回目标应用再发现ready。SDK辅助功能失败及对照原样留证，没有修改生产可访问性。生产broker默认安装，测试/诊断和故障桩仍EXCLUDE_FROM_ALL，不进用户包；最新验证不是新分发包。

依据：[UIA2超时](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation2-put_transactiontimeout)、[SendInput边界](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)、[进程快照](https://learn.microsoft.com/en-us/windows/win32/api/tlhelp32/nf-tlhelp32-createtoolhelp32snapshot)、[PID复用](https://devblogs.microsoft.com/oldnewthing/20150403-00/?p=44313)。
