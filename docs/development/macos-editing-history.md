# Mac 撤销、重做和粘贴并匹配样式（#48 / #50）

2026-10-22，基于 `5e58c6d`，仅 `codex/macos-adaptation`。
[实际操作、分轮源码和原始日志](evidence/macos-editing-history/verification.json)。
固定普通安装仍为已允许的 `4690e79`，最新保留候选为 `cce2f9a`；两者均不包含
本轮及上一轮剪贴板修正。没有升级普通安装，没有新增 Keychain 或系统允许请求。

## 问题与实现

原生 Undo/Redo 仍指向 AppKit 的历史，而当前文本实际由 Flutter 管理。
修正前最小 Release：粘贴并匹配样式只将 AX/NSTextView 改为中文，controller
保持英文，Left 后显示回退。其路径与上一轮普通粘贴的问题相同，但选择器为
`pasteAsPlainText:`，不能将上一轮普通粘贴成功套用到它。

NativeTextEditingMenu 新增 undo:/redo:/pasteAsPlainText: 的原生菜单路由，
精确识别 Command-Z、Command-Shift-Z、Command-Option-Shift-V。只在当前本窗口
Flutter NSTextView、无原生 sheet 时处理；其他组合保留原事件。普通文本字段的
匹配样式粘贴继续使用框架 PasteTextIntent，不引入富文本或自建剪贴板解析。
UndoTextIntent/RedoTextIntent 从当前焦点查找框架现有 UndoHistory，不保存另一份
产品历史。桥只传动作名，不传文字、凭据或历史内容。

Dart 明确拒绝只读编辑器的 undo/redo，避免撤回成为只读之前的编辑；既有复制/
剪切/粘贴保护保持。系统 sheet 开始时恢复所有原始菜单 target/action，结束后
重接当前 Flutter 动作。本轮没有改动 Windows 原生目录、协议、资料库或授权模型。

## 实际对照与修正后结果

使用普通 WidgetsFlutterBinding、当前产品 DesktopTextField/DesktopWindowFrame
的独立 Release，无 Bootstrap、资料库、Agent 服务或 Keychain 调用。QA 仅记录
已知合成文本的相等布尔值、长度与选区；临时剪贴板在 native 内存保存各格式并恢复，
用户原剪贴板不输出、不落盘。每轮均用实际 CUA 操作，不注入编辑器动作。

初次 PID84493 在第一次输入后尝试撤销无变化。这不足以单独证明缺陷：框架可能
将空框及首次快速输入合为一个历史状态。修正后 PID85377 的相同初次尝试也无
变化，明确不计失败或通过。随后统一使用完整英文→完整中文两个已到达模型的
状态进行比较；没有通过更改框架历史合并策略来迎合工具。

| 实际进程 / 动作 | 结果 |
| --- | --- |
| 旧实现 PID86016，两个编辑源码逐字节回到5e58c6d；英文后普通粘贴中文 | controller依次asciiExact=true、fixtureExact=true，确认不是只有AX值。 |
| 旧实现两状态后⌘Z、查看Edit菜单 | 中文不变，Undo/Redo仍禁用。此组才是撤销缺陷的有效原生对照。 |
| 修正实现 PID85377，英文→中文后⌘Z、⇧⌘Z | controller与AX回到英文，再回到中文。 |
| 修正实现，原生Edit→Undo/Redo | 同样准确往返英文/中文。 |
| 原生Paste and Match Style菜单，再Left | controller进入17字合成中文，Left后保留，没有回退。 |
| ⌘⌥⇧V | controller准确进入同一合成中文。 |
| 真正NSSavePanel剪切合成文件名、原生Undo、Redo | 文件名空/Save禁用→原名/Save可用→空/Save禁用；Flutter草稿不变。 |
| 真实Cancel后重新聚焦Flutter，⌘Z、⇧⌘Z | 英文/中文正常往返，没有混入系统文件名历史；没有保存文件。 |

旧实现精确对照在修正实测之后重新构建，并非再次运行修正二进制。原生helper与
Dart桥均保存旧Git字节；修正实测所用的两份源另外保存并与最终产品逐字节匹配。
QA原生窗口只比产品多此前已审计的内存剪贴板准备/恢复块，去除它后与产品相同。
三次受监督进程84493/85377/86016均实际⌘Q退出0，没有退出后再次观察而重启。
实际AX/画面保留在会话中，归档明确标为转录，未宣称另存了一套截图。

## 回归与清理

两项新回归修正前均失败/退出1，修正后与既有编辑桥/窗口回归共12通过。
新回归覆盖两个字段各自历史、只撤销当前焦点、重做、切回第一字段，以及保留
历史后切为只读拒绝撤销/重做。非编辑焦点和根卸载补查两个新动作。
最终桌面严格分析退出0，完整桌面205通过/2条件跳过。本轮没有重新运行未修改
的Core/CLI/Storage，也不将上一轮722项或12项相关测试重复累加为本轮总数。
两版构建严格分析、Release及deep/strict签名通过，原生既有弃用警告保留。

独立App已注销，源副本及整个构建目录清理；固定安装7971项内容/模式/链接匹配，
deep/strict签名通过，PID53592仍运行。测试/预览范围仅一份完整App、零生成dSYM，
原ZIP、SDK与私有恢复材料保留。没有修改普通库或其钥匙串。

物理中文IME、按钮上的反向Tab、原生面板快捷键、其余窗口/字号/主题及最终同包
普通安装验收仍待。原生菜单在Flutter编辑器聚焦时按可路由动作启用，仍未实现
菜单禁用样式与每个Flutter历史可用状态同步；无历史时框架动作可安全无操作，
只读则由桥明确拒绝。#48保持OPEN、3/6；#50保持OPEN、2/6，不因这些修复关闭整票。
