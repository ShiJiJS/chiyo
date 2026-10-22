# Mac 键盘焦点与原生编辑器归属

2026-10-22，#48/#50，产品dd050f3，仅`codex/macos-adaptation`。
接续[初始值与闲置缓存](macos-native-text-cache.md)。此前长期存在的纯焦点错绑，
在本轮所列实际场景已修正；不宣称完整旁白、物理按键或所有瞬时AX查询均通过。

## 实现与边界

普通输入额外提交当前keyboardFocused、UTF16选区及组合范围；数据来自自身唯一EditableText，
只送所属窗口的本机通道，不新增Agent HTTP能力。秘密仍完全排除该通道。
原生验证布尔类型、整数/范围、最多一个键盘焦点和唯一可见几何匹配。
旧用途/文本更新格式继续可用，任意额外键或无效更新保留原状态，不猜测焦点目标。

仅在本应用活动、所属窗口可见且为key window、没有原生sheet，且Flutter已选定的普通字段
发生键盘焦点转换时，通过公开setAccessibilityFocused对齐该字段。每次转换只做一次，
不持续追赶旁白光标。Dart报告组合文字或原生firstResponder报告marked text时延后对齐。
不调用私有engine选择器、KVC，不修改SDK，不选择另一个Flutter输入框。

AppKit聚焦可能把原生编辑器变成全选，因此仅在目标currentEditor正文与当前模型相同时，
将其原生selection缓存还原为Flutter既有选区。它不写活动正文、不改Flutter控制器或组合文字。
普通闲置缓存同步和原生懒创建/100ms轮询仍保留；一次凭据输入后的立即CUA查询曾显示旧名称，
随后稳定态正确，故不承诺所有瞬时读值/通知时序都已解决。

## 先对照，后采用

| 轮次 | 来源与操作 | 实际结论 |
| --- | --- | --- |
| public-focus | bac5d8b，仅QA焦点假设 | 原生编辑器跟随正确字段，旧纯焦点串值不再长期保持；但CUA显示整段Selected text，Dart仍为末尾光标，不当成完整选区成功。 |
| public-focus-selection | bb665c5，QA追加既有选区还原和组合保护 | 原生currentEditor.selectedRange与Dart选区、实际⌘A、SCIM组合/Space选词、纯Tab返回一致。 |
| production-final | dd050f3，正式实现，未开上述QA假设开关 | 凭据普通字段、信息编辑、真实文件面板/确认取消、保存及独立重开通过下列核对。 |

两个假设均仅单进程观察/正常退出，不称为完整保存重开。
每轮669项源码输入对固定Git对象及QA修改摘要核对；正式轮使用真实默认窗口策略。

精确最终Dart回归在独立bb665c5旧产品源码上2失败（缺新焦点/选区元数据），最终相关27项及严格分析通过。
AppKit公共接口15项通过：无效类型/越界/双焦点、真实默认后台保护、单次焦点/选区恢复、
旁白浏览不被重复重选、Dart或原生组合期间延后。这里的活动条件和字段编辑器是明确的合同测试替身；
真实OS窗口与Flutter桥由下方CUA验证。早期独立原生程序尝试激活窗口失败退出133，
随后将环境活动条件变成可注入谓词；生产调用仍使用默认NSApp/key/visible检查，不放宽守卫。
初次选区断言另误要求field.accessibilitySelectedText返回全文，实际该直接getter为空，
但native editor range与Dart及CUA全选一致；最终证据使用活动编辑器范围，不把该错误预期算产品失败。

## 正式实现的实际窗口核对

普通绑定、真实SQLCipher及独立合成内存密钥，所有输入、点击、Tab、面板及退出由CUA执行。
未填写秘密、未触发Keychain或系统密码，也未打开VoiceOver。

- 凭据名称SyntheticCredentialAlpha、绑定名SYNTHETIC_BINDING分别正确；只切换名称、两次Tab返回绑定后，
  native编辑器属于绑定，原生[0,17]与Dart[0,17]全选一致。草稿明确放弃，界面仍0项凭据。
- 信息名称/说明填写不同值，恢复原名称后只点击说明而不编辑：名称保持原名，说明Beta，
  native编辑器属于说明，原生[24,0]对应Dart[24,24]，不再留在旧名称shim。
- 实际⌘A后原生[0,24]/Dart[0,24]一致；逐键n/i/h/a/o形成ni hao、composing[0,6]，
  原生光标[6,0]。Space选为你好，回到名称后两次Tab返回未改说明，原生[2,0]/Dart[2,2]一致。
- 实际拖动可见滚动条到文件字段，打开NSOpenPanel；Escape实际关闭，日志记录begin/cancelled。
  返回说明你好及[2,0]/[2,2]保持，暂存0、原7B附件v1不变。一次轮滚动未移动，不定性为已证明产品回归；拖动实际成功。
- 点击取消打开未保存确认，再取消确认，草稿、说明焦点及选区保持。最后保存MacFocusSaved，正常⌘Q退出。
- 独立PID重开GUI及仓库核对原名、BaselineValue、原附件7B/v1；再打开编辑器只做名称→Tab两次，
  说明MacFocusSaved的原生编辑器与末尾光标[13,0]正确。取消只读查看并正常⌘Q。

正式两进程均退出0、库各关闭一次/Flutter异常0/端口关闭，native AXTree错误0；
连同两个假设共四次正常退出，不累加为四次完整流程。当前保存检查点是英文，
本轮中文组合/提交通过，不冒称新版中文持久化全矩阵已完成。复合#48仍3/6、#50仍2/6。

## 统一候选及清理

准确干净源码`dd050f3caa1bcd4a382a765672a5f8b603787d02`，package21，版本`0.4.1+13-mac-dev.dd050f3caa1b`。
stock --check严格分析及781通过/66条件跳过：Core290/6、CLI75/40、Storage160/18、Desktop256/2，
21构建/签名/压缩/解包检查均0；针对性测试不另累加。ZIP130966982字节，
SHA256 `2030d3d50a35d181341ef761b45a6045f52814695a85847417e409738be3058e`，保留于`build/macos-adaptation/issue50-package-21/`。
两份解包载荷各7971项/75个Mach-O与准确ZIP清单逐字节/模式/链接核对，桌面二进制摘要及
95条适配符号确认。ARM64/ad-hoc/未公证，不称干净用户或准确普通入口升级已通过。

两轮QA假设及正式QA的App/dSYM/私有合成库/源码、独立原生试验二进制均清理；
整包解包、诊断及根缓存另回收1909.1MiB。
最终build/local只留固定4690e79一份App/零生成dSYM，7971项清单/strict签名/PID53592保持。
原有非包内GH运行状态、SDK/依赖缓存、候选ZIP、私有恢复备份及密钥均保留。
[逐文件原始证据摘要](evidence/macos-keyboard-ax-focus/verification.json)。

固定4690e79普通预览未换入；[人工配合清单](macos-owner-assisted-acceptance.md)仍集中安排。
剩余完整旁白/物理键盘、最终准确普通入口、Keychain升级及通知/休眠/干净用户等原条件保持。
