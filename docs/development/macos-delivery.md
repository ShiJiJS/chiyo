# Agent Info Manage：Mac ARM64 开发预览

当前本机稳定安装位置、身份保留与升级顺序见 [本机安装约定](macos-local-installation.md)。
它补充历史交付记录；普通入口及升级是否通过，仍以各轮实际结果为准。

2026-10-22 [普通包文件访问矩阵](macos-sandbox-file-matrix.md) 又完成13个登记操作、
12次真实随包AWS启动，以及两次正常退出/重开，未新增主人钥匙串操作。明确区分
目录初选时访问、重开后只读书签、具体另存目标写入和未选相邻文件拒绝；发现当前
尚缺明确的持久工作目录读写入口。原777/附件保持、16条历史及8/5操作重开核对，
夹具和AOT驱动已清理，仍只有固定App一份。#44第2项保持开放，不以读成功代替写入支持。

2026-10-22 [修正整包与实际备份/被动升级核查](macos-package-upgrade-20261022.md)：
`7edb11c` 新包包含全选、最近使用及专用说明修正，713 通过/66 跳过、21 个阶段通过。
实际普通旧版导出备份经独立内存密钥目标恢复并重开通过。新版被动启动无法取得旧
Keychain，未发起系统提示，原库摘要保持；已恢复可用 `4690e79` 固定安装。
本轮生成重复 App/dSYM/构建缓存已清理，新旧 ZIP 和私有备份/恢复密钥保留。
最终升级及普通新版 GUI 仍待，不将新包构建通过当成安装通过。

