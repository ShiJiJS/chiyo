# Mac Keychain 访问与签名升级检查（#42）

## 真实锁定钥匙串与恢复验收（2026-10-21）

QA 源码 `9f8c829`，生产代码与 `01c1f14` 现有整包均未改变。
[69 份原始证据与输入摘要](evidence/macos-locked-keychain/verification.json)覆盖独立原生探针及
签名 Release Flutter + SQLCipher 的真实锁定/重试/退出。下文旧记录中的“隔离锁定仍待”是当时状态。

仅创建专属文件钥匙串，随机解锁密码只保留在创建进程内存中，不经 argv、环境、文件或日志。
读取副本只增加 `kSecMatchSearchList`，写入副本只增加 `kSecUseKeychain`，明确指向该专属钥匙串；
这是对测试副本查询目标的两行修改，生产 store/bridge、Keychain 默认身份及数据位置未改。
[Apple 的指定查询列表说明](https://developer.apple.com/documentation/security/ksecmatchsearchlist)
与本机 `SecItem.h` 一致。测试没有调用 LockAll、切换默认钥匙串或替换搜索列表。
系统创建测试钥匙串可能登记自己的搜索项，删除后核对完整搜索列表与默认项均恢复原状态。

最终原生探针（第 3 轮）：签名沙盒中使用同一生产 store 代码加上述显式目标，
创建/读取原随机密钥后实际 `SecKeychainLock`，并通过 `SecKeychainGetStatus` 确认锁定。
两次读取均 `key_unavailable / -25293`，总耗时约 0.004 秒；锁定期间重复写入也被拒绝。
仅用本进程生成的密码解锁该测试钥匙串后，原密钥保持；交互开关恢复初值，默认项保持。
删除专属钥匙串和空测试根，完整搜索列表恢复。前两轮成功探针保留，不累加计数；
首轮只观察最终交互值，后续才加入与初值精确比较。

最终 Flutter 轮次（第 2 轮）：**8 个准备/构建/签名步骤、4 个实际 Release 应用进程**全部退出 0，
Flutter 异常均为 0，严格分析通过。两个业务进程与两个后续清理进程分别记录：

1. 真实 Keychain 创建数据库密钥、SQLCipher 4.19.0 新建合成资料并完成一次获准读取；
   卸载测试业务界面并在同一进程关闭服务/库，随后锁定专属钥匙串。
2. 两次重新启动均进入生产错误界面，实际构建“无法访问系统钥匙串”与重试按钮；
   库字节保持、没有替代密钥或 endpoint，原生状态查询确认每次失败后仍锁定。
3. 恢复场景仅解锁测试钥匙串，再调用普通启动重试。原密钥、信息/字段身份、内容及已结束授权/访问历史保持，
   旧授权不能继续读取。最终正常 Cocoa 退出，端口关闭，两个库各关闭一次。
4. 退出场景保持钥匙串锁定，在错误状态正常 Cocoa 退出。**下一个独立清理进程再次确认仍锁定**，
   才删除专属钥匙串。两个场景分别核对默认项/完整搜索列表的前后摘要，随后删除其合成根。

这使用真实锁定状态和真实 SQLCipher，不是模拟拒绝码；但录入/审批、进程内重启、原生锁定/解锁/退出均为受控 QA。
不等于操作登录钥匙串、物理窗口按钮、系统允许/拒绝提示或完整升级。也没有声称锁定钥匙串会撤销已打开数据库的内存密钥。
生产内容路径没有增加接收测试钥匙串、密码或任意文件路径的接口；所有 qaPrivate 方法仅编入源代码副本。

### #42 验收映射

| 原条件 | 证据与状态 |
| --- | --- |
| 1. 身份/签名与迁移策略 | 身份保持，稳定签名与实际授权/迁移策略尚未验收，保留未完成 |
| 2. 真实密钥创建、录入、完全退出/重开 | 既有 `05326a7`/`b98e487` 默认 Keychain 多进程记录支持；合成资料和秘密不进入外部接口，保留原版本范围 |
| 3. 缺失/不可访问/锁定/错密钥/坏库的保留与退出 | 既有默认 Keychain 20 进程故障记录，加本轮真实锁定/恢复/独立退出后锁态，已覆盖 |
| 4. 两版签名应用及旧库升级 | ad-hoc 更换签名仍默认拒绝，真实系统授权与 schema 升级未验收，保留未完成 |
| 5. 发布 SQLCipher 与故障隔离 | `01c1f14` 整包及实际 Release SQLCipher 4.19.0 记录、专属故障项与无原库/密钥上传的证据支持 |

第 2/3/5 条按各自范围收口，不表示 #42 或总票 #19 完成。签名身份数仍为 0，Mac 仍锁屏；
真实主人允许/拒绝/取消及后续重开、两版升级和最终安装继续保留。最新变化只有 QA，现有整包无需重打。

```sh
python3 scripts/qa/macos-locked-keychain.py build/macos-adaptation/NEW_NATIVE_LOCK
python3 scripts/qa/macos-flutter-keychain.py build/macos-adaptation/NEW_FLUTTER_LOCK --locked-keychain
```

两个输出目录必须不存在。独立原生探针只验证 store；Flutter 模式才覆盖 SQLCipher、错误界面和恢复流程。

## 主人主动请求系统授权（2026-10-21，#42 继续 OPEN）

交付更新：入口与最终退出修复已纳入 `01c1f14` ARM64 整包，见 [当前交付记录](macos-delivery.md)。
下文“尚待刷新”的描述保留各次源码验收结束时的状态；实际系统授权与升级仍未通过。

最终源码 **`36a4bef`** 补充退出竞态保护：若第一次原生退出失败、授权随后返回且正在关闭新打开的库，
第二次退出必须等待资源清理，不能继续使用“尚无资料库时立即退出”的路径。
在 `b98e487` 的独立源码副本运行新增回归，实际观察到第二次 terminate 在 close 尚未完成时调用
（预期次数 1，实际 2，测试退出 1）；原始失败保留。最终增加 library/runtime/cleanupPending 检查，
回归通过。完整桌面更新为 **187 通过、2 跳过**，严格分析、普通 Release 构建和 strict 签名再次通过。

最终源码另做一轮 8 个准备步骤/7 个签名 Release 进程，恢复、拒绝和退出场景均通过、Flutter 异常 0；
30 秒模拟等待中的两次正常退出为 0.216/0.217 秒。该轮输入摘要逐一匹配 `36a4bef`，专属密钥/根已清理。
原有 20 进程普通故障回归仍对应 `b98e487`，未把历史结果改写为最终版本重新运行。
[证据索引](evidence/macos-owner-keychain-access/verification.json) 的 `cleanupRaceFinalValidation`
记录最终结果，共保留 125 份不可变原始文件。下文保留首次入口实现的验证范围。

源码 `b98e487e1fdba935cc1feb3dfeb29159fcec5f7f`。新增“请求钥匙串访问”入口：
只在 Mac 启动因密钥失败、原资源已释放时显示，普通启动和“重试启动”仍不请求交互。
主人点击后通过独立 method channel 方法读取原 service/account；由系统决定是否允许，
程序不更改 ACL、不输入密码、不改应用身份。交互读取缺失密钥直接失败，不能走创建替代密钥的路径。
一次允许所返回的原密钥直接用于本次开库，不要求第二次交互读取；是否允许后续启动访问取决于实际系统决定，尚未验证。

所有原生密钥操作现在在串行后台队列运行，包括等候进程内交互锁，返回结果切回主线程。
这符合 [Apple 对 SecItemCopyMatching 阻塞行为的说明](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:))。
等待系统时显示独立退出入口；关窗/退出无需等密钥操作返回。若退出失败可以重试；
退出请求之后到达的成功结果关闭刚打开的库，不启动 Agent endpoint，失败结果不重新显示窗口。
正常启动的退出等待和审计保留语义保持原有规则。恢复入口没有开放给 Agent HTTP/CLI。

