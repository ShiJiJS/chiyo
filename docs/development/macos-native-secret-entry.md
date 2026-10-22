# Mac 托管凭据使用原生安全编辑框

2026-10-22，独立分支 `codex/macos-adaptation`，基于 `9379dd5d43e036a74fafde17a83f08b32a2165d6`。本轮将上一轮通过的原生安全弹层方向接入产品，修正 Mac 托管凭据录入与轮换的秘密编辑路径。Windows/main 没有修改或合并，没有运行 Windows CI。

## 行为与实现

此前 Flutter 的遮蔽字段在实际 Mac 辅助功能树中曾出现合成明文；圆点显示和禁用复制不足以解决该问题，独立复现见 [诊断记录](macos-secure-field-diagnosis.md)。现在 Mac 的 `credentialInput(secret: true)` 和 `DesktopTextField(obscureText: true)` 使用 `MacSecretInput`，Flutter 界面只呈现“未填写 / 已填写”和“填写 / 修改”，不创建承载秘密值的 EditableText 节点。已检查现有生产 `obscureText` 入口；不把这项修复推广为所有普通字段辅助功能异常都已解决。

点击后使用 AppKit NSAlert sheet 和 NSSecureTextField；完成只更新当前表单草稿，既有父表单“保存凭据”才调用 OwnerAccess 保存。取消、Escape、平台失败、禁用或异步期间草稿被替换均不覆盖现有内容。请求编号匹配取消，防止重复打开及已卸载组件接收晚到结果。NUL、超过 65,536 UTF-8 字节和超过组件字符上限的内容被拒绝；Swift 和 Dart 均核对，复杂字素不按 UTF-16 码元截断。清空可以回到未填写，必填由原表单决定。

原生通道仅属于应用主人进程，没有新增 Agent HTTP 能力、持久化位置或诊断明文输出。原生控件在关闭前清空编辑缓冲；这不构成所有运行时内存副本已清零的保证。平台异常使用通用说明，不回显原生错误详情，也不降级回存在已复现问题的 Flutter 秘密编辑框。非 Mac 保留原 TextField。

真实测试还发现 sheet 打开时普通应用 Quit/⌘Q 未到达原有退出流程。现将主菜单已有 `NSApplication.terminate` 项转到已有 `requestFullQuit`，先取消安全编辑框；desktopReady 时沿用 Dart 退出处理，未就绪时异步调用系统终止。窗口关闭和设置完全退出共用取消入口。没有扩大任意应用控制；系统替代的“退出并保留窗口”菜单动作未单独验收。

## 已执行验证

| 层次 | 实际范围与结果 |
| --- | --- |
| 严格分析 | 桌面 `flutter analyze --no-pub --fatal-infos` 退出 0，无问题。 |
| 完整桌面测试 | 215 通过、2 条件跳过；跳过不算通过。新增 6 项覆盖草稿接受/取消/清空、语义中无值、重入和晚到结果、错误/禁用、NUL/字节/字素限制、真实创建/轮换表单保存失败保留及重试、Windows 仍用原输入组件。 |
| 针对性回归 | 同一 6 项另重复 3 轮，各 6 通过；不累加成更多独立用例，也不与 215 相加。 |
| 原生构建 | 最终 7 项依赖/格式/严格夹具分析/Release 阶段均退出 0，最终 App deep/strict 签名验证退出 0。 |
| 实际原生输入 | CUA 操作真实系统安全框和产品 CredentialEditor/CredentialManagement。新建和轮换后，MemoryInformationRepository 保存的合成字节与预期准确一致，版本由 1 到 2，完成 sheet 后仍须父表单保存。 |
| 边界与返回 | 实际 65,537 字节内容使“完成”不可用；两字素上限拒绝 abc，复杂字素 `👩🏽‍💻é` 准确回写；有效值 Return 接受、无效值 Return 不提交；清空返回未填写，Escape 保留原草稿。系统安全角色及遮蔽值、复制/剪切禁用、其他 Flutter 控件可达均被观察。最终焦点观察由控件祖先类型确认，不能使用 Release 已剥除的 debugLabel 判定。 |
| 实际退出 | 共 5 个独立 QA 进程正常退出 0。最终同一二进制分别在 desktopReady=true 和 false、安全 sheet 打开时按 ⌘Q 正常退出；ready 路径确实转发现有 quit。此夹具没有真实 worker/HTTP 服务，不能冒充执行中退出的完整生命周期验收。 |
| 外观 | 相对 9379dd5，四主题 × 100%/200% 字号，共 16 张 Flutter 前后图与 2 张对照图；两轮渲染均退出 0，QA 源码精确恢复。已目测状态、修改入口、滚动区和底部保存可达。系统 sheet 使用系统外观，不称其跟随 Flutter 主题/字号。 |