2026-10-21 主人允许真实 Keychain 后，固定 `4690e79` 普通整包已实际启动，
系统 PATH 下随包 CLI、实际 SQLCipher 与 App worker、合成录入/部分批准/文件消费、
真实撤销/一分钟到期、两次正常退出和重开通过。#50 已有第二项实机证据；
全屏编辑时捕获黑屏的原因尚未定位，最终升级、通知、备份恢复、Codex 及干净环境
仍待，不能宣称最终日常闭环完成。见
[追加验收及限制](macos-local-installation.md#2026-10-21-主人允许后的普通安装包验收)。

同一固定包随后完成 [普通包 AWS 联合验收](macos-installed-aws.md)：真实中文空格文件
面板、随包 AWS/worker、签名成功读写、错误秘密、版本失效、撤销与五次操作历史重开。
详情页“尚未使用”的写死占位已在源码修正，27 项相关测试通过；修正尚未换入固定包，
不能将它当作当前安装界面已修复。原安装包字节和签名保持，未新增系统授权请求。

同一包进一步完成 [真实 SSH、空附件及执行中退出](macos-installed-ssh.md)：严格主机
校验、正确/错误私钥、真实 15 分钟到期、原生空文件另存/拒绝覆盖；执行中正常退出
后独立重开保留 unknown，进程结束后通过实际回执核查回收。未新增钥匙串允许，
原输入保留，合成私钥和测试材料已清理；#46 的故障分支另按历史原始证据逐项复核。

随后同包 [AOT 附件版本验收](macos-installed-file-versions.md) 补齐旧操作固定旧版、
新操作使用当前版、GUI 历史恢复、释放/撤销及独立重开持久化；结合已核对的同包
部分批准和真实到期证据，#44 第 4 项具备证据。另复现全选未生效，#48 尚待定位，
没有为诊断新建 Keychain 身份或重建包。

[Mac 全选衔接修正](macos-native-text-editing.md) 已进入源码，并在不访问资料库/
Keychain 的独立 Release 诊断中核对真实 Flutter 选区、原生菜单和系统面板取消边界。
8 项相关回归和严格分析通过；系统面板快捷键和最终普通包复验仍待，固定安装包
未替换。诊断应用和构建缓存已清理，未新增系统允许。

这是本机开发预览包，最终安装升级验收由 #50 跟踪。当前整包的版本、源码和载荷
以同目录 `manifest.json` 为准；下方按批次保留历史验证记录。产品名称为
Agent Info Manage，应用文件仍固定为 `app/info_desktop.app`，
bundle ID 保持 `com.example.infoDesktop`，不另建资料身份。

仅支持 Apple Silicon ARM64。最低构建目标为 macOS 14.0，来自随包 Dart AOT
程序的实际最低系统声明；目前仅在本机 macOS 27.0.1 执行相关验证，
macOS 14 和其他设备尚未实机验收。App、worker 和 CLI 主程序均为 ARM64，
依赖库至少包含 ARM64；不提供 Intel 兼容承诺。

## 随包凭据工具

`4690e79` 已生成包含工具的新整包；707 通过/66 条件跳过，21 个打包阶段通过。
ZIP 130,946,101 字节，SHA256
`0bebec70ba5860b25592024f8f6f00760b587ea91ef4c0d77c0fb0940bce360a`。
工具移动后的隔离实际 UI 与整包载荷逐清单一致；其历史范围不变。
普通包后续验证见上方追加记录，最终安装升级仍待。
详情与历史失败见 [生产工具交付记录](macos-production-tools.md)。

`scripts/dev-macos.sh build` 的 Release 构建现会从
`third_party/macos-tools.json` 固定的官方归档组装 GH 2.102.0 / AWS CLI 2.38.1，
下载缓存为项目 `.downloads/`；校验 SHA256 后解包，AWS 另核对 Apple 安装器签名。
不执行安装器脚本。完整载荷与许可保留在
`Contents/Resources/ThirdParty/`，逐文件清单含摘要、权限和内部符号链接；
打包脚本同时核对原生依赖、架构与最低系统，再核对中文路径解包后的全部字节。
GH 为 ARM64，AWS 官方依赖允许同时含 x86_64/ARM64，应用和 worker 仍只支持 ARM64。
首次缺少缓存时构建需要联网；已有缓存摘要不符会失败，需核对来源后重新下载。

Agent 的 `capabilities` 返回 `credential-tools.v1` 和 `credentialTools`：
按 receiver 选择 `available:true` 的准确路径，移动应用后重新查询。
设置 → 应用运行显示随包版本、入口状态及复制路径。发现仅检查入口摘要，
不执行工具、不访问既有认证，也不提供凭据使用授权；实际申请和操作继续核对
工具版本/身份与主人决定。系统 SSH 仍使用 `/usr/bin/ssh`，在操作时检查已支持版本。
缺少或损坏工具不阻塞资料功能。普通 `flutter run` 的 Debug 构建不组装工具，
需要工具实机验收时使用上述完整 Release 入口。

外部目录书签保留文件访问管理；目录可读不能转换成程序执行权。
GH/AWS 应使用随包路径。此机制不关闭 App Sandbox、不新增执行 entitlement，
仍为本机 ad-hoc 开发签名；Developer ID/公证与最终安装升级验收继续由 #50 跟踪。
下方 `01c1f14` 及更早的历史 ZIP 不含这次工具集成。

## 2026-10-21 纳入 Keychain 恢复入口的整包（#50 继续 OPEN）

固定干净源码 `01c1f141d876a9d3c49c61c7fc3d1e572c432c5a`，版本
`0.4.0+12-mac-dev.01c1f141d876`。包含主人主动请求 Keychain 访问的 `b98e487`，
以及等待授权时退出、迟到开库清理与退出重试竞态修复 `36a4bef`。
现有 `541a671` 包不含这些新改动；两份旧包和当前安装均保留，未发布 GitHub Release。

新 ZIP：
`build/macos-adaptation/issue50-package-7/agent-info-manage-0.4.0+12-mac-dev.01c1f141d876-macos-arm64.zip`。
**45,489,681 字节**，SHA256：
`860df96c93a3db4779724cddba5731caf7402c141308a51057d8502d198ac228`。

本轮从固定提交运行 `package-macos.py ... --check`，四包严格分析通过：
Core **285/6**、CLI **72/40**、Storage **159/18**、Desktop **187/2**（通过/跳过），
合计 **703 通过、66 跳过**；有条件跳过不算通过。21 个构建/签名/归档/解包阶段均退出 0。
App、worker、五个 CLI、诊断程序、Skill/引用、SQLCipher、许可证、锁和清单为同一源码产物；
133 个文件/链接、12 个 Mach-O，主程序均为 ARM64，原应用身份及 macOS 14.0 最低声明保持。
实际验证宿主仍仅 macOS 27.0.1，不扩大到其他系统或设备。

中文空格路径解包后，文件字节/权限/链接及 manifest 与原载荷一致，deep/strict 签名通过；
App 沙盒、用户文件选择、书签和网络权限保留，worker 继承沙盒，Release 无调试 entitlement。
在仅 `/usr/bin:/bin` PATH 下运行实际随包 AOT 诊断，确认 SQLCipher 4.19.0 community、
资料重开、独立目标恢复及旧授权拒绝；该诊断使用合成内存密钥，不覆盖 Keychain。
六项实际随包 CLI/hook/worker 检查通过，与源码测试重叠，不加到 703。
解包 CLI SHA256：`cb9971c43daa0bccf06c31d48c6ac3ab62f3e57c34bc96655c47202b9e14f5b7`。

[28 份原始构建/测试/清单与摘要](evidence/macos-delivery-keychain-access/verification.json)
按 Git 入库原字节保留；不提交 ZIP、数据库或密钥。本轮没有再次运行旧资料/附件 UI 场景，
也没有将 #42 隔离源码副本的真实 Keychain/模拟系统决定验证写成此 ZIP 的安装后 GUI 验收。
其各自版本与范围见 [Keychain 记录](macos-keychain-validation.md)。

Mac 仍锁屏。稳定位置实际 App、真实系统授权及签名/旧库升级、干净用户或独立 Mac、
真实文件面板/通知/Codex 和最终日常闭环仍待；#50 第一项整包证据刷新，其他五项不勾选。
远端 main 仍是 `b37f96a`，Windows 原生目录无改动，共享 bootstrap/launcher 的 Windows 实机回归仍待。
所有本轮改动仅推送 `codex/macos-adaptation`，未替换用户安装或修改系统信任。

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