[固定证据与原始资料](evidence/macos-owner-keychain-access/verification.json)：

- 完整桌面 **186 通过、2 跳过**；其中新增 8 项覆盖明确触发、重复点击/普通重试、拒绝重试、
  关窗/退出不等待、迟到成功/失败、系统退出失败重试和不符合条件的拒绝。定向 20 项与全量重叠，不累加。
- 两个独立签名 Release Flutter 源码副本保留生产 store、bootstrap、launcher、SQLCipher，
  只对 QA 身份和明确列出的原生故障/系统决定注入做改动。输入文件摘要逐个与源码提交匹配。
- 恢复入口轮次：8 个准备步骤、7 个真实应用进程返回 0。允许/拒绝/等待都是 **模拟系统决定**，
  不调用真正的交互授权查询。允许场景从该 QA 应用已有权限的真实 Keychain 项读取原密钥，
  实际重开 SQLCipher 核对原信息身份/内容/历史，旧授权拒绝。
- 两个等待场景在原生后台队列真实睡眠 30 秒；另一原生通道仍可响应。
  程序经正常 Cocoa 退出，含启动/断言的整进程耗时分别 0.357 秒和 0.290 秒，
  未用强杀代替退出。入口由实际 Flutter TextButton 回调触发，关窗为注入的生命周期事件；
  这不是物理鼠标、系统弹窗或红色关窗按钮验收。
