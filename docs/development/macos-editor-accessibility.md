# 信息编辑器用途标签与真实 Mac 辅助功能检查

2026-10-22，#48/#50，仅独立 `codex/macos-adaptation`。基线 `fffd7ac`；产品修正
`bb98c80`、`148a9fe`、`69a7b8d`、`d74fdbb`。固定普通 4690e79 预览没有替换，
本轮未访问其资料或 Keychain。原复合验收未关闭。

## 问题与实现

基线真实 Mac 编辑器的七个文本框在原生 AX 树中没有用途名称；空标签按钮无名，
目录按钮只有当前值“未分类”。相邻可见标题不等于对应输入框的语义标签。

编辑器现在关联信息名称、公开说明及字段名称／内容／说明的用途，目录、标签、字段
类型合并用途和原按钮语义，保留值、角色、动作、焦点及忙碌禁用状态。装饰性标题从
语义树排重，画面与业务行为保持。框架语义测试先通过，但实机原生文本框仍无名，
因此没有把 Dart 层通过当作最终修复。

核对本地固定 Flutter engine 的 `FlutterTextInputSemanticsObject.mm`：原生 AppKit
文本框 shim 未将框架名称转交 accessibilityLabel。SDK/engine 来源、文件哈希保存在
原始证据；没有修改 Flutter SDK，也不依赖其私有类名。

`MacTextFieldAccessibility(label, child)` 保留框架 Semantics，并仅将用途和可见逻辑矩形
经本地 MethodChannel 批量交给原生 module。`NativeTextFieldAccessibility` 只在所属
Flutter view 内寻找 NSTextField，排除 NSSecureTextField，附有系统 sheet 时暂停；严格
验证数据形状、有限坐标、大小与唯一矩形，唯一几何匹配才设置 accessibilityLabel。
不读取或传递内容，不改选区或焦点。弱引用保存原标签，清除／释放时只还原仍由自己
持有的标签。原生对象可能在 AX 查询时才创建，因此描述存在期间用主线程定时检查。

实机滚动又暴露出用途坐标不更新。被动诊断确认 native view 已移动，但 Dart 提交的
矩形仍停在顶部；不能仅凭 AX cell 和 live view 的不同内边距推断缓存失效。
最终根因是 ScrollableState 可保留而具体 ScrollPosition 被替换，原监听仍挂旧对象。
现在监听、替换和释放实际 ScrollPosition；滚动后帧调度及所属 live view 几何匹配也
单独覆盖。未改变存储、授权、协议、Windows 原生实现或外部访问能力。

## 回归与逐轮实机结果

同一最终语义测试在独立 fffd7ac 源码上 4 项预期失败，修正后 4 项通过。针对原生
metadata 的测试覆盖只发送用途／位置、滚动、清除以及非 Mac 不发通道调用；精确新增
“同 State、更换 Position”回归先出现应为20、实际40的失败，修正后通过。最终相关
widget 测试共 **20 项通过**，严格分析通过。独立 AppKit 公共接口测试 **9 项通过**，
包括无内容／焦点变更、无效数据保持原状态、清除还原、外部改名保留、歧义不猜测、
安全文本框隔离、几何更新、释放还原及嵌套 live view。Windows widget 模式不算 Windows
原生或 CI 验收。本轮未重跑完整四包套件，也未声称已有 ZIP 包含这些新修正。

| 轮次 | 来源 | 实际结果与边界 |
| --- | --- | --- |
| run-1 | fffd7ac | 复现无名输入；旁白真实开启条件下普通 UI 保存／正常退出／独立重开。不是旁白光标导航通过。 |
| run-2 | bb98c80 | 按钮用途修复，但 native 输入仍无名。真实 SCIM 逐键组合、选词、多行中文保存重开另有证据。 |
| run-3 | 148a9fe | 顶部两个 native 用途出现；滚动不自动刷新，编辑后才更新。中文检查点粘贴，不算 IME。 |
| run-4 | 69a7b8d | 被动用途／几何日志证实滚动后 metadata 仍旧，未记滚动通过；中文检查点粘贴。 |
| run-5 | d74fdbb | 会话中断后等待真实 UI 超时；驱动按失败终止并清理，未记通过或正常退出。 |
| run-6 | d74fdbb | 实际拖动滚动条，无编辑即自动更新中部字段名称／内容／说明、部分可见附件名称、底部附件说明；回顶部恢复信息名称／公开说明。正常保存中文、退出、独立重开通过。 |

run-6 实际打开 NSOpenPanel，CUA Escape 未关闭，随后点击原生 Cancel 正常返回；没有
选择新文件，原附件保留。此次没有证据证明 Escape 或原焦点恢复完整通过。其 `nihao`
逐键输入 composing 为 [-1,-1]，也没有算 IME 成功；最终精确 `你好测试\n你好` 由粘贴
保存。界面和 SQLCipher 只读核对在独立进程重开前后均一致，BaselineValue 和原7字节
附件保持，数据库完整性正常，核对不改变 DB/WAL/SHM。两次真实 Command-Q 分别退出
43243／43282，退出码0，各库关闭一次、Flutter异常0、端口已关闭。

准备时的测试夹具修正、初始失败、native 桥接与滚动的中间失败全部保留，未把这些
失败日志累加为通过数量。最终轮逐项核对667个源码输入及 QA 副本修改哈希。

## VoiceOver 的实际边界

只读 NSWorkspace 系统标志确认：最初关闭，CUA Command-F5 未开启。随后实际系统设置
开启，处理“使用旁白”欢迎界面，真实 VoiceOver 进程33953及标志true；未更改欢迎
选项、AppleScript 控制或申请辅助功能权限。Control-Option-Right 未产生可确认旁白
光标导航，无法取得可验证字幕或声音。不能将开关true或 AX 标签当成完整朗读通过。

基线在旁白运行时完成普通 UI 保存／重开后，已恢复旁白关闭，退出本轮打开的旁白
实用工具，系统设置返回原通知页，未改变通知配置。后续 run-2–6 旁白均关闭。

## 清理与后续

原生驱动清理每轮 App、dSYM 与私有合成库，取消注册测试应用；归档后删除残余源码
副本与本轮独立诊断二进制。最终项目中只有保留的普通预览1份 info_desktop.app，
生成目录无 dSYM。普通预览7971项逐一核对字节／模式／链接、严格签名正常，PID53592
保持；恢复备份和候选ZIP保留。本轮没有新增系统钥匙串请求。

[原始证据索引](evidence/macos-editor-accessibility/verification.json)；
[集中人工配合清单](macos-owner-assisted-acceptance.md)。#48 继续 OPEN、3/6，#50 继续
2/6，原4/5/6项范围不缩减。尚需完整物理键盘／旁白、普通包联合条件和下一份一致候选
包；未为每次改动替换固定入口、触发密码或放宽 Keychain 访问规则。
