# Mac 遮蔽字段的原生辅助功能对照（#48 / #50）

2026-10-22，基于aa9fdd3，仅Mac分支。本轮不改生产代码、不替换普通安装。
[六个实际进程、五轮Flutter构建和原始源码/日志](evidence/macos-secure-field-diagnosis/verification.json)。

上一轮发现画面为圆点时CUA AX仍可能返回合成明文，本轮用独立AppKit、无编辑桥的
Flutter、当前编辑桥三个实际对照进一步定位，随后验证两种原生替代原型。所有文字
预先合成，不读取真实秘密、资料库或Keychain；没有开启系统VoiceOver、变更系统
辅助功能设置或新授权。这里的AX读取不是实际语音读屏验收。

## 实际对照结果

| 进程 | 操作与结果 |
| --- | --- |
| 原生96247 | NSSecureTextField初始值、全选、原生菜单开关、保存面板取消后，均为secure text field和遮蔽值；Copy/Cut禁用。普通NSTextField的合成值正常可读。 |
| 无编辑桥97311 | 同一固定Flutter，移除原生桥安装及Dart DesktopWindowFrame；始终遮蔽字段输入Z后初次AX为圆点，原生Copy/Cut仍可用。切换另一个字段为遮蔽并从保存面板返回后，两个AX字段出现已知SyntheticToggle42，画面两个字段仍是圆点，模型身份未交换。 |
| 当前桥97941 | 相同TextField代码，仅打开桥开关，原生窗口为生产源码原字节。始终遮蔽字段输入Z、⌘A、开关菜单后，AX及Selected text出现实际合成秘密变体SyntheticSecret4Z2；Copy/Cut已正确禁用。切换及面板返回后也观察到两个AX字段显示相同合成Toggle值。 |

因此不能把画面或AX中的某一值直接当成当前Dart模型。无桥也能产生遮蔽值/字段对应
异常；当前框架动作桥的全选路径还能使始终遮蔽字段的实际合成秘密变体出现在AX。
复制限制仍必要，但不足以保护辅助功能文本；这不是已经解决的隐私验收。

本地Flutter3.47.7、framework abaf9c5、缓存engine deb2874。SDK源码显示RenderEditable
产生遮蔽语义值，而Mac文本输入插件/FlutterTextField共享原生字段编辑器并更新文字。
这只是源码线索；本机没有缓存engine提交对象，未声称已证明所有本地源码与预编译
engine内部逐字节对应。SDK源码摘要、版本及干净状态保留，SDK没有修改。

读取的相关上游[Flutter #170721](https://github.com/flutter/flutter/issues/170721)在本次查看时
仍开放，报告及Mac复现记录描述了遮蔽文字被读屏读出的情况，后续评论指向桌面嵌入层。
它支持继续检查此边界，不代表本软件已修复；也不将上游提及的Windows当成本机Windows
验收。没有向上游发消息、提交报告或修改其他开发分支。

## 嵌入原生视图原型未接受

98560在Flutter中以AppKitView嵌入NSSecureTextField，保留当前桥。实际坐标点击后输入
传回Dart长度20、程序替换回传准确，面板取消后原生字段仍为secure。但AX树只见原生框，
其他Flutter控件没有完整暴露；按AX元素点击还落到下面的Flutter字段，模型从17字变为1字，
不能把这次误点算作原生输入成功。坐标输入的成功单独记录。

99195仅在QA中增加Dart ensureSemantics，仍没有完整AX树；实际日志出现
`Failed to update ui::AXTree ... Nodes left pending by the update: 15`，Tab后焦点回到容器。
应用自己的只读NSAccessibility属性检查仅输出字段类、已知值相等布尔值和mask状态，
没有日志正文；与外部CUA AX的读取范围分别记录。不能通过只验证一个原生框的遮蔽而
忽略其他控件的可访问性。两轮嵌入方案均未加入产品，没有调用私有engine API或关闭
辅助功能来绕过问题。

## 标准原生弹层原型通过，产品整合仍待

99966保留当前生产原生窗口与编辑桥，只在QA增加NSAlert+NSSecureTextField弹层。
Flutter主界面只有“已填写/为空”和编辑按钮，不创建Flutter秘密编辑器；普通合成字段
保持可编辑。原型中已确认：

- 输入SyntheticSheetUpdated42后取消，Dart旧值保持；重开仍为原16字符遮蔽值。
- 再输入并确认，native及Dart updatedExact=true，23字符准确回写。
- 再次打开仍为secure text field；全选后系统菜单Copy/Cut禁用，主菜单保留原生处理。
- Escape取消并保留已接受值；返回主界面辅助功能树完整，普通字段可继续输入X。

原型代码不在生产入口注册。尚需接入真实凭据表单、取消/清空/长度边界、重复点击与
窗口退出、焦点及主题/字号、只读/禁用等条件，并核对不会把秘密放入Flutter可编辑
语义节点。不能把本轮原型确认写成产品修复或凭据保存完整验收。后续实现应沿此已验证
方向继续，而不是启用未通过的AppKitView原型。

## 检查与清理范围

五轮Flutter夹具分别严格分析、Release构建及deep/strict签名通过；独立AppKit控制构建/
签名通过，原有弃用警告保留。首轮QA漏写大括号的分析失败日志保留，修复后再构建。
六个受监督进程均实际⌘Q退出0，无新增系统确认或测试夹具剪贴板写入。未重跑未修改
的普通桌面/Core/CLI/Storage测试，也不累加此前209或724项结果。

实际AX/画面在会话中，归档为明确的转录，未宣称另存截图。完整上游页面阅读存于
忽略目录，公开证据只保存自有代码、日志、摘要和此处概述。两个生成App注销，自有
native/source构建删除；固定4690e79的7971项/strict签名/PID53592保持，一份完整App、
零生成dSYM。具体释放空间见cleanup.json，SDK、旧ZIP、私有备份和恢复密钥保留。
#48继续OPEN、3/6；#50继续OPEN、2/6，安全秘密编辑及最终同包流程仍未通过。
