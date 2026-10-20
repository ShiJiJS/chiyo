# Mac Keychain 访问与签名升级检查（#42）

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

## 剩余验收

#42 仍需真实 Flutter 应用 + SQLCipher 的首次创建/重开、独立测试 Keychain
缺失/锁定/不可访问、错误密钥/损坏库的保留与退出，以及两版应用完整升级。
当前探针是原生签名沙盒进程，不能冒充 Flutter UI 或真实库升级。

跨版本应选择并实测稳定签名、所有者显式系统授权或明确的备份迁移路径。
本轮没有创建证书、修改系统信任、放宽 Keychain ACL 或索要用户密码。
这个缺口同时属于 #50 最终交付；其他 Mac 独立验收继续执行。
