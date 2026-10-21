# Mac 原生复制、剪切和粘贴与 Flutter 文本模型（#48 / #50）

2026-10-22，基于 `8b82c03`，仅在 `codex/macos-adaptation` 修改。
[分轮结果、源摘要和原始资料](evidence/macos-clipboard-actions/verification.json)。
固定普通安装仍为已允许的 `4690e79`；本次修正尚未换入该包，最新旧候选
`cce2f9a` 也不包含本修正。没有新增 Keychain 调用或主人系统允许。

## 实际复现与原生对照

TextEdit 新建临时文稿：CUA 英文输入和中文粘贴均准确；同一工具的
`typeText('中文_Probe')` 实际只输入 `Probe`。因此不能把此前中文按键输入失败
直接归因于应用，也没有把粘贴当作物理中文 IME 组合输入通过。
文稿已清空，保存至本轮工作目录，空白 RTF 归档后移除；iCloud 临时自动保存文件
随正常另存消失，没有删除未知个人文稿。

独立最小 Release 使用当前产品 DesktopTextField、DesktopWindowFrame 和普通
WidgetsFlutterBinding，不初始化 Bootstrap、数据库、Agent 服务或 Keychain。
修正前 PID79692：输入 `FlutterBaseline`，真实全选 `0:15` 后 CUA 粘贴中文，
AX 显示 `中文 合成粘贴 Clipboard`，但 controller 没有发生文字更新；随后 Left
使 AX 回到 `FlutterBaseline`。日志与实际画面共同说明原生 NSTextView 的展示值
没有进入 Flutter 文本模型，不能以 AX 粘贴画面独立判定成功。

## 实现与源码回归

将既有 NativeSelectAllMenu 扩为 NativeTextEditingMenu，仅对本窗口 Flutter
框架 NSTextView、无原生 sheet、无额外 Control/Option/Shift 的 Command-A/C/X/V
以及对应原生菜单动作，发送明确动作名。Dart 核对当前焦点属于 EditableText，
调用框架原有 SelectAllTextIntent、CopySelectionTextIntent 和 PasteTextIntent。
原生桥不传文字或剪贴板内容，不访问其他应用，不新增辅助功能能力。

Flutter 自身继续处理输入格式、选择区、只读和密码遮罩限制。新回归验证跨字段
中文复制、选区替换、剪切及剪贴板一致性，同时核对只读框不能剪切/粘贴，密码框
不能复制/剪切，非编辑焦点拒绝动作，根包装卸载不留下处理器。Windows 不注册
该桥。原生 sheet 开始时恢复每个菜单项原 target/action，结束后重接 Flutter；
原生文件名编辑仍由 AppKit 处理。

修正前新增复制回归失败，测试进程退出1；修正后两组相关测试共10通过。
第一次完整源码检查：Core285/6条件跳过、CLI75/40、Storage159/18均通过，桌面
严格分析因新测试一个多行 if 缺少大括号退出1。补正测试后，桌面严格分析退出0，
完整桌面203通过/2条件跳过。最终四包合计722通过、66条件跳过；不是将首次
检查脚本写成退出0，也没有重复运行未受测试格式修改影响的三个包。

QA 新增面板按钮时也出现一次相同格式规则问题，补正后分析及 Release 构建通过。
产品没有这项 QA 按钮、剪贴板暂存或日志。最终 Release 原生日志保留既有弃用
警告，严格 deep 签名通过，没有宣称所有原生编译日志零警告。

## 实际修正后界面

PID80938 使用实际 CUA 操作，按 controller 已到达完整文本后再操作选区：

| 场景 | 实际结果 |
| --- | --- |
| CUA 中文粘贴后 Left | controller 长度17、fixtureExact=true；Left后中文保持。 |
| 原生菜单全选/复制，普通删除，再原生菜单粘贴 | controller 准确恢复 FlutterBaseline，而不是此前合成剪贴板中的中文。 |
| ⌘A、⌘X、⌘V | controller 从英文变空，再完整恢复英文。 |
| 中文的原生菜单剪切/粘贴 | controller 变空后重新 fixtureExact=true。 |
| 英文 ⌘C、普通删除、⌘V | 英文准确恢复，独立确认复制确实改变剪贴板，不以剪切代替复制证明。 |

PID82356 再以当前源码打开真实 NSSavePanel：原生菜单全选文件名
ClipboardPanelSynthetic，剪切后文件名为空、Save禁用，粘贴后恢复且Save可用。
实际 Cancel 返回，没有创建文件，Flutter 中文草稿保持。重新聚焦编辑框清空后，
原生菜单粘贴使 controller 再次 fixtureExact=true，确认菜单恢复连接。
这轮没有验证无需重新聚焦的取消恢复，不替代此前完整表单焦点验收。

QA 在 native 内存中临时保存剪贴板所有 item/type 的字节，测试结束显式恢复，
只记录恢复动作；既不落盘也不输出用户剪贴板。两轮均观察到恢复完成。
未修正、修正和面板三个受监督进程均实际 ⌘Q 退出0。
最后一次退出后 CUA 的 getAXState 又打开了空白 PID82380，已再次实际 ⌘Q 退出，
系统进程表确认消失；它没有受监督退出码，也不新增通过计数。此次额外打开没有
执行剪贴板准备动作。实际截图/AX保留在会话中，归档有明确标注的转录，未声称
另存了一套截图文件。

## 剩余范围与清理

物理中文组合输入、原生面板快捷键、按钮上的反向 Tab、Paste and Match Style、
Undo/Redo 和其余窗口/字号/主题矩阵没有随本轮通过。原生菜单在 Flutter 编辑器
有焦点时仍按动作可路由而启用，实际操作由 EditableText 自己限制；只读/密码
保护以模型及剪贴板断言验证，没有宣称菜单禁用样式也完全覆盖。
#48继续OPEN、3/6；#50继续OPEN、2/6，最终普通安装统一升级及同包联合流程仍待。

独立诊断 App 已注销，源副本及整个构建目录清理。固定普通安装7971项的内容、
模式及链接逐一保持、deep/strict签名通过，PID53592继续运行；测试/预览范围仅
一份完整 App、零生成 dSYM。SDK、既有 ZIP、私有备份及恢复密钥保留。
原生产 Keychain 及资料库未改，没有运行 Windows CI 或修改 main/Windows 分支。
