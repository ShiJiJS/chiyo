# #35 原生输入与安全目标发现检查点

2026-10-19，接续6ef4219的SQLCipher/schema18/备份7。实现原生输入进程、Dart私有驱动和`focus-target`核心/HTTP/CLI接口，真实Win32假密码窗口经独立编译CLI验证。#35仍OPEN，生产能力关闭，没有更改Round05界面或用户配置。

## 真实验证范围

最终native-session-03使用运行时随机假密码，含Unicode/中文和首尾空格，原文未先打印或写源文件。独立AOT info.exe连接真实loopback服务，所有者API批准一次；接收器内部比对自己的内容，不向Agent回传值。使用Memory仓储，SQLCipher另由完整存储套件覆盖，不冒充真实Flutter/SQLCipher界面闭环。

| 实测 | 结果 |
| --- | --- |
| 安全发现 | 仅规范路径/当前SHA，就绪后返回ready，无值、PID/句柄等 |
| 桌面互斥 | 独立准备端持锁时CLI新操作refused/busy，未输入；关闭后明确新操作可用 |
| 输入/复用 | 一次批准，多次操作完整匹配，保留空格/Unicode，不续期 |
| 同ID重复 | 返回同fillId/原结果，内容仍只匹配一次，未重发 |
| 焦点改变 | 切至另一个密码框后unknown/focus_changed，停止余下输入 |
| 未知恢复 | 新ID被fill_needs_attention拦截；所有者检查、清空、重点击后原授权新操作成功 |
| 撤销 | 新操作grant_revoked，原输入不变，不复活许可 |
| 交付/观察 | 无paste、剪贴板序号不变；正常Computer Use文字快照在原假密码仍仅在本地内存时作原文/JSON转义精确扫描，均不含；截图遮挡 |
| 清理 | 接收窗口、CLI、服务及Computer Use会话已关闭/reset |

不因此宣告内置浏览器、所有UIA提供者、显式value、明文截图或模型服务网络载荷通过。真实支持证据仅针对所列Win32窗口；工具遮挡不是本软件控制所有外部采集的保证。

## 自动验证

核心190、CLI相关子集35、存储89、桌面109，共423项执行零跳过，四包严格分析及Windows Release通过。不是全部真实SSH/AWS/GH接收器重新验收。新增CLI测试覆盖安全发现会话/能力/形状、实际原生坏帧，以及真实子进程挂起、回执丢失、坏响应和EOF竞争；故障桩不是真实输入成功证据。

原生23项守卫（含实际SHA及写入/替换拒绝）和24项快照检查在Debug/Release各通过，不称为47种控件兼容。辅助程序/故障桩显式构建，桌面Release尚不打包它们。[固定日志、事件与来源绑定](evidence/issue35-focused-fill-native/verification.json)；[内部合同](../design/windows-focused-fill-native.md)。

## 发现与修正

1. 初轮CUIAutomation不能提供超时接口，真实空控件被拒绝且未输入；更换CUIAutomation8后通过，失败事件保留。
2. 进程退出回调可能早于stdout最终字节，改由EOF判断丢回执，实际立即退出refusal覆盖。
3. 未解决输入需限制同会话其他已批申请；回归发现活动checking应先返回busy，已修顺序。该顺序修正在最终GUI运行后，只影响并发分支，由核心公开接口回归验证；固定运行绑定其当时源码，不冒充源码完全相同。
4. 拒绝私有通道尾随/额外内容；丢发送回执为unknown，不以关闭或非零退出冒充未输入；并发关闭共享排空Future。

早期编译/lint错误已修；Computer Use一次element geometry unavailable后重新观察截图才点击，没有复用索引或猜窗口。此前临时目录清理被自动审批拒绝保留历史，本轮未重试删除。未用真实秘密、子Agent或服务器同步，无新用户ZIP；用户包仍0.4.0+8，PR32草稿。

接下来完成Flutter填充申请/审批/历史和人工检查、程序清单及bootstrap，再验证当前可见内置浏览器并重打包；之后继续#37→#38→#30。