原生完整创建/轮换测试在菜单退出路由改动前完成；其 Dart 与 NativeSecretEditor 字节和最终版本相同，后续只调整 MainFlutterWindow 退出路由。最终六个生产输入文件与用于最终构建的 QA 副本逐字节一致。界面截图矩阵使用 channel 返回合成值，只证明父表单呈现；实际系统 sheet 由 CUA 操作证明，二者不混算。

原始失败保留：早期严格分析、测试 semantics handle 释放错误、矩阵测试 Dart 通配符变量错误、焦点和 Escape 观察，以及安全 sheet 阻挡 Quit 的复现。本轮修正后相关最终日志通过。CUA 的原生界面观察记录为文字转录，没有伪称已保存系统 sheet 截图；没有完整 VoiceOver 朗读、中文 IME 或物理键盘验收。剪贴板输入只含合成字串，工具负责恢复，不声称另行读取或哈希验证了主人剪贴板。

## 清理与交付范围

[验证清单](evidence/macos-native-secret-entry/verification.json) 记录 99 份自有源码、构建/运行/失败日志、设计取舍及图片的 SHA256。原始资料见 [raw](evidence/macos-native-secret-entry/raw/design-notes.md)。清理已退出的 QA 应用 LaunchServices 登记、源码副本和生成缓存，回收 1,152,692 KiB，约 1.10 GiB。项目构建/本地目录只留一份完整普通 App、零生成 dSYM（开发 SDK/cache 不在此口径）。

已逐项复核固定普通预览的 7,971 个载荷/链接，差异零，deep/strict 签名通过，原 PID 53592 仍在。SDK、旧 ZIP、私有加密备份和恢复密钥保留。实际 Keychain 调用与新增系统授权请求均为 0。

固定普通预览仍为 `4690e79357bb728da22193d8dadd6dc8a8ce2ce6`；保留候选 ZIP 仍为 `f93c3bd`，两者尚未包含本轮安全输入或前轮菜单状态修复。本轮没有替换已允许的应用、发布新 ZIP 或宣称普通安装升级通过。跨版本 Keychain 免重复确认仍属 #42/#50 的签名/安装工作，不能通过改 ACL 或关闭保护绕过。

#48 保持 OPEN、3/6；#50 保持 OPEN、2/6；#46 保持 OPEN、4/6。本轮解决秘密输入及其退出局部问题，仍需最终一致产物的普通入口验证，以及实际 IME、完整焦点/窗口范围、直接 Dock/状态栏、真实睡眠唤醒、通知回跳和干净用户等原条件。内存仓库验收不替代真实 SQLCipher 重开、Keychain 升级、Gatekeeper 或跨平台实机。

复跑材料在 raw 中：prepare.py/build.py/run.py、实际 QA 入口、视觉测试和 visual-matrix.py。按原目录布局复制源文件后构建；不要直接从 raw 路径重放准备脚本或清理脚本，也不要把 QA 入口作为普通产品入口。清理脚本只记录本轮拥有的路径和校验条件。
