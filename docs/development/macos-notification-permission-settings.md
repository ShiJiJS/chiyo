# Mac 系统通知拒绝与设置恢复实机验收（#47）

2026-10-22，冻结 QA 源码 `e68bdc659ee5cd54349f82d57b9dc796fc063226`。
生产实现与 package21 的 `dd050f3` 相同，本轮只扩展 QA 场景；普通预览没有换包。
沿用此前已允许的 `org.shijijs.agent-info-manage.qa.notifications20261021`，
显示名“Mac 通知合成验收”，实际 PID76903。合成 SQLCipher 库／内存密钥，
没有调用系统钥匙串，也没有申请新的通知身份。

## 实际系统操作与结果

CUA 操作系统设置中这一个 QA 应用的“允许通知”，没有改其他应用、专注模式、
镜像／共享屏幕或全局通知偏好。初始允许为 on，桌面／通知中心／锁屏均选中，
临时提醒、声音 on、预览默认、分组自动；恢复后相同。

| 阶段 | 系统事实与应用实际操作 | 结果 |
| --- | --- | --- |
| 初始 | 原允许保持，原生设置查询 authorization=2；未点授权按钮 | 应用显示“系统接受通知”，启动 permissionActions=0、submissions=0 |
| 临时关闭 | 实际系统“允许通知”切到 off，再点应用正式“开启或检查提醒” | 原生 authorization=1，应用显示“系统已拒绝通知权限”和系统设置指引 |
| 拒绝期间 | 生产请求流新增一条合成字段请求，应用内提醒保持开启 | 本机通知调用为 0，请求仍 pending；实际收件箱显示新聊天、全部26／待处理26／已处理0，以及拒绝通知但可在应用内处理的提示 |
| 恢复 | 系统“允许通知”切回 on，再点应用同一检查按钮 | 原生 authorization=2，应用恢复“系统接受通知”；原请求仍 pending，没有补发或自动批准 |

原生被动观察共四条 settings 记录，authorization 序列 `2,2,1,2`。
两次应用检查按钮确实调用生产 `requestAuthorization`，计入 permissionActions=2；
权限已有系统决定，整个操作没有出现新的授权或密码提示。
`--reuse-permission` 在此组合模式保证启动复用已有允许，不能将它解释为
本轮整个期间权限 API 调用为 0。普通复用模式此前的 0 次事实仍保持其原范围。

本轮没有点击“发送测试通知”，没有原生 submit／accepted／willPresent／didReceive，
也没有通知 open 回调；不是又一轮投递／真实点击证明。
文件 gate 不改变系统许可，未注入 availability、open 或原生通知回调。
生产状态刷新由上述实际按钮完成，不宣称后台自动探测系统设置变化已经验证。

CUA 最后实际 ⌘Q 正常退出 0，库关闭一次、Flutter 异常 0、端口关闭。
监督脚本 complete=true，非提前退出，无强杀清理。系统设置返回原通知列表页。
9 项依赖、严格分析、Release、QA 显示名签名、deep/strict 签名和 entitlements
检查全部退出 0。构建输入与冻结 Git 源码逐项核对，副本原生差异只有 QA 身份和
被动日志，显示名在签名前明确记录。
[原始结果、源码、原生日志及 CUA 观察转录](evidence/macos-notification-permission-settings/verification.json)。
会话中的 CUA 截图／AX 输出是界面观察来源，未另存图片，不冒充独立截图集。

## 清理与剩余范围

临时应用、dSYM、编译缓存、合成库和 controller 已由驱动清理；归档核对后删除
剩余源码副本。固定普通预览 4690e79 的 7971 项、strict 签名和 PID53592 保持。
项目 build/local 范围仅固定预览一份 App、生成 dSYM 为 0；SDK、ZIP 和资料备份保留。

#47 仍 OPEN、1/5：本轮补实际拒绝和系统设置变化，第一项还含不可用状态等复合条件，
不因这个子场景通过而整项勾选。前台／关窗后台完整显示和真实点击、类型与旧请求、
实际投递失败及最终普通包条件继续按原票据；不以拒绝时未调用 API 冒充 API 投递失败。
没有 main、Windows 或 CI 操作。

复跑使用新的输出目录，原系统允许必须已存在；此模式需要实际操作系统设置和
应用检查按钮，不能仅创建 gate 文件替代：

```sh
python3 scripts/qa/macos-notifications-ui.py build/macos-adaptation/NEW-permission-settings \
  --reuse-permission --permission-settings
```
