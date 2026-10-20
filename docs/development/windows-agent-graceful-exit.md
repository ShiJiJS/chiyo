# Windows Agent正常退出（#39）

2026-10-20用户要求补齐Agent自行退出应用的逻辑。实现源码
`887f1c2e29da8799cfec48032ac4967d1576fb77`，整包 **0.4.0+11**。
Round05外观、公开授权协议v2、schema21及备份7/8/9保持。

## 交互与结果

随包 `cli/info.exe app status` / `app quit` 默认只定位同一交付目录的桌面窗口；
另一目录的本软件实例需核对后显式指定 `--pid`。多实例返回`ambiguous_target`。
仅在同一本机Windows桌面使用窄消息入口，消息含目标PID及查询/退出操作，不含秘密；
接收端核对自身PID，调用端绑定实际进程句柄并核对程序路径。入口没有加入HTTP主人能力，
不授予批准、读取或编辑能力，仍遵循ADR0002的同用户应用层边界，不是OS沙箱。

退出复用原有流程：停用会话许可、排空审计/交付记录、停止服务、关闭库、请求终止。
只有绑定的进程实际以0结束才报告`exited`；窗口消失或端口释放不当作充分证据。
写入/关闭失败返回`shutdown_failed`，保留库及窗口，修复后可重试；超时保持未知，
不会调用强制终止。已启动命令仍按原有Job规则运行，退出不擅自杀死它们。
启动之前先安装生命周期入口，初始化失败或部分资源清理失败时也能请求正常退出。
只读`running`表示应用控制入口已可响应，不表示资料服务成功启动。
参数、JSON及退出码见[CLI说明](../cli.md)。旧版没有此入口，明确返回不支持，不降级强杀。

## 验证与边界

- 定向CLI2项、桌面17项通过；保存失败的事件明确拒绝，修复后重试成功，启动失败/启动中退出已覆盖。
- 干净887f1c2完整 **689通过 / 20 opt-in跳过**：CLI94/13、Core272/1、Storage161/6、Desktop162/0。四包严格分析、原四锁、Windows Release通过。
- 实际ZIP中文/空格路径解包、限制PATH后独立CLI/hook **16/0**、实际SQLCipher/DPAPI联合生命周期 **7/0**；与完整组重叠，不累加。
- 另编译不进入产品载荷的Win32测试对端，原生控制 **1/0**：正常退出、窗口先消失的160ms等待、旧协议、超时仍存活、失败后再次退出、初始化等待、多实例拒绝及同包重复退出。它是传输夹具，不能冒充真实Flutter或存储验收。
- 实际Release的独立虚构SQLCipher/DPAPI库：UI一次批准普通字段与文件、排除维护账号，独立AOT CLI重复读取3次且期限不变、越界拒绝；66字节虚构文件原文一致、释放后副本消失。五个主页面、文字/文件详情、遮挡凭据及文件已释放历史实际查看。
- 关窗后窗口清单无该实例，CLI仍显示running且可继续已批准读取；实际SQLCipher写锁使正常退出返回shutdown_failed，进程仍在、状态可查；释放写锁后重试确实退出，重复调用not_running、HTTP服务不可用。重开库核验1条授权已记录applicationClosed、4次成功读取及2条信息仍在。
- 独立尾段真实进程退出/重开后旧会话证明被拒绝；缺密钥错误页实际查看，CLI正常退出且退出码0，原DB哈希不变、没有重建密钥。
- 新增有效会话向HTTP `/app/quit`、`/owner/quit` 请求仍unauthorized，传输定向1/0；实际AOT通用JSON-lines的app/quit对象返回invalid_request。Core/Storage严格分析、Python语法及原四锁再核对通过。

实际包内检查分轮留证，**不宣称一轮完整GUI脚本全通过**：packaged-01脚本取错`id`（合同是`deliveryId`）后正常退出；packaged-02完成上述后台/写锁/重试退出，但解析Dart build-hook前缀失败。原始inspect输出另行核对，退出事实确实持久化；原失败结果保持。tail-03读取含中文的观察回执未指定UTF-8而失败，finally仍正常退出；修正后tail-04退出0、complete=true。三个中断均为QA脚本错误，没有改产品行为或抹掉失败。新版可复用脚本为[scripts/test-windows-app-control.py](../../scripts/test-windows-app-control.py)，使用[合成夹具](../../packages/info_storage/test/support/packaged_control_fixture.dart)；观察回执只证明实际操作员看过界面，不是自动图像断言。

所有测试资料库、窗口、CLI、SQL写锁进程均已回收，47125无监听，Computer Use kernel已reset。
未打开用户真实库、修改Codex配置或系统安全设置，未使用子Agent、同步或Mac。
正常包内流程新增的是上述明确范围，仍不替代真实Codex安装/信任/分享、真实通知点击、
旧版备份对话框及干净用户/独立机器验收。#18/#23/#30继续开放。

## 同版本交付

- ZIP：`build/windows-preview-0.4.0-11-887f1c2/agent-info-manage-0.4.0+11-dev.887f1c2e29da-windows-x64.zip`
- 大小：**53,312,233字节**。
- SHA-256：`65bb32f0080da7769eb79e51b751297702bdde47e137b0a934abb206949bd0f7`。
- 已展开：`build/windows-preview-0.4.0-11-887f1c2/AgentInfoManage/app/info_desktop.exe`。
- format2 manifest逐项校验113项载荷；新增C++测试对端没有混入交付目录。

证据清单及逐字节核验见[evidence/issue39-app-control/verification.json](evidence/issue39-app-control/verification.json)。
源码冻结、构建工具链和载荷哈希以同包manifest为准；未签名开发预览，没有发布Release。
