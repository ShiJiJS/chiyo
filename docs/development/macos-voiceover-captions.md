# 旁白字幕与原生焦点检查（#48）

2026-10-22，冻结源 `45f5da4bb8fc16e2e56e8bd9ecdd35eaf5c963d7`，
沿用生产 Flutter 绑定及字段用途适配器。只开启被动的系统、焦点及合成字段值观察，
没有启用焦点修补假设、按键转发或去除适配器的对照选项。

CUA 查看系统旁白实用工具：字幕面板原本已开启，修饰键为 Control–Option 或 Caps Lock；
AppleScript 控制关闭且未更改。实际开启旁白并结束欢迎页后，观察到存活的旁白 PID85797。
应用原生观察到 voiceOver=true，Flutter semanticsEnabled=true。
字幕面板关闭再开启后恢复原值，但两次绑定旁白应用都出现工具超时，未取得可核对的朗读字幕。

旁白开启期间，CUA 实际打开合成信息编辑器。AX 能读到信息名称、公开说明的用途和值；
普通 Tab 从名称经过目录到公开说明，应用焦点日志一致。仅尝试一次 Control–Option–Right，
之后可观察的键盘焦点仍是公开说明。键盘焦点不能代表旁白光标，AX 树不能证明实际朗读；
本轮不声明旁白导航或听读通过，也没有编辑、保存或独立进程重开。

独立 Release PID85716，真实 SQLCipher、内存合成密钥，无系统钥匙串请求。
8项依赖准备、分析、构建、签名及 entitlements 步骤退出0；669份输入与 Git 核对，
3份副本差异仅 QA 身份及原生被动观察。实际 ⌘Q 正常退出0，库关闭一次、Flutter异常0、
端口56554关闭，驱动 observation-only complete=true。这不等于 Issue 完整验收通过。

结束时通过系统设置关闭旁白，字幕偏好恢复原值，设置返回通知列表，实用工具已退出。
驱动删除私有合成库、controller、App/dSYM；归档校验后删除源码副本。
固定预览的7971项清单、strict签名与原PID保持，build/local中仅留固定预览一份App、
生成dSYM为0，开发SDK、候选ZIP及恢复备份保留。
[原始结果、日志、修改副本与校验摘要](evidence/macos-voiceover-captions/verification.json)。
界面事实来自会话CUA观察和明确转录，没有另存原生截图。

#48 保持 OPEN、3/6。完整旁白需要真实听读和旁白光标操作；最终普通候选包的
物理键盘、中文与联合流程仍按原条件补验。此轮不改产品、不重打候选包，不涉及 Windows/main/CI。
