# Mac 菜单栏入口不可见时的窗口回退（#46 / #50）

2026-10-22，独立 `codex/macos-adaptation`。修复真实原生回退缺口：
菜单栏项已经不可见时，其 `button` 对象仍可存在，原实现仍允许隐藏窗口；
窗口已经在后台时，菜单栏项消失也没有恢复窗口或刷新入口状态。
[分轮原始记录、实际源码和摘要](evidence/macos-status-fallback/verification.json)。

## 实现

`MainFlutterWindow` 现在同时检查状态项的按钮和 `isVisible`，再决定关窗能否隐藏；
原生 availability 使用同一判断，避免向 Dart 报告不可见入口仍可用。
对实际状态项建立 KVO 观察：入口不可见且窗口隐藏/最小化时，先恢复窗口，
再发送既有 availability 事件。入口恢复也刷新 Dart 状态，不重启服务或改变授权。
完全退出前关闭观察并清除 desktopReady，排队回调不会在终止途中重新显示窗口。

依据 [Apple NSStatusItem.isVisible 文档](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible)
及本机 AppKit 头文件：该属性支持 KVO；临时被菜单栏空间遮挡时仍可返回true。
因此本修复针对原生入口不可见/移除的状态，**不宣称检测到菜单栏拥挤、刘海遮挡或所有系统故障**。
没有增加文件、通知或 Keychain 权限，也没有添加 Agent 控制系统菜单栏的通道。

## 原生基线与修正验证

QA入口使用生产 DesktopBootstrap、DesktopLauncher、NativeDesktopPlatform、SQLCipher，
独立随机应用身份和内存合成数据库密钥。仅源码副本增加两个QA方法：
改变该测试应用自己创建的真实 `NSStatusItem.isVisible`；被动读取状态项和窗口原生状态。
生产 close/hide/show/KVO和退出逻辑保持，没有注入 close/open/availability/quit 事件。
这里是受控原生故障注入，不是通过系统菜单栏物理移除图标。

| 场景 | 实际结果 |
| --- | --- |
| 修正前基线 e5068ef | button存在、isVisible=false、窗口可见；CUA实际点击红色关窗后，生产hide返回true、原生windowVisible=false。原授权仍可读取，库未关闭，确认回退缺陷。 |
| 修正后，不可见入口时实际关窗 | 同样button存在/isVisible=false；真实关窗后hide返回false、windowVisible=true、Dart tray=false。 |
| 原生入口恢复 | 设置实际状态项可见后，KVO使Dart tray=true，无需重启。 |
| 可用入口时再次实际关窗 | 第二次真实关窗hide返回true，先被动观察到windowVisible=false，确认确实进入后台。 |
| 后台入口消失 | 随后仅将真实状态项设不可见，生产KVO恢复windowVisible=true、Dart tray=false；不调用show/open，也不使用CUA激活应用来制造恢复。重新恢复入口后tray=true。 |
| 授权与退出重开 | 关闭和回退后原授权仍读到相同合成字段；实际⌘Q后独立进程重开，信息及结束历史保存、原授权被拒绝，再实际⌘Q。 |

CUA读取隐藏目标会重新激活它。为避免污染隐藏断言，每次实际点击关窗后只读取访达的
AX状态；目标是否隐藏/恢复由目标进程内的原生被动观察记录。取得这些断言之后才再次
读取目标AX/截图。基线结束时的工具重激活单列为openApprovals，不冒充Dock点击。
第二次关窗后的自动恢复，在再次接触目标CUA之前已写入报告。
两个截图只展示随后可达的实际窗口，不单独作为“无工具激活恢复”的证明。

基线App62553和修正App63370/重开63395共3个进程，均真实⌘Q退出0，
关闭库各一次、Flutter异常0，端口退出后均不可达，无失败兜底强杀。
基线报告的complete表示已完整复现缺陷，**不表示旧产品回退通过**。
合成申请由测试owner API批准，仅用于检查关窗前后的授权保持，不冒充GUI审批验收。

两轮各8项依赖/严格分析/Release构建/验签检查退出0；构建保留既有Keychain弃用警告。
运行时/启动回归18通过、0跳过，Dart格式和Python语法检查通过。
两轮各634项构建输入摘要重新匹配；基线生产Swift匹配e5068ef，修正Swift匹配当前实现；
源码副本与相应生产Swift的差异精确限定为上述两段QA方法。原生生产修复不包含QA方法。

## 清理、复跑与剩余条件

两轮测试应用注销，临时App/dSYM、Flutter编译缓存、合成库/授权私有文件均删除。
原稳定4690e79/PID53592没有替换；7971项载荷字节/模式/链接及deep/strict签名一致。
项目测试/预览目录合计只余1份可用App、0份生成dSYM，固定SDK缓存不计入。
原新旧ZIP、私有备份和独立恢复文件保留。本轮Keychain调用和新增主人系统允许为0。

复跑使用全新输出目录：

```sh
python3 scripts/qa/macos-status-fallback-ui.py \
  build/macos-adaptation/NEW-status-fallback-run
```

按controller.json定位准确应用；首次不可见入口时点击红色关窗，等待第一项报告。
确认入口恢复的等待阶段后再次点击红色关窗；此时避免读取目标AX，直到报告完成
后台隐藏和自动恢复断言。随后正常⌘Q；监督脚本独立重开核对持久化，再正常⌘Q。
`--expect-regression`只用于修正前源码，完整复现后也必须正常退出。

本轮补齐 #46 第1项中的不可用回退实现和实际原生证据，仍缺直接Dock/状态栏点击；
CUA绑定两者均timeoutReached，不把工具限制当作产品失败或通过。第5项真实OS锁屏/
睡眠/唤醒及期限跨越仍待。**#46继续OPEN、4/6**，不拆小原复合条件凑勾选。
生产改动尚未进入已允许的4690e79安装或原7edb11c候选ZIP；统一升级后需复验。
**#50仍OPEN、2/6**；未触发新签名系统确认，没有Windows/main/CI操作。
