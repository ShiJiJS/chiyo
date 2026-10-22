# 包含菜单状态与原生安全输入的 Mac ARM64 候选（#50）

2026-10-22，以干净源码 `c6958daabcd77862f436db5088e08bb0bf3fa6b4` 生成
`0.4.0+12-mac-dev.c6958daabcd7`。此候选集中包含此前的编辑菜单状态/选区删除、
组合文字回归，以及最新 Mac 原生安全秘密输入和 sheet 期间退出路由。
生产源码只在独立 Mac 分支；主分支无新提交待整合，没有 Windows CI。

保留 ZIP：
`build/macos-adaptation/issue50-package-15/agent-info-manage-0.4.0+12-mac-dev.c6958daabcd7-macos-arm64.zip`

130,969,937 字节，SHA256：
`d9b0415f382a4c128adf9d55f5f18609eb78ef83b37745367b23066dd07988d7`。
Manifest SHA256：
`364bbd6ae13c676fab8988b4da82095f7cbd3cd956a42ce503d87e42f0245f04`。

## 这一份候选的验证

Stock `scripts/package-macos.py` 使用 `--check`，21 阶段全部退出 0。
四包严格分析通过，测试分布如下；跳过不计通过，不累加重叠的后续解包测试。

| 模块 | 通过 | 条件跳过 |
| --- | ---: | ---: |
| Core | 285 | 6 |
| CLI | 75 | 40 |
| Storage | 159 | 18 |
| Desktop | 215 | 2 |
| 合计 | 734 | 66 |

644 项源码输入在构建前后逐字节保持，并在两次核对中匹配固定提交的 Git 对象。
快照 SHA256 为 `cc3df4361407cd15a9fa3b646e9a516bb325b8685f0227c4686c26e5a72bab93`。
使用普通 `main.dart` Release 入口，未为该包替换 QA 入口、密钥策略或应用身份。

载荷 7,971 项、75 个 Mach-O。App/worker/CLI 的主程序 ARM64、依赖路径与最低系统
检查通过；沙盒、worker 继承保持，无 Release 调试 entitlement。包内和中文空格路径
解包后的 deep/strict 签名、权限和内部链接均通过。随包 SQLCipher 诊断与桌面库版本
相同，AOT CLI/hook 材料生成与 worker 生命周期检查通过。测试驱动使用 SDK；随包程序
在被测的系统 PATH 中执行，不要求用户安装 Xcode，仍不能据此宣称干净用户验收。

另直接从保留 ZIP 读取桌面 Mach-O，先核对 manifest 的字节数和 SHA256，再检查符号。
119 条匹配符号中同时存在 NativeSecretEditor 和 NativeTextEditingMenu，确认最新原生
实现实际进入交付二进制。临时检查文件已移除；符号检查不替代实际 GUI 行为测试。
主程序 SHA256 为 `956c3bb487975ba3c05e3bbe48af81ff17e67a23889a40df6a265ef75cd329c0`。

## 清理与仍待验收

三处生成 App 已注销；归档前/解包/诊断输出及生成缓存共九处回收
1,956,080 KiB，约 1.87 GiB。保留 ZIP、校验文件、manifest 与日志。
固定普通安装的 7,971 个文件/链接无差异，deep/strict 签名退出 0，PID 53592 仍在。
项目预览/构建扫描范围只留固定安装一份完整 App、零生成 dSYM；开发 SDK/cache
不在生成产物清理口径。旧 ZIP、私有备份、恢复密钥和已批准合成 Codex 项目保留。

当前固定安装仍为 `4690e79`，没有替换为此候选，没有发起生产 Keychain 访问或新的
系统授权，也没有安装/信任新的 hook。签名仍为本机 ad-hoc，未公证；最低声明 macOS
14.0，实测 ARM64/macOS 27.0.1。保留构建中的既有 legacy Keychain API 弃用警告，
不因构建成功宣称该 API 的未来兼容性已经验证。

[安全输入的实际原生验收](macos-native-secret-entry.md)属于隔离 QA 和内存仓库；
本轮整包构建/解包不能把它自动变成普通安装的完整 GUI 验收。最终同包 UI、中文 IME、
VoiceOver、真实通知/睡眠、签名升级保留旧 Keychain 与干净用户继续待办；#50 OPEN、2/6，
#48 OPEN、3/6。不得把限制 PATH、符号存在、绿色测试或旧版可重开当作这些条件已通过。

[30 份原始日志、源码输入快照及摘要](evidence/macos-package-c6958da/verification.json)
包含原始 stock 打包结果、监督器、manifest、清理和二进制包含证据。重新生成应选新的
build 子目录并保持干净源码，不覆盖本候选或正在运行的固定安装。
