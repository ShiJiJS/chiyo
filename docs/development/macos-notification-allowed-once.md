# 通知许可复查后的允许路径实机回归（#47）

2026-10-22，冻结 QA `c95cb02`，生产 Dart／macOS／打包入口与 package23 的
`7b19d34b61cf07d5a77db05adb8f0c9cdbf85805` 无差异。只扩展 QA 场景，没有修改
产品或再生成候选包。补齐[上一轮许可缓存修正](macos-notification-stale-permission.md)
尚未直接运行的原生允许分支，不将它扩大为完整显示或通知点击验收。

## 一次实际生产请求

固定已允许身份 `org.shijijs.agent-info-manage.qa.notifications20261021`，
显示名“Mac 通知合成验收”，Release PID84457，真实 SQLCipher／内存合成密钥。
普通 Flutter 绑定、生产 Bootstrap／runtime／通知桥。准备25条申请后才启动请求监听，
启动没有通知；CUA实际激活应用、查看通知页“系统接受通知”后，只创建一次协调 gate。
gate只发起新合成请求，不修改系统状态或注入回调。

- 系统设置中该应用“允许通知”为on，没有更改任何通知偏好或调用权限申请。
- 生产新请求流触发一次 native notify；实际预检查authorization=2，UN add恰好一次。
  原生submit／accepted／willPresent均为同一UUID
  `2112A597-6169-4471-9324-5F26DFED5E53`和同一请求ID。
  submit记录appActive/windowVisible=true，accepted=true、errorCode0，三次设置查询均允许。
- 应用保持enabled、permissionActions=0；新增请求仍pending。
  CUA手动打开访问审批后，新聊天可见，全部26／待处理26／已处理0，没有自动批准。
- 未实际点击系统通知，didReceive/open回调为0。willPresent与API接受不证明横幅实际可见。
  本轮没有从系统日志推断新的抑制原因，也不把手动打开审批当成通知自动定位。
- 实际CUA ⌘Q退出0，库关闭一次、Flutter异常0、端口关闭，驱动complete=true，无强杀。

9项依赖准备／严格分析／Release／签名及entitlements步骤退出0；669份输入与Git核对，
副本差异仅QA身份和原生被动日志。生产源码逐路径diff与package23为0；不重复上一轮
784项全套测试或构建新的ZIP，不把旧数字记成此轮新跑。
[26份原始结果、日志、源快照与摘要](evidence/macos-notification-allowed-once/verification.json)。
界面事实来自会话CUA AX／截图及明确转录，未另外保存原生截图文件。

## 清理与剩余范围

生成App/dSYM/缓存、私有库和controller已删除，归档核对后另移除约23MiB源码副本。
同身份helper只查询本次准确UUID／请求组合，before0/after0，不能声称实际删除过一条；
helper不申请权限、不发送新通知、不注入点击，结束后也已注销删除。
固定预览7971项／strict签名／PID53592保持，build/local仅固定预览一份App、生成dSYM为0。
原资料、恢复备份、开发SDK和候选ZIP保留，系统设置返回原通知列表。

#47保持OPEN、1/5：实际完整前台／关窗后台显示与点击、非首页定位、其他请求类型及
旧通知、真实投递错误和最终普通包范围仍按原条件，不由这一个允许分支提前勾选。
没有main、Windows、CI或新主人确认。

复跑使用新输出目录，先确认同一QA身份已有系统允许；每轮只协调一条新通知：

```sh
python3 scripts/qa/macos-notifications-ui.py build/macos-adaptation/NEW-allowed-once \
  --reuse-permission --allowed-once
```
