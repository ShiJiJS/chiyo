# Mac 原生全选与 Flutter 选区衔接修正（#48 / #50）

2026-10-22，独立 `codex/macos-adaptation`。
[结果、源码摘要和 105 份原始资料](evidence/macos-native-text-editing/verification.json)。
固定普通包仍是已允许的 `4690e79`；本次修正进入源码，**尚未替换该包，也未宣称
普通资料库上的修正后验收完成**。诊断使用独立签名应用、合成文本，不连接资料库、
Keychain、Agent 服务或主人审批，没有要求新的系统允许。

## 复现和定位

此前普通包的 ⌘A 和原生 Edit → Select All 没有实现全文替换，见
[普通包原始复现](macos-installed-file-versions.md)。本轮先用系统 TextEdit 新建文稿
对照：相同工具操作可选中全文并一次删除；文稿最终为空，保存至当前测试目录并
归档后移除，没有保留测试文字。

最小 Release 诊断窗口使用产品的 DesktopTextField，原生侧只被动记录合成按键的
modifier flags/first responder，Dart 记录合成 controller 的文字和选区。原生层与 AX
可报告已经全选 `ProbeAlphaBeta`，但 Dart 选区仍是 `14:14`，BackSpace 后只是
`ProbeAlphaBet / 13:13`。因此不能将 AX 的“Selected text”单独当成业务编辑成功。
原生 first responder 为 FlutterTextInputPlugin；观察也显示工具合成事件的原生
Command flags 与 Dart HardwareKeyboard 的 modifier 状态并不一致，不据此宣称
真实物理键盘或所有 Flutter/macOS 环境都有同样问题。

仅向该 responder 的 `doCommand(by: selectAll:)` 转发的候选也没有更新 Dart 选区，
失败日志保留，未将这条做法交付。最终使用明确的本机动作桥接。

## 修正范围

- Mac 的 NativeSelectAllMenu 保留原生菜单项，只把本应用 Flutter 文本框的全选
  送往 `agent_info_manage/text_editing`。本应用局部按键监听只接管没有其他修饰键
  的 Command-A，限定当前窗口、Flutter 框架 NSTextView 和无系统 sheet 的情形；
  不监听其他应用，不新增辅助功能授权，不接管其他快捷键。
- Dart 的 MacTextEditingActions 核对当前焦点确实属于 EditableText，然后调用已有
  SelectAllTextIntent。桥接只传动作名，不传文字、字段 ID、凭据或私密能力。
- DesktopWindowFrame 的 Mac 分支安装该处理，覆盖启动和正常应用的根包装。
  Windows 的原有窗口/编辑路径保持；没有改变核心授权、存储、Agent 协议或原生
  Windows 文件。旧根卸载不能清除替换根已安装的监听。
- NSOpenPanel / NSSavePanel 等系统 sheet 打开期间恢复原始菜单 target/action，
  关闭后重新连接 Flutter；其他原生响应者保留原生动作。监听和观察器随处理器
  释放，原菜单也恢复。

## 实际验证

8 项相关 widget 测试通过：4 项新增覆盖当前编辑框全选后删除、其他编辑框不变、
非编辑焦点拒绝、根包装替换/卸载和 Windows 不注册；另有 4 项既有窗口回归。
桌面严格分析通过。首轮测试缺少 Material 祖先导致夹具失败，补正夹具后通过，
两轮原文都保留，没有把夹具失败说成产品回归或隐藏它。

独立 Release/沙盒原生诊断已构建并严格验签；最终用于通过记录的 PID48678 与
未启用原生修正的对照 PID48635 使用相同二进制。Dart 包装、native helper 和 Xcode
工程源码与产品修改逐摘要核对。诊断 MainFlutterWindow 额外有被动日志及仅 QA
环境开关，入口没有资料库；**这些日志/开关不在生产代码里**。诊断可执行文件含
x86_64/ARM64，本轮实际运行于 ARM64；没有改变生产打包的 ARM64 范围，也没有
因此宣称 Intel 验收通过。

| 最终实际 CUA 操作 | 结果 |
| --- | --- |
| 输入完整 `CommittedBridgeCheck`，观察输入完成后 ⌘A、BackSpace | Dart 记录范围 `0:20`，AX 和 controller 均为空。 |
| 系统另存框通过原生 Edit → Select All、BackSpace | 文件名为空，Save 禁用；实际 Cancel 返回，未创建文件。 |
| Cancel 后回到 Flutter，输入 `AfterNativePanelFinal`，原生菜单全选并输入 `FinalReplacement` | Dart 选区 `0:21`，最终只有替换文案，没有追加旧文字。 |
| 实际 ⌘Q | 最终原生进程退出 0；全部八个受监督诊断进程均有退出 0 记录，未强杀作为正常退出。 |

前一轮启用 sheet 恢复后的 PID48258 还验证了 Cancel 后 ⌘A/删除重新作用于 Flutter。
系统 TextEdit 对照、最小基线、失败候选、修正后实际 UI 分开记录，不能累加成多项
不同的最终包验收。

## 保留的未通过及诊断边界

系统另存框中，CUA ⌘A 没有建立可靠选区；未启用原生 helper 的同二进制对照也
表现相同，随后 BackSpace 只删一个字符，两种模式原生菜单全选均能清空。因此这项
不算通过，也不能把它定性为本次修正新增的回归；物理键盘及系统远程面板输入路由
仍待核对。第一次面板探测失败原样保留，不能只引用菜单成功而宣称所有面板快捷键
都正确。

一次 CUA 退出后观察自动重启了旧诊断进程46585，导致两份早期画面绑定旧进程。
此后核对内核 PID/可执行路径并只保留一个诊断实例；那两份画面排除于通过结果，
额外进程实际 ⌘Q 后已消失，没有无依据补造其退出码。另一次测试在合成字符仍排队
时发全选，controller 显示先选 `0:16`、余下字符继续替换；该组也不计通过。后续每次
快捷键前先确认完整文字已经到达界面，最终通过记录与 PID、日志明确对应。这里
没有证明任意未完成输入队列、物理 IME 或其他编辑快捷键均正确。

## 清理与后续

诊断应用已注销并删除，构建及相关缓存回收约 934 MiB；项目仅一份固定预览 App、
零生成 dSYM（工具链除外），无诊断进程。空白 TextEdit 对照文件已归档后移除。
本轮 QA container 的数据已清理，但系统保护的
`.com.apple.containermanagerd.metadata.plist` 无权删除，按原始清理错误记录保留，
没有请求放宽系统保护。原生产 App43712 和 Keychain 未改。

#48 保持 OPEN、3/6；尚有系统面板快捷键、实际 IME/其他键盘、窗口/字号/主题和
完整取消焦点矩阵。本次原生诊断不是最终普通包；#50 后续统一换包时应连同此前
“最近使用”显示修正和 Mac 接入说明复验，避免为每个修正单独触发钥匙串允许。
Windows/main/CI 均未操作。