- 普通行为轮次：11 个准备步骤、20 个真实应用进程返回 0，覆盖创建/重开、缺失、坏长度、
  错误密钥、损坏库和重试保留。不同 ad-hoc 签名默认读取仍为 `upgradeAccess: denied`，
  原签名可重新打开；不能据此宣称交互授权或升级通过。
- 两轮 Flutter 异常均为 0；已启动端口退出后关闭。各自 QA Keychain 项最终删除并确认不存在，
  专属合成根清理。普通产品入口另行 Release 构建及 deep/strict 签名核验通过。

Mac 仍锁屏，系统签名身份数仍为 0。本轮没有调用真实系统授权弹窗、解锁钥匙串、创建证书、
修改信任或操作生产资料。真实允许/拒绝/取消及其后重开、锁定钥匙串、两版应用/schema 升级、
最终安装与 Windows 共享界面回归仍待。现有 `541a671` ZIP 不包含本入口，后续由 #50 刷新，
不能把源码 Release 编译当成整包安装升级通过。

复跑（输出目录必须不存在）：

```sh
python3 scripts/qa/macos-flutter-keychain.py build/macos-adaptation/NEW_OWNER_ACCESS --owner-access
python3 scripts/qa/macos-flutter-keychain.py build/macos-adaptation/NEW_DEFAULT_KEYCHAIN
```

## 早期原生探针与非交互失败修复

2026-10-21，修复源码 `86e35f3`，#42 保持 OPEN。

## 保留现有资料身份

本阶段保持原 bundle identifier `com.example.infoDesktop`、Keychain service
`org.shijijs.agent-info-manage.database`、account `local-database-v1`。
沙盒资料目录为该应用容器中的 `Data/Library/Application Support/AgentInfoManage`。
不能通过改 bundle identifier 或 service 来绕过旧密钥访问问题；那会换成另一份
容器或密钥。未来重命名必须另行完成备份/恢复或显式迁移验证。

生产 Security.framework 逻辑提取到 `DatabaseKeyStore.swift`，Flutter
仍使用原 method channel 和固定默认身份。QA 工具直接编译这份实现，使用两个
独立、ad-hoc 签名且启用生产沙盒 entitlement 的原生探针 App，Keychain service
限定为 `org.shijijs.agent-info-manage.qa.<UUID>`。它不读取或修改生产密钥，
不输出密钥数据，不开放新的 Agent 接口。

## 实际发现并修复的错误

