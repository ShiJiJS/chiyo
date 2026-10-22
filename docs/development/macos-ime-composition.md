# Mac 组合文字回归与系统输入对照（#48）

2026-10-22，仅 Mac 分支；生产编辑桥保持 f93c3bd。
[原始记录、失败预期和最终测试源码](evidence/macos-ime-composition/verification.json)。

新增两个 Mac widget 回归：拼音 z→zh→zhong 的 composing 更新不成为历史，提交中文后
原生 Undo/Redo 桥准确往返原文/中文；粘贴替换选中的组合区，随后 IME 提交，撤销回到
组合开始前，不恢复半成品拼音。相关编辑桥/窗口测试共14通过，严格分析退出0。
这轮只重跑相关测试，不能把它当成完整桌面或实际中文候选窗验收。

首轮错误要求粘贴立即清除 composing，第二轮又要求未提交时可撤销，分别失败。
固定 SDK 的 TextEditingValue.replaced 会调整并保留组合范围，EditableText 的历史
跳过仍在组合的值。因此最终测试明确检查替换后的组合文字和范围，再模拟输入法提交，
然后检查撤销。保留所有失败原始日志，没有修改生产逻辑来迎合错误预期；焦点调试记录
确认失败时仍在编辑器。初版 composition-tests.patch 仅为草稿，最终源码以归档 dart 为准。

实际 CUA 在新建的自有 TextEdit 文档逐键输入 z/h/o/n/g，只见 zhong 和英文拼写提示。
被动读取系统输入源为简体拼音，真实 Control-Space 切为 ABC，再切回拼音，逐键输入仍
相同。输入源标识不能证明输入法内部中英文模式；这些观察既未证明软件中文输入通过，
也未证明是本软件缺陷。Ctrl-F8 无可观察焦点变化，TextInputMenuAgent 的工具选择超时，
Assistive Control 直接启动失败；未重启系统输入进程或修改全局辅助功能/键盘设置。

参考 Apple 的[键盘快捷键](https://support.apple.com/zh-cn/102650)和
[键盘检视器](https://support.apple.com/guide/mac-help/use-the-keyboard-viewer-on-mac-mchlp1015/mac)
定位系统入口；未保存或转载整篇文档。实际 AX/画面在会话中，归档是明确标识的转录，
没有宣称另存截图。前后输入源及修饰键状态 JSON 逐字节一致；Caps Lock 操作未观察到
全局标志变化，不认定内部模式已切换。

自有文档清空后经真实保存面板保存为空白 RTF，实际关闭；先前 iCloud 自动保存路径
已消失。归档219字节空白文件后移除自有输出，保留 TextEdit 原有启动面板。
未读取或修改其他文档。无 Keychain 调用、新系统授权、普通库修改或 Windows 变更。
#48 保持 OPEN、3/6；物理 IME、按钮反向 Tab、面板快捷键及最终同包验收继续待办。
