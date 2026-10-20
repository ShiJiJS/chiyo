# Agent Info Manage：Mac ARM64 开发预览

这是本机开发预览包，最终安装升级验收由 #50 跟踪。当前整包的版本、源码和载荷
以同目录 `manifest.json` 为准；下方按批次保留历史验证记录。产品名称为
Agent Info Manage，应用文件仍固定为 `app/info_desktop.app`，
bundle ID 保持 `com.example.infoDesktop`，不另建资料身份。

仅支持 Apple Silicon ARM64。最低构建目标为 macOS 14.0，来自随包 Dart AOT
程序的实际最低系统声明；目前仅在本机 macOS 27.0.1 执行相关验证，
macOS 14 和其他设备尚未实机验收。App、worker 和 CLI 主程序均为 ARM64，
依赖库至少包含 ARM64；不提供 Intel 兼容承诺。

## 当前源码与已有整包的差异

`b98e487` 增加主人主动请求 Keychain 访问及等待时退出保护，`36a4bef` 补齐迟到开库清理与退出重试竞态，已完成源码 Release 构建、
签名核验、桌面回归及隔离原生验证，见 [#42 记录](macos-keychain-validation.md)。
下方 `541a671` ZIP 尚不包含此入口；刷新整包和实际安装/升级仍归 #50，旧包证据不扩展到新源码。

## 退出修复与后续整包

#42 的真实 Keychain 联合验收随后发现并修复了退出后界面访问已关闭资料库的问题
（`05326a7`，见 [联合验收记录](macos-keychain-validation.md)）。
下方 `c1a58b7` 整包的既有结果不包含此修复；现已刷新为 `541a671` 整包，验证范围见下一节。

## 2026-10-21 纳入退出修复的整包（#50 继续 OPEN）

固定源码 `541a6714473eb85810c984bc32797c5fb548b09d`，版本
`0.4.0+12-mac-dev.541a6714473e`，已包含 `05326a7` 的 launcher 退出保护。
ZIP 保存在项目：
`build/macos-adaptation/issue50-package-6/agent-info-manage-0.4.0+12-mac-dev.541a6714473e-macos-arm64.zip`。
45,487,290 字节，SHA256：
`ae7a4f00d3b79cf300800f05d55916254d8e39119631798a776595603add4640`。
旧包保留，未替换已安装应用或发布 GitHub Release。

干净源码执行 `python3 scripts/package-macos.py build/macos-adaptation/issue50-package-6 --check`：
四包严格分析通过；Core 285/6、CLI 72/40、Storage 159/18、Desktop 178/2
（通过/跳过），合计 **694 通过、66 跳过**。21 个打包阶段均返回 0。
133 项文件/符号链接、12 个 Mach-O；主程序 ARM64，最低声明 14.0，
实际验收宿主仅 macOS 27.0.1。App 仍为原 bundle identity，包含随包 worker、
CLI/hook/材料生成器、Skill/引用、SQLCipher、许可证、依赖锁和载荷清单。

解包到中文空格路径后，字节/权限/链接与清单一致，deep/strict 签名通过；
沙盒/书签/用户选择文件/网络 entitlement 保留，worker 继承沙盒，Release 无调试权限。
仅 `/usr/bin:/bin` PATH 下实际存储诊断确认 SQLCipher 4.19.0 community、
资料重开、独立目标恢复与旧授权拒绝。六项随包 CLI/hook/worker 测试通过，
与源码用例重叠，不累加到 694。CLI SHA256：
`ecf7736d915a653d33a922253e670f63ead19d0776598e28965e89d57aff18fb`。

本轮没有重跑资料筛选/附件 UI 场景；下方 `c1a58b7` 的原生联合结果保持历史范围。
退出修复的普通 Release Flutter + 真实 Keychain 隔离副本验证单列在
[#42 记录](macos-keychain-validation.md)，不能冒充此 ZIP 的已安装 GUI 流程。
远端 main 仍为 `b37f96a`，Windows 原生目录无改动，共享 launcher 的 Windows 实机回归仍待。

[原始构建/测试/解包日志、清单及摘要](evidence/macos-delivery-shutdown-fix/verification.json)
保存源码版本与范围；不含数据库、测试密钥或 ZIP 二进制。
#50 第一条整包组成/身份/版本/架构证据已刷新，其余五条继续未完成：
稳定位置实际应用、签名升级、干净用户、系统面板/通知/Codex 和最终日常工作闭环。

## 包含内容

- `app/info_desktop.app`：Release 桌面应用、SQLCipher、Flutter 运行库及随包 worker。
- `cli/`：无需 Dart SDK 的通用 CLI、Codex 适配器、hook、worker 和材料生成器，
  同时包含 Skill 模板及凭据/普通附件引用。
- `diagnostics/bin/macos-storage-check` 与 `diagnostics/lib/`：
  使用新建合成库验证加密、重开和独立备份恢复的可选诊断程序。
  它使用临时内存密钥，不读取生产库、不验证 Keychain。
- `notices/` 与 `provenance/`：许可证、第三方声明、依赖锁和原生资产来源记录。
- `manifest.json`：版本、源码 SHA、构建宿主、应用身份、最低系统、
  原生架构、签名类型、文件摘要/权限和符号链接。

运行 App 和随包程序不需要 Xcode、Flutter 或 Dart。
当前为本机 ad-hoc 签名，未公证；它不代表其他设备的 Gatekeeper 已通过，
也不保证替换构建后能继续读取旧 Keychain 项。不要用尚未验证的预览包覆盖唯一
可用的旧应用。先保留旧包，并在旧应用中导出完整备份、另存恢复密钥；
旧应用的实际升级/授权恢复仍由 #42/#50 完成，不关闭系统保护来绕过失败。

## 路径与 Codex 材料

先将整个 `AgentInfoManage` 目录放到稳定位置，保留目录结构。
本包的准备命令只写入一个不存在的新目录：

```bash
"/你的稳定路径/AgentInfoManage/cli/info-prepare-codex" \
  "/另一个稳定路径/agent-info-codex"
```

它复制同版本 CLI/hook/worker，生成最终绝对路径的 `hooks.json`、Skill 和引用，
拒绝覆盖已有目录。支持中文、空格与 shell 特殊字符路径。生成后移动目录会让
旧 hook 路径失效，应在新的稳定位置重新生成并审查接入配置。

该命令不会安装/注册/信任 hook，不修改已有 Codex 配置或启动聊天。
接入与实际聊天事件验收见随包 `CODEX-INTEGRATION.md` 和 #49；
其中 Windows 的实机记录不自动适用于此 Mac 包。Mac 的焦点填充尚未支持，
以当前服务 capabilities 为准。

## 构建与验证范围

在干净、已提交的 Mac 分支根目录运行：

```bash
python3 scripts/package-macos.py build/macos-adaptation/new-delivery
# 同时执行四包全部源码检查
python3 scripts/package-macos.py build/macos-adaptation/new-checked-delivery --check
```

仅构建者需要项目工具链和 Python。打包器不改 Flutter 全局设置，
检查源码期间未变化，核对签名/沙盒/架构/最低系统和开发机外部库依赖，
生成 ZIP 与 SHA-256，再解压到中文空格目录复核文件、权限、符号链接和签名。
从解压目录限制 PATH 运行合成存储诊断，并用实际 AOT 材料生成器和 CLI worker
执行相应测试。诊断的源码测试驱动仍需 SDK；随包运行程序本身不需要。

构建输出的 `verification.json` 只有 `complete: true` 才代表上述打包检查通过；
源码四包检查仅在 `sourceChecksRequested: true` 时由打包器运行。
这些结果不等于干净用户安装、Keychain 升级、真实通知、可见系统面板或
真实 Codex 接入已验收。最终同版本应用全流程仍需 #41–#49 的剩余门槛。

## 2026-10-21 同源码整包更新与联合回归

本轮固定干净源码 `c1a58b758dc41bbdfe8699ec67fd6c350224b294`，纳入近期历史界面、
多标签滚动和大字号计数修复。新包版本 `0.4.0+12-mac-dev.c1a58b758dc4`，
保留首轮包，不覆盖现有安装，也未发布 GitHub Release。

本地 ZIP：
`build/macos-adaptation/issue50-package-5/agent-info-manage-0.4.0+12-mac-dev.c1a58b758dc4-macos-arm64.zip`
（45,483,253 字节），SHA-256：
`5d1219c50d7bc767af8af792d2b8ce76cbb372aa0e74f7d2305e8ddbb7c69d1d`。

本轮通过 `package-macos.py --check` 在上述源码重新执行四包严格分析及测试：
Core 285/6、CLI 72/40、Storage 159/18、Desktop 174/2（通过/跳过），
合计 **690 通过、66 跳过**，没有把旧源码结果作为本轮结果。
21 个打包阶段均返回 0；133 项文件/链接、12 个 Mach-O，App 与五个 CLI、
worker、Skill/引用、SQLCipher 诊断、许可证/依赖锁和清单齐备。
产品名称、bundle 身份、最低系统及 ARM64 范围沿用上文，实际宿主仍为 macOS 27.0.1。

中文空格目录解包后的字节、权限、链接及清单核对通过；App deep/strict 签名通过，
沙盒、用户选择文件、书签和网络 entitlement 保留，worker 继承沙盒，Release 不含调试访问权限。
受限 PATH 下运行实际 AOT 存储诊断，确认 SQLCipher 4.19.0 community、资料重开、
独立目标恢复与旧许可拒绝；六项随包 CLI/hook 材料生成及 worker 生命周期检查通过。
这六项与源码测试有重叠，不额外累加到 690 项。

另外用新包内 `cli/info` 联合当前源码的 Mac 原生测试宿主：

| 场景 | 阶段 | CLI 状态核对 | 结果 |
| --- | ---: | ---: | --- |
| 目录/标签、搜索分页及容量 | 6 | 38 | 125 条资料、52 标签、四主题与 100%/200%、库重开通过 |
| 普通编辑、提案和恢复保留附件 | 10 | 44 | 六次真实交付/释放，1024 字节原文、身份与版本保持，重新授权及库重开通过 |

两轮记录的 `appBaseCommit` 与 `productSource` 均为 `c1a58b7`，CLI 摘要均为
`4e0a9920648c71bde9571410cede0624afccaed0097ca297633a4417197f71e2`。
Flutter 和五个 CLI 实例均正常退出 0；之后已恢复普通入口 Debug 构建并通过严格签名检查。
这是同源码的 Debug 原生测试宿主与交付 AOT CLI 联合回归，
**不是已安装 Release 应用的最终 GUI 闭环**。临时密钥、测试文本通道、合成资料和受控审批的边界保留。

本轮可证明 #50 第一项“整包组成、身份/版本/架构、清单与摘要”，其他复合条件继续待验。
稳定位置实际启动、真实 Keychain 升级、干净用户/独立 Mac、通知/系统面板和真实 Codex
没有因本轮通过而完成；当前仍为本机 ad-hoc、未公证包。
远端 main 同轮核对仍为 `b37f96a`；Windows 原生代码目录未改，当前共享 UI 的 Windows 实机回归仍待。
[101 份原始资料、摘要与范围索引](evidence/macos-delivery-refresh/verification.json) 已保存，
包含四包日志、打包清单、联合检查与原生渲染图；不包含数据库、测试密钥或 ZIP 二进制。

## 2026-10-21 首轮打包验证记录（#50 继续 OPEN）

首轮已验证的本机预览版本 `0.4.0+12-mac-dev.cccc37e4a112`，产品与打包器源码
`cccc37e4a1125f88c7714a26b1873fdb2ffb7a9c`，位于独立 Mac 分支。
ZIP 保留在本项目
`build/macos-adaptation/issue50-package-4/agent-info-manage-0.4.0+12-mac-dev.cccc37e4a112-macos-arm64.zip`，
45,484,523 字节，SHA-256：
`b1a869203f2a43d87b325a88c4bb8f6c6819e502c4dc062a8df9c74929838a6d`。
未上传二进制或发布 GitHub Release，未替换用户已安装应用。

运行环境：Apple Silicon、macOS 27.0.1、Xcode 27.1/SDK 27.0、
Flutter 3.47.7（`abaf9c523780a608bd46686fd5e53740a07077f8`）、
Dart 3.13.5。实际 App 为 49.2 MB，133 项文件/符号链接载荷和 12 个 Mach-O
记录在清单中；主程序均 ARM64，所有实际最低系统声明不高于 App 的 14.0。
这不等于在 macOS 14 上运行验收。

已验证范围：

- `fc0f5e5` 的四包严格分析及测试：Core 285/6、CLI 72/40、
  Storage 159/18、Desktop 173/2（通过/跳过），合计 689 通过、66 跳过。
  跳过记录逐项留在原始日志，不能作为通过。之后仅调整 Python 哈希兼容、
  Xcode 构建/签名和交付测试模板来源；没有将旧全量结果冒称在最终 SHA 重跑。
  最后 CLI 严格分析通过。
- `cccc37e` 实际 ZIP 解压到中文空格目录，逐项核对文件字节、权限、符号链接
  和清单；另一次独立遍历与 SHA 检查同样确认 133 项及 ZIP 摘要。
  解压后的 App 通过 `codesign --verify --deep --strict`，沙盒、用户选择文件、
  书签和网络能力保留，随包 worker 仍继承沙盒，Release 不含 `get-task-allow`。
- 解压后的 AOT 存储诊断在仅 `/usr/bin:/bin` 的 PATH 下通过：
  SQLCipher 4.19.0 community、合成资料重开、旧授权拒绝、独立目标密钥恢复。
  App 内实际 SQLCipher 的内存版本探针与诊断一致；诊断使用内存密钥，
  不构成真实 Keychain 或 App 界面通过。
- 6 项实际随包程序检查通过：AOT 材料生成器/CLI/hook、包内 Skill/引用、
  中文/空格/单引号/字面 shell 替换字符路径、拒绝覆盖和源目录移除后运行；
  另含 CLI worker 的登记前断连、放行后独立执行、worker 崩溃后后代、
  短命令零退出及信号退出。被测程序使用受限 PATH，测试驱动仍使用 Dart SDK；
  CLI worker 检查不冒充沙盒 App 的宿主联合验收。6 项与源码测试重叠，不累加。

保留的失败及修复：

1. 初始检查的 Core 测试引用了不存在的 matcher，改用现有 `isA` matcher；
   随后上述四包完整检查通过。原失败日志保留。
2. run-01 在计算摘要时使用 Python 3.11 才有的 `hashlib.file_digest`，
   本机 Python 3.9 报错；改为有界分块 SHA-256。该次 `complete=false`，
   不称为完成的包。
3. run-02 构建成功但 App 严格签名失败；原构建目录同样失败，排除复制问题。
   当时详细校验指出 `Contents/MacOS/info-runtime-worker` 被修改，而 worker
   自身签名有效。Xcode 的 worker 脚本阶段每次运行却没有声明输出，
   增量构建遗漏外层重新签名。`28be55c` 声明 worker 输出路径后，
   连续两次 Release 构建及严格校验通过，日志中均有外层 CodeSign。
4. run-03 首次完成打包/解包检查，但人工审核清单发现 Xcode 自动注入
   `get-task-allow`。`cccc37e` 仅在 Release 禁用基础 entitlement 注入，
   打包器增加拒绝检查，并让交付测试使用解压包内的 Skill 模板。
   run-04 整包复验通过，以 run-04 为该轮有效产物；不交付 run-03。

88 份原始记录、各阶段源码摘要和最终载荷清单见
[证据索引](evidence/macos-delivery/verification.json)。
失败记录、run-03 和 run-04 均保留，生成的测试库、备份和密钥不纳入证据。
本次 Mac 处于锁屏状态，没有声称运行实际 GUI、通知、系统面板或真实 Codex。
稳定路径 App 启动、两版签名的 Keychain 升级、干净用户安装及
#41–#49 剩余联合验收未完成，#50/#19 保持 OPEN。