首轮探针 A 创建并多次读取专属测试项成功，同 bundle identifier、不同代码哈希
的探针 B 读取未返回，90 秒后由测试 runner 结束。原来的
`kSecUseAuthenticationUIFail` 不能阻止本机 legacy Keychain 的 ACL 提示，
而生产 bridge 在 Flutter 主线程同步读取，会导致启动长时间卡住。
首轮结束后由原 A 程序清理专属测试项，并确认不存在。

修复为仅在原生 Keychain 操作期间关闭 legacy Keychain 的交互，
用进程内锁串行化该范围，并在成功和失败路径恢复原设置。它不更改 Keychain
ACL、不允许另一签名读取旧密钥、不跳过错误、不替换已有密钥。
采用本机 SDK `SecKeychain.h` 提供的 legacy 交互控制；相关 API 的弃用警告
保留，不能简单换成 Data Protection Keychain 而丢掉已有资料的密钥。

修复后 B 在 **0.431 秒**返回 key_unavailable / OSStatus -25293，
A 仍能读取同一原值。生产启动页增加 Mac 钥匙串错误说明；重试不发布端口，
退出仍可用。这个结果证明失败能及时显示，并不证明新签名已能访问旧密钥。

## 本次证据

- 两份原生探针均成功编译、签名并通过 deep/strict codesign 校验。
- 实际 Keychain 的不存在、创建、独立进程重开读取、拒绝重复覆盖、
  拒绝 31 字节坏值均按预期执行；失败后原程序仍能读到原值。
- 每步核对 legacy 交互设置已恢复；最终只删除专属测试项，并再次确认不存在。
- 桌面严格分析通过；启动/运行时相关 **18 项测试通过**，覆盖钥匙串失败后
  错误提示、重试、未发布端口和退出。Release 重新构建及 deep/strict 签名校验通过。
- 本机 `security find-identity -v -p codesigning` 返回 0 个有效签名身份。
  两份 ad-hoc 程序的代码哈希不同，虽然 bundle identifier 相同，
  第二份仍被拒绝；不能宣告升级无缝保留访问。

首轮超时、第二轮 Swift 类型修正前的编译失败、第三/四轮受控拒绝均保留。
第四轮是最终带耗时、交互状态恢复断言的完整探针。
[证据清单](evidence/macos-keychain-validation/verification.json)不含密钥或数据库。

```bash
python3 scripts/qa/macos-keychain.py build/macos-adaptation/NEW_KEYCHAIN_RUN
```

输出目录必须不存在且位于项目 `build/macos-adaptation` 下。探针中的
`complete: true` 表示所有观察步骤结束；`upgradeAccess: denied` 明确表示
新签名访问旧项仍未通过，不能按 runner 返回 0 认定升级成功。

## 原生探针结束时的剩余验收（后续进展见下节）

当时 #42 仍需真实 Flutter 应用 + SQLCipher 的首次创建/重开、独立测试 Keychain
缺失/锁定/不可访问、错误密钥/损坏库的保留与退出，以及两版应用完整升级。
当前探针是原生签名沙盒进程，不能冒充 Flutter UI 或真实库升级。

跨版本应选择并实测稳定签名、所有者显式系统授权或明确的备份迁移路径。
本轮没有创建证书、修改系统信任、放宽 Keychain ACL 或索要用户密码。
这个缺口同时属于 #50 最终交付；其他 Mac 独立验收继续执行。

## Flutter、真实 Keychain 与 SQLCipher 联合验收（2026-10-21）

源码 `05326a7`，新增普通 Release Flutter QA 入口及隔离构建 runner。
最终第六轮 **11 个准备/构建/签名步骤、20 次实际应用进程均返回 0**，
每个应用进程明确记录正常 Cocoa 退出且 `flutterErrors: 0`。
[完整证据](evidence/macos-flutter-keychain/verification.json)保留失败轮次及源码摘要。

### 验证边界

