# Mac 普通输入的 AX 初始值与闲置缓存

2026-10-22，#48/#50，产品ca5fe69，仅独立Mac分支。接续[提示气泡修正](macos-tooltip-accessibility.md)。
本轮补齐初始/闲置原生值，**尚未解决全部焦点与辅助功能问题**，#48继续3/6、#50继续2/6。

## 独立诊断与实现

基线770c67f的真实窗口：名称输入SyntheticNameAlpha、说明输入SyntheticDescriptionBeta后，
原生名称NSTextField.stringValue/cell.stringValue/accessibilityValue均变成后者；画面和Dart草稿
仍分别正确。重新聚焦及Tab后两个native缓存还曾互换。问题不只在CUA输出缓存。
初次打开原生shim的缓存为空，也不能反推Flutter初始值为空。

新增只读QA诊断分别记录native字段、AX值、currentEditor身份/归属及Dart草稿，
仅在显式synthetic参数的自有合成应用中记录字符串；生产默认不输出内容。
本轮没有读取个人资料、Keychain、系统密码或跨设备秘密。

MacTextFieldAccessibility现在从自身唯一EditableText取得普通文本及控制器/焦点变化，
将其与用途和可见几何送到所属窗口的本机MethodChannel。TextFormField内部控制器也能追踪；
更换控制器后解除旧订阅，隐藏页面和屏外字段仍不登记，obscureText不传文本。
这改变了此前“只传用途/几何”的局部接口：普通文本只供自身AppKit辅助功能shim缓存，
没有新增Agent HTTP访问能力、选区命令或日志内容；秘密继续使用原生安全输入路径。

原生维持唯一几何匹配及安全字段/系统sheet排除，只在currentEditor为nil时同步stringValue，
发送valueChanged。已有活动编辑器及组合文字均不写入，不通过清空控件/移动焦点来掩盖问题。
数据、存储和授权逻辑保持。原生shim懒创建后仍需要现有100ms轮询，不声称首个瞬时查询即完整。

## 回归与真实范围

精确最终Dart回归在独立旧770c67f上2失败（缺初始text、替换控制器后无当前text），
修正后相关26项通过、严格分析0；新增秘密排除和订阅释放检查。AppKit公共接口11项通过，
包括闲置值更新、无焦点改变、活动编辑器内容/组合文字与安全字段不被覆盖。
早期测试把currentEditor公开getter返回值误当成底层初始值而失败，已修正为实际前后对比；
历史“普通文本也不进入通道”的期望按新接口改为普通值准确、秘密仍排除，失败日志保留。
Windows只有框架模式回归，不当作原生Windows验收。

正式实现Release+普通绑定+真实SQLCipher/合成内存密钥，实际CUA完成：
- 未聚焦前名称及说明初始AX值与模型一致。
- 输入不同名称/说明后两者native值、AX值与草稿各自正确。
- 系统SCIM逐键n/i/h/a/o得到ni hao、有效composing[0,6]，Space选为你好；名字缓存不被覆盖。
- 恢复原名称并保存MacFocusSaved，正常⌘Q后独立PID重开，GUI/仓库确认原名、BaselineValue和原7B附件v1保持；
  再进编辑器时两个初始原生缓存正确。两进程退出0、库各关闭一次/Flutter异常0/端口关闭，native AXTree错误0。

但同一正式轮也保留失败：恢复名称后只点击说明、不改值时，原生编辑器仍挂在名称shim，
名称原生/AX值为你好，而Dart名称保持原名。因为保护活动编辑器，本轮同步不强行覆盖它。
这不是短暂等待后已恢复的通过；不能宣称串值完全修复、所有Focus/VoiceOver通过。
最后继续在实际说明框输入检查点并保存，数据结果正确，不将保存成功代替辅助功能完整通过。

固定SDK源码显示GetFocus使用最后辅助功能焦点，树的键盘焦点另记；Mac的FOCUS_CHANGED没有处理，
值/文档选区事件按GetFocus选择编辑器。这是上述所有权问题的可测试解释，尚未证明预编译engine内部
逐字节相同。官方[Flutter #191001](https://github.com/flutter/flutter/issues/191001)也记录键盘与旁白焦点不同步；
仅作为相关线索，不将其报告当成本机完成证据。后续可在QA中验证公开setAccessibilityFocused与已选键盘字段对齐，
目前未实现或通过，不调用私有engine方法、不修改SDK。

单独AppKit公开setAccessibilityValue试验未改变直接AX getter；旧override API返回true也未改变直接getter，
未测外部AX效果、未采用。没有为通过而改用私有选择器或伪造输入。

## 候选与清理

准确源码 `ca5fe69f79169b1f642aa05416faa19123636558`；package20，版本`0.4.1+13-mac-dev.ca5fe69f7916`。
stock --check共21阶段均0、四包严格分析通过，780通过/66条件跳过：
Core290/6、CLI75/40、Storage160/18、Desktop255/2，不累加针对性测试。
ZIP130962638字节、SHA256 `b784104f95226696cb77eff1cd67215500e3dfac34dacbdcbf108a0efe5d60db`，保留于
`build/macos-adaptation/issue50-package-20/`。两份解包各7971项文件/模式/链接与清单一致，
75个Mach-O；准确包内桌面二进制摘要及65条用途适配符号核对。
ARM64/ad-hoc/未公证，仅构建目标14.0、本机27.0.1实跑，未称干净用户/准确普通包升级已通过。

基线与正式QA应用/dSYM/私有合成库/源码、独立原生诊断二进制均已清理；
整包解包、诊断与根缓存再回收1908.9MiB。
最终build/local仅固定4690e79一份App/零生成dSYM，7971项清单/strict签名/PID53592保持，
已有非包内GH运行状态文件保留；SDK、依赖缓存、候选ZIP和私有升级备份均保留。
[原始证据与逐文件摘要](evidence/macos-native-text-cache/verification.json)。

固定4690e79普通预览未替换；无新增Keychain请求。人工配合范围仍见[集中清单](macos-owner-assisted-acceptance.md)，
焦点诊断仍可自动推进，不能把这个缺口全部推给主人试听。
