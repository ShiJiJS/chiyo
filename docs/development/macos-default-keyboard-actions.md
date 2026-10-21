# 恢复默认键盘动作（#48 / #50）

2026-10-22，基于940278d，仅在 `codex/macos-adaptation` 修改。真实Mac按键诊断确认
Tab命令已送到Flutter，却无法移动焦点。产品为搜索快捷键提供 `MaterialApp.actions`
时替换了框架默认动作表，丢失NextFocusAction/PreviousFocusAction等默认动作。
[分轮事实、源摘要及原始证据](evidence/macos-default-keyboard-actions/verification.json)。

## 定位和实现

第一轮仅QA开启诊断：普通WidgetsFlutterBinding的子类包装默认BinaryMessenger，
保留原消息、处理器、回复和顺序；记录flutter/textinput的方法名及performSelectors
的选择器名称，不记录文字或客户端编号，不消费或注入输入。原生局部监视器返回原事件，
只观察测试窗口；Tab才附带其字符码，另观察flagsChanged。生产SDK和输入处理未修改。

实际Left产生moveLeft:，文本选区16:16变为15:15，证明原生到EditableText路径有效。
Tab字符码9产生insertTab:，Shift-Tab字符码25产生insertBacktab:；两者均送到Dart，
说明节点771291003、文本SelectorBaseline和选区15:15仍不变。此时Flutter硬件键
观察中的shift仍false，不足以解释原生已正确送达的反向选择器也无效。

对照本机固定Flutter源码：WidgetsApp直接采用非空widget.actions；EditableText的
performSelector把上述选择器映射为NextFocusIntent/PreviousFocusIntent并从当前上下文
查找动作。应用原动作表只有SearchInboxIntent。现将该搜索动作放到MaterialApp.builder
内的局部Actions，保留框架完整默认动作（包括框架自行配置的可覆盖ScrollAction），
搜索回调和适用页面规则保持。没有全局截获Tab、补造修饰键或更改输入法行为。

新增真实InformationApp表单回归，在Mac文本选择器测试路径和Windows按键路径分别
验证Tab离开名称字段、Shift-Tab回到原字段、草稿文本保持。修正前两个平台模式均失败，
退出1；修正后与搜索、文件编辑、原生全选四组共22通过/0跳过。完整桌面测试199通过、
2条件跳过（条件跳过不算通过），最终严格分析及Dart格式检查通过。Windows模式是在
Mac上运行widget测试，没有运行Windows runner/CI，不代表Windows实机通过。

## 第二轮无按键诊断包装的实机复验

使用普通WidgetsFlutterBinding、生产DesktopLauncher/Bootstrap/UI及SQLCipher；
内存合成密钥，随机独立身份，不访问用户资料或真实Keychain。Native副本仅保留既有
当前输入源ID读取及文件面板begin/end日志。所有键盘、面板、取消及保存由CUA实际操作。

| 实际动作 | 模型、焦点及结果 |
| --- | --- |
| 说明ActionsBaseline输入后Tab | 从item-description节点1056475252到item-tags节点869927535。 |
| CUA从标签按钮Shift-Tab | 实际进入field-name-0节点649646070，方向错误，明确不计通过。 |
| 从字段名称Shift-Tab | 正确回到item-tags节点869927535。 |
| 按实际截图选说明，Shift-Tab | 正确到item-directory节点514291359；再Tab回原说明。 |
| Escape打开未保存确认，取消 | 恢复原说明节点1056475252、原文本/选区15:15；不重新点击直接续写AfterEscape。 |
| 滚动后真实NSOpenPanel，Cancel | 忙碌时选择/保存禁用，无暂存；回到同一说明节点，直接续写AfterPanel，库仍为BaselineDescription。 |
| 实际⌘A替换为MacFocusSaved并保存 | 普通字段BaselineValue及7字节附件/版本1保持。 |
| 实际⌘Q、独立进程重开、实际⌘Q | 70386/70460均退出0，库各关闭一次、Flutter异常0、端口关闭；重开模型及实际列表/详情一致。 |

修正前诊断进程69298/69365也正常退出0，分开保留，总4次退出不算4次键盘通过。
最后CUA退出观察返回timeoutReached，监督器随后已确认原70460退出0、PID消失及清理完成；
没有因为观察超时而重启或重复退出。实际文件面板只打开一次、取消一次。

最终637项构建输入中636项与提交前源码逐字节相同，唯一差异是新回归测试的格式化；
对副本运行同一Dart格式化后与最终测试文件逐字节一致。生产main.dart、editor及QA入口
均与实际构建输入相同；严格分析、Release构建和deep/strict签名通过。原生编译既有
弃用警告保留，未宣称整份原生日志零警告。

## 仍开放的范围和清理

按钮上的CUA Shift-Tab仍向前移动，不能宣称完整反向键盘链已通过。此前原生Shift
flagsChanged的keyCode为0、Fluttershift状态false；与文本框原生选择器和正常修饰键
widget测试结果不同，工具/引擎路径仍需进一步区分，保留实际物理键盘验证。AX在非文本
焦点只报container，滚动后字段值映射不准确；本轮用控件键/实际节点与截图坐标核对。
SCIM.ITABC输入源ID保持，不等于中文组合输入通过，本轮没有完成中文IME验收。

两轮独立App、dSYM、编译缓存和私有合成库/控制文件均清理，零Keychain调用/系统确认。
固定4690e79预览PID53592仍在，7971项文件内容/模式/链接及deep/strict签名保持；
测试/预览目录只余一份完整App、零生成dSYM（SDK/依赖缓存除外），原ZIP和私有恢复文件
保留。此修正尚未换入固定普通安装；最终统一升级/同包闭环和干净用户仍待。
#48继续OPEN、3/6，#50继续OPEN、2/6，不把已修复的单条键盘问题当作整项完成。

```sh
# 日常实际UI复验：不包装messenger、不记录按键。
python3 scripts/qa/macos-editor-focus-ui.py build/macos-adaptation/NEW-focus
# 仅定位时开启被动键盘/选择器记录。
python3 scripts/qa/macos-editor-focus-ui.py build/macos-adaptation/NEW-keys --diagnose-keys
```