runner 将仓库源码复制到全新的 `build/macos-adaptation` 目录，逐文件记录 SHA256。
仅在副本中将 bundle identifier 改为 `org.shijijs.agent-info-manage.qa.flutterkeychain`，
将 Keychain service 固定到本轮随机 QA UUID，并注入只操作该 service/account 的
删除/31 字节坏值/错误密钥方法。生产源码没有这些故障入口或身份覆盖参数。
`DatabaseKeyStore.swift`、Dart 平台适配、SQLCipher、启动和退出实现保持原源码字节。
使用实际 Release 沙盒 entitlement、ARM64 应用及随包 SQLCipher 4.19.0 community。
这份测试副本不替代 #50 正式整包，不验证生产容器迁移。

每个场景新建合成资料库，密钥由生产逻辑随机生成并经真实 Keychain 保存/重读；
没有内存假密钥。录入与批准调用主人业务接口，退出事件由探针触发；错误页实际
构建并检查其提示与重试文案。没有声称物理输入、系统面板、菜单点击或截图验收。
Mac 当时锁屏不等于登录 Keychain 被锁定；本轮未锁定或修改用户的登录钥匙串。

### 结果

- 首次创建、录入、批准读取、完全退出与独立进程重开成功；信息项/字段身份、
  值和已结束的授权/访问历史保持，旧临时授权凭证被拒绝，重开不生成替代密钥。
- 缺失密钥、31 字节坏值分别返回 `key_unavailable`；32 字节错误密钥、损坏库
  分别返回 `library_unavailable`。各做两次启动尝试，数据库字节不变、密钥创建
  次数为 0、未发布端口、未保留打开的库，错误页正常构建且可以退出。
- 仅测试夹具还原故意损坏的原字节后，同进程第三次启动成功，原信息和历史
  保持，旧授权仍失效。这不是软件自动修复损坏数据库的功能。
- 同一 Release 应用副本更改 `CFBundleVersion` 后重新 ad-hoc 签名；两份应用
  使用同 bundle identifier、service/account，但不同 CDHash。新签名在 **0.772 秒**
  内完成两次拒绝、错误页与退出，`upgradeAccess: denied`。原签名随后仍正常重开。
  两份的 Dart 业务代码相同，因此这证明的是签名/版本改变后的失败保留行为，
  不代表不同资料库 schema 的完整升级迁移成功。
- 最终仅删除专属 QA Keychain 项并重读确认不存在；六份本轮私密临时资料清理。
  证据不包含密钥、数据库、临时授权凭证或私密关联文件。

### 联合验收发现并修复的退出问题

第四轮 runner 曾返回成功，但原始日志在三个场景出现 `StorageFailure(library_closed)`：
启动/恢复成功后的界面帧尚未绘制，立即退出已关闭资料库，该帧随后读取主题设置。
本轮不把第四轮当作完整通过。修复让 launcher 监听退出状态，退出中及库已关闭时
卸载依赖库的界面；如果系统退出失败，保留单独“重试退出”入口。审计保存失败时
库仍打开，沿用原有保存失败处理，不假装退出成功。

新增四项回归覆盖首帧前退出、已显示界面退出、库关闭后系统退出失败与重试。
修复前相关三项界面测试失败；修复后完整桌面 **178 通过、2 跳过**，严格分析通过。
普通 Release 重新构建与 strict/deep 签名验证结果见证据清单。
修改涉及共享 launcher；仍仅提交 Mac 分支，Windows 原生回归待 #41。

QA runner 同时增加 Flutter 错误计数和关闭后最后一帧检查。第五轮曾在无界面
清理进程错误等待一帧而超时，专属项已删除，随后独立原生探针只读确认不存在；
修正清理模式后第六轮通过。前面三轮的注入定位、静态检查及 Swift 类型错误，
以及中间测试异步等待修正日志全部保留，均不算通过。

```bash
python3 scripts/qa/macos-flutter-keychain.py build/macos-adaptation/NEW_FLUTTER_KEYCHAIN_RUN
```

`complete: true` 只表示整套观察完成；必须单独看 `upgradeAccess`。
#42 仍 OPEN：正式身份/稳定签名策略、真正锁定钥匙串的隔离验证、完整版本/库迁移、
实际系统授权提示和生产整包联合验收尚未完成。不能通过改生产 bundle identifier、
service 或放宽 ACL 绕过升级问题。
