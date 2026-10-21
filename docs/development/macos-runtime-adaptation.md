# Mac 凭据执行与普通附件适配

- [#48 解锁后的真实文件面板](macos-native-file-panels.md)：Computer Use 实际 NSOpenPanel 选择/取消、NSSavePanel 保存/取消、文件版本 2 保存及同库新进程重开通过；两份导出副本字节一致，物理输入法与最终安装条件仍待。

- [#48 当前资料与凭据管理](macos-management-current.md)：文件凭据补齐、字符串及信息/模板/提案/整理在当前源码重跑，五组原生流程及 11 个独立 CLI 通过；结合同源目录/搜索证据，第 1/2/3 条完成，#48 为 3/6、保持 OPEN。系统面板与物理输入仍待。

- [#48 旧审批与历史状态](macos-history-states.md)：第 3 条按 16 阶段/25 次独立 CLI 读取、实际界面撤销和一分钟自然到期收口；现第 2/3 条完成，#48 保持 OPEN。

- [#48 大资料库与长申请](macos-large-library-history.md)：1000 条资料/20 页、32 目录、128 标签及四主题字号矩阵通过；502 条历史/63 页、200 字段真实组件审批与库重开通过。70 次目录/边界协议核对及 22 次历史流程 CLI 读取核对通过；仍待物理输入等完整条件，#48 保持 OPEN。

开发分支：`codex/macos-adaptation`。2026-10-21 已保存原有适配并整合固定主分支 `b37f96a089d6d4a0a9f872bd667be0c6b037f975`，合并源码及四包/Release 验证见 [主分支整合记录](macos-main-integration.md)。下文 2026-10-20 的实机证据仍仅代表原 `0855120` 基线上的适配，不自动扩展到新包。环境准备记录见 [macOS 本机环境](macos-local-setup.md)。

## 2026-10-21 当前执行记录

按票序核对 #41：整合、重叠保留与工具链/来源的第 1/2/3/5 条已在 GitHub 对应证据勾选；
第 4 条仍缺当前共享修改的 Windows 实机回归，远端 main 重新读取仍为 `b37f96a`。
#42 新增 [实际旧源 schema 20→21 迁移](macos-schema-upgrade.md)（QA `0407589`）：
16 阶段/8 场景，28 持久表与附件版本字节保持、冲突/错密钥/旧读者拒绝与同目标重试通过。
实际系统 Keychain 授权和签名应用联合升级仍待，不提前勾选复合条件。

#44 新增实际生产上限验收（QA `fc491f7`）：10 MiB 单文件、原件/草稿 100 MiB、
200 暂存/32 草稿、100 MiB/32 份受管副本均核对拒绝与释放重试；两个独立 CLI 会话共享配额。
最终八阶段/146 次 CLI 状态、44 次交付；最大文件和空文件实际上传原字节一致，释放后不可再用。
真实 SQLCipher/生产容量组件、持久历史及输入不变通过；见 [容量记录](macos-file-capacity.md)。
真实系统面板、外部 GH/AWS 和最终安装包联合条件仍待，#44 不提前关闭。

#48 文件完整生命周期（QA `72863c8`）完成替换/取消、版本差异恢复、删除/回收恢复、
原生历史撤销、真实一分钟到期和库重开；最终十七阶段/46 次 CLI 状态检查，
六份文件实际消费且失效后旧路径不可再上传，授权/交付关联保持。
第 2 条结合既有文本编辑/提案保留证据收口；其余实际输入/面板/最终包仍待。
参见 [文件生命周期记录](macos-file-lifecycle.md)，未改生产代码或已有整包。

#44 同机附件消费（QA `2cd6111`）已完成真实系统 curl → loopback HTTP 接收：
原生 Flutter/SQLCipher + 独立整包 CLI 的六份交付逐字节一致，释放后六次再上传均失败且无新增接收；
十阶段/44 次 CLI 状态断言通过。第 5 条有直接证据，其他实机及最终包条件仍待；
临时密钥/审批为夹具，Debug 测试宿主不代替 Release 安装。见 [文件消费记录](macos-tools-files.md)。

#42 新增真实专属钥匙串锁定验收（QA `9f8c829`）：签名 Release Flutter 的锁定失败/重试、解锁恢复及锁定状态正常退出通过；后续独立进程确认仍锁定，清理后默认钥匙串/搜索列表恢复。原第 2/3/5 条有范围对应证据，第 1/4 条签名/升级仍待；生产代码与最新整包未变。见 [Keychain 验收映射](macos-keychain-validation.md)。

最新 #42 源码 `36a4bef` 已补主人主动请求 Keychain 访问、等待时退出保护和迟到开库的清理竞态：
最终桌面 187/2、7 个模拟系统决定的签名 Release 进程通过；20 个真实 Keychain 普通故障回归进程对应先前 `b98e487`。
入口和修复已纳入 `01c1f14` 整包。后续用户亲自允许后的[真实 Keychain 恢复与两版重开](macos-keychain-owner-allow.md)已通过；正式签名/旧 schema 迁移联合升级和最终包仍待，源码验证范围见 [Keychain 记录](macos-keychain-validation.md)。

- [#41 主分支整合](macos-main-integration.md)：已固定新基线并构建，当前 Mac 分支的 Windows 实机回归仍待。
- [#43 故障恢复](macos-lifecycle-recovery.md)：已按原有 6 条条件完成收口；既有 8 项 SQLCipher/AOT 联合场景、5 项 Darwin worker 检查，加上两种签名 Flutter/系统 SSH 故障重开及本次 41 项定向检查。无法确认旧进程时保留材料，实际结束后回收，不重放命令。
- [#42 Keychain](macos-keychain-validation.md)：实际 Release Flutter + Keychain + SQLCipher 的 20 次进程验证通过，补齐创建/重开、缺失/坏值/错误密钥/损坏库保留与重试；发现并修复退出后界面读已关闭资料库，桌面 178 通过/2 跳过。后续[真实系统允许](macos-keychain-owner-allow.md)完成新 ad-hoc 签名访问原密钥、恢复原库、新旧版独立重开，7 个进程退出 0 并清理测试项；不替代不同 schema 的签名应用联合迁移或正式安装。
- [#44 工具与附件](macos-tools-files.md)：外部 GH/AWS 实测 EPERM 后，已新增主人选择工具目录与系统书签持久化入口；原生存储/界面回归及新包 SSH/附件工作流通过，真实目录许可、外部 GH/AWS、当前系统面板仍待验收。
- [#45 备份恢复](macos-backup-recovery.md)：签名 Flutter 的 7/8/9 格式恢复、签名 Release 应用与独立 AOT 的 80 MiB 中断回滚/同目标重试，以及固定旧源 5/6 兼容已通过；另已完成真实 Keychain 源密钥丢失后，独立新目标的格式 9 恢复/重开与 2 MiB 附件及历史关系核对；真实面板、最终交付包联合验收与 Windows 双向迁移仍待。
- [#46 应用生命周期](macos-lifecycle-recovery.md)：实际签名 Flutter 的重复启动拒绝、正常退出/重开、SIGKILL 重开、缺失密钥、47125 占用、初始化期间退出和 SQLCipher 审计失败重试已通过；9 个正常退出、1 个故障注入，实际菜单/睡眠唤醒仍待。执行中 worker 联合场景已在 #43 补齐。
- [#48 移除范围与历史](evidence/macos-removed-scope-ui/verification.json)：真实 Mac Flutter/SQLCipher 与独立 AOT CLI 的 9 阶段流程连续三轮通过，每轮 19 次读取断言；四主题、200% 滚动及有效/已结束筛选与权限一致。随后修正访问次数断行，补充完整应用导航内 19 条记录/三页/24 字段长申请的搜索、滚动及清除复验，见[新增证据](evidence/macos-history-layout/verification.json)。实际系统面板、键盘、其他资料管理及大规模数据压力仍待。
- [#48 资料管理闭环](evidence/macos-library-ui/verification.json)：新增实际 Mac Flutter/SQLCipher + 独立 AOT CLI 的模板、编辑、删除恢复、版本恢复及库重开验证；最终九阶段/18 次读取断言通过，模板修改与既有信息隔离、取消确认及关闭弹窗后详情刷新均独立核对。提案/整理/凭据等其余流程、真实输入和系统面板仍待。
- [#48 提案闭环](evidence/macos-proposals-ui/verification.json)：实际 Mac 原生审核完成批量提案调整、分类校验失败保留草稿与原子重试、拒绝、删除、冲突拒绝与新版本再次确认；最终 11 阶段/22 次独立 CLI 状态和 3 次公开目录检查，重开后五条处理记录及当前内容保持。整理、附件与提案联合场景、真实输入等继续待做。
- [#48 整理闭环](evidence/macos-organization-ui/verification.json)：六个整理任务覆盖缩小范围、自动应用、整批冲突、撤销、拒绝、无改动结束及库重开；最终 12 阶段/49 次独立 CLI 状态断言通过。保留首轮过早查找 UI 的失败；睡眠/到期、真实输入及其余资料流程仍待。
- [#48 附件保留闭环](evidence/macos-attachment-preserve-ui/verification.json)：原生文本编辑、修改提案确认、文本删除/恢复及库重开保持附件身份、版本与原文；最终十阶段/44 次 CLI 状态核对、六次真实交付/释放通过。初始文件准备与审批为夹具，实际系统面板仍待。
- [#48 字符串凭据管理](evidence/macos-credential-management-ui/verification.json)：原生创建/元数据/关联/轮换/停用/版本与回收恢复/过期/隐藏及库重开，最终十五阶段、55 次 CLI 状态核对通过。明确使用测试文本通道；真实输入法清空到期时间、文件凭据面板与实际使用授权仍需联合验收。
- [#48 目录、标签与搜索](evidence/macos-library-filters-ui/verification.json)：原生目录创建/循环拒绝/移动、标签改名、125 条资料分页/组合筛选/库重开及 38 次 CLI 核对通过；修复多标签侧栏和大字号计数溢出，52 标签、四主题及 100%/200% 矩阵通过。Windows 实机与真实输入仍待。
- [#49 真实 Codex 合成验收](macos-codex-real-client.md)：正式入口逐条信任了用户批准项目的三个 hook；真实模型完成部分批准、多次读取、隔离/撤销、附件实际消费与释放，以及压缩、分叉、清空、SessionEnd 和结束后恢复的组件验证。后续[运行时续验](macos-codex-runtime-continuation.md)补齐实际传输恢复、自然到期、同库进程重开和 SSH 凭据复用；用户安排的[真实主子委托](macos-codex-delegation.md)补齐同根/范围/固定到期、子引用绑定、实际中断与根结束后的拒绝，六项均有证据。物理系统操作和最终包联合验收仍按各票及 #50 保留。
- [#50 ARM64 交付](macos-delivery.md)：`01c1f14` 新包纳入 Keychain 恢复入口和迟到清理退出保护，四包 703 通过/66 跳过，21 个打包阶段及六项随包检查通过。此前原生资料/附件及隔离 Keychain 场景保持各自版本范围；第一项整包清单与身份/架构证据已刷新，稳定安装、真实 Keychain 授权/升级与最终实际 GUI/Codex 仍待。

#43 已完成其范围，其余上述票据仍 OPEN；具体未完成条件以 GitHub 票据及各记录为准。现有证据不等于 Mac 总票 #19 已可交付。

### #48 目录、标签、搜索分页与标签容量验收

源码 `9ea4526`（Mac 独立分支），本轮修改共享 `library.dart` 布局，并新增原生场景与回归。
以实际 Mac Flutter/SQLCipher 运行，独立 AOT CLI 使用既有 `cccc37e` 产物；
[证据与摘要](evidence/macos-library-filters-ui/verification.json) 保留五轮日志、截图和各轮源码。

原生界面创建三个目录（含父子层级）和两个标签，尝试把父目录移动到子目录时拒绝并保留原层级；
125 条合成资料为容量夹具。验证三页列表及末页详情、公开字段说明搜索、无匹配清空详情、
超过长度限制的失败提示及恢复、父目录包含/排除下级、两标签 AND 筛选。
私人分类名称和字段原文不会作为公开内容搜索命中。
随后通过界面移动并改名子目录、改名标签，父/目标目录计数相应变化，
所有信息项与字段的身份、版本、字段值和原目录 ID 保持；同进程库/服务重开后再次核对。

六个交换阶段内独立 CLI 完成 38 次命令状态断言：四轮遍历公开目录的全部 125 项，
确认没有重复、原文及私人目录/标签名称；搜索、目录/标签筛选总数吻合。
已批准首字段在移动前后仍可读取；库重开后旧请求无法读取。
本例不声称覆盖所有未授权字段、自然到期或应用进程重启。

容量检查发现并修复：

- 50 个标签在普通字号造成侧栏纵向溢出 1023 像素；标签区域改为受视口高度约束的独立滚动。
- 200% 字号的列表分页栏横向溢出 47 像素；总数使用可用宽度并允许换行。
- 三位数资料计数与侧栏标题挤压；标题/计数按空间换行，“全部信息”文字受可用宽度约束。
- 原生图检查发现首次换行调整使普通字号标题与计数贴近；最终保留全行宽度恢复正常间距。

最终 run-5 为 125 条资料、3 个目录、52 个标签；完整应用内四主题 × 100%/200%，
1280×800 下可滚动选中最后标签、清除筛选、翻到第二页，无未处理布局异常。
主流程使用 1440×1000，最终共 33 张 Flutter 渲染图；这不是物理屏幕截图或全量性能保证。
Flutter 与两个独立 CLI 均退出 0；严格分析、六项相关 widget 回归、普通入口 Debug 重建和严格签名验证通过。
源码摘要与最终被测文件核对一致。

失败记录也保留：run-1 把 claim 的预期误写为 approved，实际协议返回 ok，修正测试驱动后 run-2 主流程通过；
run-3 扩大标签/字号场景后实际触发侧栏标题溢出；run-4 自动流程通过但视觉复核发现间距问题；
run-5 为最终修复与补拍。中间 widget 诊断包括一次无字段夹具被拒绝，随后改为合法合成字段；
这些失败均不算通过。失败原生轮次未捕获 Flutter 退出码时保持 null。

复跑（输出目录须不存在）：

```sh
python3 scripts/qa/macos-library-filters-ui.py build/macos-adaptation/issue48-library-filters-ui-next \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

当前桌面锁定，文字使用已注册的 TestTextInput；临时密钥、资料/压力标签准备和内容审批为夹具。
初始目录/标签创建及后续改名/移动由原生测试驱动。产品没有目录/标签删除入口，本例未新增或声称验收删除功能。
真实中文输入/键盘/焦点、系统面板、Keychain、Windows 原生 UI 回归和最终同源交付仍未完成；
本轮共享 UI 改动在合并前须由 #41 补 Windows 实机回归，#48 六条复合条件保持未勾选。

### #48 字符串凭据管理、可见性与版本恢复的原生验收

QA 源码 `33a8631` 新增 `macos_credential_management_native_test.dart` 与
`scripts/qa/macos-credential-management-ui.py`，产品基线 `8f917f6` 不变。
[固定证据](evidence/macos-credential-management-ui/verification.json)保存六轮原始日志、源码及截图，
父进程使用已核对摘要的 `cccc37e` ARM64 AOT CLI。

实际 Mac Flutter/SQLCipher 中，由 tester 新建字符串凭据，输入框 obscured，保存后详情不显示秘密。
默认不可发现；UI 将其关联到夹具普通信息后仍不可发现，关联不产生内容读取许可。
修改名称、公开用途、私有备注及可见性，先输入无效日期，保存被拒绝且原元数据保持；
纠正并保存后，独立 CLI 凭据目录只含约定的六个公开字段，不含秘密、私有备注或普通字段值。

UI 轮换到版本 2，旧版本 1 加密材料保留；停用/启用与 CLI availability 一致。
版本恢复以版本 1 原文建立停用版本 3，重新启用后才能作为当前可用版本。
删除先取消（不写入）再确认，目录消失、普通信息及关联保留；凭据回收站恢复建立停用版本 4，
材料与版本 1 一致，重新启用；设置过去日期显示过期并拒绝申请，清除日期并关闭可见性后重新隐藏。
关闭服务/真实加密库并在同一进程重开，名称/用途/私有备注/关联/四个版本及当前启用隐藏状态保持，
普通信息身份、版本 1 和字段值全过程不变。

每个检查点独立 CLI 核对凭据目录与普通目录，并验证凭据编号不能当作普通内容许可。
13 次有意不符合条件的 request-use 精确返回 invalid_reference、credential_version_changed、
credential_disabled、credential_deleted 或 credential_expired，operationClaimed=false。
服务中的使用请求及执行始终为零；这没有证明实际批准、旧 grant 撤销、秘密注入或 worker 运行。
正常执行仍依 #44 的实际运行场景验收，不能把请求拒绝当成命令执行通过。

输入边界与失败记录：run-1 在无效日期重试后仍读到旧名称；run-2 增加最多五秒等待保存窗口关闭，仍失败。
run-3 核对编辑器/当前 revision 都为 2，诊断和截图证明空字符串注入后到期框仍保留 not-a-date。
run-4 聚焦后模拟 Meta+A/Backspace 仍未清空。Flutter 本地集成 binding 默认不注册测试文本通道，
其 TestTextInput 文档说明与真实 IME 混用可能导致状态不同步；这是诊断依据，不是已经确认真实用户输入缺陷。
run-5 显式注册 TestTextInput 后完整通过，输入框内容逐次断言；退出前注销，产品代码不变。
随后严格分析报单个 if 缺少大括号，run-6 仅补括号并验证最终源码完整流程。

run-5/6 各 complete=true、十五阶段、55 次命令状态断言、14 次凭据目录核对及 15 张原生图，
Flutter 和两份 CLI 正常退出 0；两轮成功专属根已清理。前四轮失败根仅本机保留，
没有伪造其未捕获的 Flutter 退出码，也不累加重叠通过结果。
最终严格分析、凭据界面/维护五项回归通过，普通 main.dart Debug 恢复及 deep/strict 验签通过。
主 agent 目测公开/轮换/两种恢复/过期/重开页面及最后元数据编辑图；1440×1000 紫棠主题无阻断性布局问题。
主人界面按设计显示私有备注（全部为合成内容）；CLI 回包不含这些值。

复跑（输出目录必须不存在）：

```sh
python3 scripts/qa/macos-credential-management-ui.py build/macos-adaptation/credential-management-new-run \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

Computer Use 本轮仍报告锁屏；全部运行都有 foreground open returned 1。
文本输入通过注册的测试通道，不覆盖真实键盘、中文 IME 或物理焦点。
**待实机补验：正常应用内使用真实键盘/IME 清空无效或已有到期时间、再次保存，以及焦点/快捷键。**
此外文件凭据的原生选择/替换、有效使用许可与轮换/停用联合场景、自然到期/睡眠、Keychain、
规模压力及最终同源包仍未因本轮完成。#48 六条复合验收保持未勾选。

### #48 普通编辑、修改提案与文本恢复保留附件的原生验收

QA 源码 `123868f` 新增 `macos_attachment_preserve_native_test.dart` 与
`scripts/qa/macos-attachment-preserve-ui.py`，产品基线 `07df31a` 未改。
[固定证据](evidence/macos-attachment-preserve-ui/verification.json)保留三轮源码、日志和原生截图；
独立父进程使用核对摘要后的 `cccc37e` ARM64 AOT CLI，经真实 HTTP/JSON-lines 交互。

夹具通过正式 Owner 暂存/提交接口创建一项“文本 + 1,024 字节二进制附件”资料，
原文件中文/空格名称；资料、密钥和审批为隔离测试准备，不当作真实文件选择或 Keychain。
原生 InformationApp 由 tester 打开编辑器修改文本及公开说明，再确认独立 CLI 提交的文本修改提案。
两次保存后附件字段身份、附件身份、版本 1 和全部原字节保持，源文件未修改，暂存为零。
提案页面显示“保留原文件与版本”及真实元数据，确认提案本身不扩大内容授权。

随后通过 UI 移除文本字段，确认后信息只剩附件；独立 CLI 旧文本读取被拒绝，原文件许可仍可领取。
通过回收站恢复文本后生成新字段身份，旧许可不能读取旧字段或新字段，重新批准新身份才可读取。
附件全程保持原身份/版本/原文，原文件许可到期时间不变；信息最终版本为 5。
同一原生进程关闭服务/SQLCipher 后重开，混合资料和确认提案状态保留，旧授权失效。
新 CLI 会话持旧文件请求被拒绝，重新批准文件后能领取完全相同原文，但不能读取文本。

最终 run-3：complete=true、十阶段、44 次命令状态断言、八张原生渲染图。
六次不同文件交付逐字节匹配 1,024 字节，每次重复 operationId 取得同一交付，
释放后路径不存在；申请前及另一会话的领取均被拒绝且未占用操作。
Flutter 与三份 CLI 正常退出 0，成功专属合成根已清理。

首轮隔离 AgentServer 未启用附件能力，按默认契约返回 unsupported_capability；
仅修正测试入口两个能力开关，与生产 Mac bootstrap 一致。首轮父进程在失败后终止自己的测试宿主，
不能称为自然退出；失败根仍本机保留。第二轮错误期待 Owner 编辑器出现提案编辑器的占位文案，
实际显示 InformationFileSummary；修正测试为真实文件控件并补截图，失败源码/日志和本机根仍保留。
两个失败轮均未伪造缺失的 Flutter 退出码，未改产品边界或重复累计通过数。

最终严格分析、文件编辑/修改提案九项回归通过；恢复普通 main.dart Debug 并 deep/strict 验签通过。
主 agent 目测文件编辑区、文本修改、提案审核、仅文件状态、文本恢复及重开页面；
1440×1000 紫棠主题没有阻断性布局问题，图中元数据和数据库/交付断言一致。
三轮都有 foreground open returned 1；Computer Use 同期确认锁屏，不算真实前台输入验收。

复跑（必须新输出目录）：

```sh
python3 scripts/qa/macos-attachment-preserve-ui.py build/macos-adaptation/attachment-preserve-new-run \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

这不是应用进程重启、原生文件面板、物理键盘、真实 Codex 或最终同源整包验收。
文件自身删除/替换/版本恢复及更大混合资料范围仍依各票继续核对；凭据管理、目录标签、
真实输入/焦点、规模压力等未因本例通过而完成。#48 六条复合条件保持未勾选。

### #48 整理请求、自动应用与结果持久化的 Mac 原生验收

QA 源码 `d161cb3` 新增 `macos_organization_native_test.dart` 和
`scripts/qa/macos-organization-ui.py`；未修改产品代码。桌面基线 `c1c54c0`，
独立父进程使用已核对摘要的 `cccc37e` ARM64 AOT CLI。
[固定证据](evidence/macos-organization-ui/verification.json)保存两轮原始日志、执行源码及最终九张原生渲染图。

实际 Mac Flutter/SQLCipher 中，由 CLI 提出三个候选信息的整理请求，原生 tester
取消第三项并选择 15 分钟，然后一次批准。CLI 只取得两项元数据，不含字段身份/值；
另一个私密会话被拒绝，普通内容请求仍待审批，越界信息与字段值注入分别被拒绝。
单独受控批准第一字段后，它可读取，第二字段仍拒绝；整理没有扩大普通内容授权。

CLI 提交后自动调整两项分类/标签，信息版本增加、字段身份与值保持；同名目录/标签只创建一份，
未选第三项不变，期限不延长。结果页只读、无需二次确认。完成后元数据能力结束，重复提交不再应用。
第二任务获批后受控 Owner 修改其中一项；CLI 整批提交因版本冲突拒绝，另一项没有部分更新，
新目录/标签没有部分创建，UI 明确“资料已变化，整批未应用”。
随后实际 UI 撤销/拒绝两个任务，独立 CLI 后续读取/提交均被相应状态拒绝，普通已批准字段仍可读取。
空变化提交明确“无改动完成”，原信息版本保持。

第六个任务批准但未提交；同一原生进程关闭服务/加密库再重开，六个任务及既有结果保持，
活动任务失效，普通内容授权历史也失效，资料身份/版本/值保持。
重开后的实际界面显示已取消任务及原整理明细；新 CLI 会话不能借旧任务或内容请求继续操作，
公开目录仅包含三项元数据、不含私密字段值或整理分类名称。此处不等于应用进程重启。

首轮在收件箱刷新前查找新请求，ensureVisible 抛出 No element，原始源码/失败日志保留，
专属合成根仍保留在本机，不提交数据库或密钥。修正为等待实际条目出现（最多五秒），
没有重挂页面或更改产品刷新。最终 run-2 complete=true，12 阶段、49 次独立 CLI 命令状态断言、
六个整理任务、九张图；Flutter 和三份 CLI 正常退出 0，成功专属根已移除。
首轮 Flutter 退出码未由驱动捕获，不补造数值；失败事实由实际日志证明。

初次分析的未使用辅助函数告警已移除，最终严格分析通过；既有整理任务/目录标签控件五项通过。
普通 main.dart Debug 已恢复，deep/strict 验签退出 0。主 agent 目测缩小范围、完成、冲突、
无改动及两张重开页面，1440×1000 紫棠主题未发现阻断性布局问题。
两轮均有 foreground open returned 1 提示，不作为可见前台操作成功的证据。

复跑（输出目录必须不存在）：

```sh
python3 scripts/qa/macos-organization-ui.py build/macos-adaptation/organization-new-run \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

信息/目录/标签准备、临时密钥、单独内容审批及并发 Owner 修改为夹具。
本轮不覆盖真实输入、Keychain、系统面板、真实 Codex、睡眠/到期、规模压力或最终同源整包。
附件与普通提案/编辑联合保留、凭据管理以及其余实机门槛仍待；#48 六条复合验收保持未完成。

### #48 批量提案、修改冲突与处理记录的 Mac 原生验收

QA 源码 `95e9fcb` 新增 `macos_proposals_native_test.dart` 与
`scripts/qa/macos-proposals-ui.py`；产品仍为 `bcd66c2` 基线，Windows 测试与分支未改。
[固定证据](evidence/macos-proposals-ui/verification.json)保留实际原生 Debug Flutter/SQLCipher、
独立父进程 ARM64 AOT CLI 的日志、源码快照和截图。CLI 使用核对过摘要的 `cccc37e` 交付。

CLI 先提交空批次并得到 invalid_request，再提交两条合成资料，第二条引用失效目录/标签。
实际原生界面调整第一条名称和值；确认失败后显示草稿保留，公开目录仍为零条，无部分入库。
返回审核保留修改值；修正第二条分类/标签后一次确认入库两条，多行文本类型保持。
受控 Owner 重复确认不新增资料；公开目录只含元数据、不含字段值。

模拟主人随后修改第一条值，原批次“按身份查看当前内容”及跳转信息库均显示新值。
另一个录入提案被界面拒绝后正文不再显示；删除提案确认后第一条进入回收流程，
再次查看当前内容明确不存在。第二条修改提案提交后主人并发改值，界面提示基于版本 1、
当前版本 2 并禁用确认；拒绝保留主人的值。CLI 基于版本 2 重新提交后，界面确认成功到版本 3，
字段身份保持；拿提案编号请求读取仍 unauthorized，确认修改不等于内容授权。

同一原生进程关闭服务/加密库后重开：剩余信息/字段/目录身份和版本 3 值保持，
原批次创建身份以及已确认/拒绝/删除五条处理记录保留，已结束录入草稿为空。
实际切换“已处理”显示五条条目；打开原批次当前内容，第一条提示已不存在、第二条显示最新值。
新 CLI 会话不能查询旧提案状态，公开目录仅剩第二条且不含正文。这里不是应用进程重启。

run-1 为初始十阶段流程；run-2 增加成功修改、无隐式读取许可、重开后的已处理列表及当前内容检查。
最终 run-2：complete=true、11 阶段、22 次命令状态断言、3 次目录断言、12 张原生渲染图，
Flutter 和两份 CLI 正常退出 0，带 nonce 的专属合成根已移除。两轮覆盖不同，不作重复稳定性或总数累加。
主 agent 目测关键批次、错误、冲突、已处理与当前内容截图，1440×1000/紫棠主题无阻断性布局问题；
没有扩大成全部主题/键盘/系统面板验收。

严格分析通过；原有录入/修改控件 2 项、批次存储失败保留草稿重试与确认时版本竞争 2 项通过。
后两项通过公开 repository seam 注入，不是本次原生 SQLCipher 写锁故障证明。
普通 `main.dart` Debug 入口恢复并 deep/strict 验签通过；原始资料逐字节核对入库摘要。

复跑（输出目录必须不存在）：

```sh
python3 scripts/qa/macos-proposals-ui.py build/macos-adaptation/proposals-new-run \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

Computer Use 仍报告锁屏；临时密钥、目录创建、并发 Owner 修改与重复确认为夹具；
原生 tester 输入不冒充物理操作或 Keychain。未覆盖批次包含既有附件的修改/保留、整理请求与结果、
大量数据、真实输入以及最终同源整包。#48 六条复合验收继续不勾选。

### #48 模板、编辑、回收与版本恢复的 Mac 原生验收

源码 `5ca246b` 新增 Mac 独立入口 `macos_library_native_test.dart` 和
`scripts/qa/macos-library-ui.py`，没有修改 Windows 测试或产品代码。
[固定证据](evidence/macos-library-ui/verification.json)保留三轮原始日志、源码快照与截图。
桌面为 `604f410` 产品基线上的原生 Debug Flutter/SQLCipher，独立父进程使用
`cccc37e` 交付中的 ARM64 AOT CLI，先核对其清单摘要，再通过真实 HTTP/JSON-lines 交互。

真实原生界面由 tester 操作完成：创建双字段模板（文本/多行文本）、模板建项、公开说明与字段值编辑、
目录与标签选择、删除确认取消后再确认、回收站恢复、历史版本恢复，以及修改模板。
目录/标签的创建、主人审批和临时数据库密钥为夹具；不把它们写成 UI CRUD 或 Keychain 验收。

独立 CLI 的 18 次读取核对编辑后的新值、删除旧字段立即拒绝、保留字段继续可读、
恢复字段新身份与重新审批、版本恢复到原值且旧字段身份不复活。
取消确认不写库；模板修改到版本 2 不改变已有资料字段名称/内容或授权。
版本恢复得到信息版本 6，目录/标签也恢复到原版本的 Services/空标签。
关闭弹窗后直接检查并截图当前详情的两字段值，不能只凭 Owner 模型判断页面已经刷新。

关闭 service/repository 后在同一原生进程重开真实加密库：信息和新字段身份、版本、模板、
目录标签、回收恢复映射保持，两条历史授权均已失效；新 CLI 会话不能借旧请求读取。
这是库/服务重开，不是重新启动应用进程（应用重启另见 #46）。

run-1 为初始流程；run-2 增加取消/模板隔离/失效历史断言；run-3 再增加关闭弹窗后的详情断言。
三轮各 complete=true、九阶段、18 次读取，Flutter 和两份 CLI 均退出 0；
不是三个相同最终用例的稳定性重复，也不把重叠测试相加。最终保留 11 张原生渲染图，
主 agent 目测核对关键页面与新增详情图，1440×1000/紫棠主题未发现阻断性显示问题。
模板/回收/资料库既有控件回归 4 项通过，最终严格分析通过；普通 `main.dart` Debug 入口已恢复，
deep/strict 签名通过。成功专属合成库由带 nonce 校验的驱动清理；未提交数据库、密钥或私密关联。

复跑（输出目录必须是新的）：

```sh
python3 scripts/qa/macos-library-ui.py build/macos-adaptation/library-new-run \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

Computer Use 本轮仍报告锁屏。测试控制点击/输入不等于真实键盘/中文输入法或系统面板。
本场景只有一条信息/两字段，不代表压力、提案/整理/凭据/附件或所有主题已验；
CLI 是较早交付版本，最终同源整包继续由 #50 收口。#48 六条整体验收保持未完成。

### #48 原生历史组件与独立 CLI 联合验证

源码 `466a18e` 新增 `macos_removed_scope_native_test.dart` 与
`scripts/qa/macos-scope-ui.py`。桌面测试使用当前源码和真实 SQLCipher；
父进程使用已核对摘要的 `cccc37e` 随包 ARM64 CLI，通过真实 HTTP/JSON-lines
会话申请与读取。主人创建、审批、删除和恢复由测试控制，使用隔离临时密钥，
不读写用户资料库或 Keychain，不代表真实 Codex 聊天。

最终 run-5/6/7 连续三轮通过。每轮九个阶段、19 次独立读取断言：
原批准两字段可读；删除一个字段后原字段拒绝而另一字段仍可读；
同名恢复生成新身份，旧许可仍拒绝，重新申请批准后才可读；
整项删除后两份许可均拒绝；真实导出、恢复到独立加密库以及关闭/重新打开
该库后，旧许可不能恢复。界面同时保留原字段名称和移除标记，
处理后审批显示旧范围不可读取；历史有效筛选保留部分有效记录，
排除全部移除和恢复归档的记录，已结束筛选与之相反。
三轮 Flutter 均退出 0，每轮三个独立 CLI 均退出 0，成功测试目录已清理。

每轮生成 22 张实际 macOS Flutter 渲染图，使用生产字体、真实阴影；
run-5 的完整 22 张入 Git，另两轮保留摘要。包含四主题部分移除
1440×900/100%、1280×800/200%，四主题归档 1280×800/200%，
200% 的范围滚动图，以及全部移除和重开的 100% 图。滚动后字段名可命中，
底部操作/事实说明仍可见。视口与字号是测试设定，组件挂载于 Scaffold，
没有全局 72px 导航，因此不代替物理窗口、系统缩放或完整软件验收。
严格分析通过；测试后重新构建普通 `lib/main.dart` Debug 入口并通过严格签名核对，
未更改既有 Release 交付包。

独立视觉评审逐张检查 22 图，没有发现阻断性重叠、永久裁切或明显状态误导；
保留 Round05 结构、颜色及业务说明。仍有一项轻微问题：
200% 归档记录左列的“11 次访问”末字单独换行，完整可读；
该问题已由下述 `97b3f2c` 修正。未进行同尺寸 HTML 对照，不声明原型还原完成。
评审结论和范围见 [视觉记录](evidence/macos-removed-scope-ui/visual-review.json)。

保留前三轮失败：run-1 使用 stdout 导致父驱动未收到根目录；
run-2 把合并显示的字段名误断言为独立文本；
run-3 业务阶段完成，但默认测试语义句柄在回调后释放，与原生句柄检查时点冲突。
改用 debugPrint、准确字段行断言及项目既有 `semanticsEnabled: false`
原生请求方式后，run-4 通过；补滚动/筛选后的最终三轮再通过。
没有放宽产品权限断言或关闭框架泄漏检查。

原始 78 份日志、结果、源快照和截图及全部摘要见证据索引。
Computer Use 本轮仍报告锁屏，普通窗口操作、中文输入、键盘焦点、
系统面板及 #48 其余资料管理流程继续保留未完成，六条整体验收不勾选。

重跑命令（输出目录须不存在）：

```bash
python3 scripts/qa/macos-scope-ui.py build/macos-adaptation/issue48-next \
  --delivery 'build/macos-adaptation/issue50-package-4/verify/中文 空格 路径/AgentInfoManage'
```

### #48 访问次数断行与完整应用历史分页

源码 `97b3f2c`。历史列表的访问/读取/文件交付数量及单位作为完整词组换行，
保留原有字体、列宽、状态及业务文案；极端宽词组仍可在列内换行，
不会固定宽度造成横向溢出。`WidgetSpan` 承担外层字号缩放，
子文本不重复放大。首轮错误的双重缩放被真实原生行盒断言捕获，
原失败记录保留；修正后四主题 200% 的“11 次访问”均只有一个文本行盒。

`issue48-history-layout-3/4/5` 连续三轮通过，原九阶段权限/备份流程保持；
每轮 19 次独立 AOT 读取断言、Flutter 和三个 CLI 均退出 0，
成功合成目录已删除。新增完整 `InformationApp` 入口，在
1440×900/100% 与 1280×800/200% 下实际点击全局历史导航：
19 条记录分三页，逐页进入、最后一页下一页按钮禁用；
搜索“分页合成08”只剩一条/一页；含 24 字段的长申请滚动可达，
清除搜索恢复 19 条/第一页。使用真实 SQLCipher，但数据创建及审批受控，
这些测试点击不冒充物理键盘或鼠标。

每轮 26 张渲染图，run-3 原图入 Git；原 22 图依旧是历史组件，
新增 4 图包含全局导航、长申请首屏和范围滚动。独立复核确认四主题
访问次数换行修正，字号与相邻元数据一致；完整应用 200% 导航分两行，
五个模块、四主题、固定底部操作均可见，字段 1–24 可滚动看到。
没有新增阻断性视觉问题。截图没有单独取长标题与范围之间的全部中间摘要，
也没有同尺寸 HTML 对照，不宣告所有窗口状态或像素级还原通过。

历史、移除字段、凭据历史和附件审批历史四个文件共 10 项控件回归通过，
严格分析通过；测试后恢复普通 `lib/main.dart` Debug 构建并严格验签。
仅共享界面排版有生产改动，未改变权限、存储或 Agent 协议；
独立 CLI 仍来自 `cccc37e` 包，本轮源码尚未重打最终 Release 包，
Windows 实机回归仍待。Computer Use 再次确认 Mac 锁屏，
原生面板、真实输入、其余资料管理和大规模数据压力仍留在 #48，
六条整体验收不勾选。失败、最终三轮、源码摘要和视觉复核见
[证据索引](evidence/macos-history-layout/verification.json)。

### #49 初期工作区准备与独立 stdin 接口（历史检查点）

以下是收到 hook 信任授权前的准备记录。后续用户已明确允许仅限该合成项目，
实际信任与真实模型工具、附件和生命周期结果见
[最新接入验收](macos-codex-real-client.md)；不能继续用本段的 `not_run`
描述最新进度。

源码 `2d4378b`。实际输入为已核对的 `cccc37e` Mac ARM64 交付包，
用随包 SDK-free `info-prepare-codex` 在中文、空格、单引号及 shell 特殊字符
目录生成 CLI/hook/worker/Skill/引用。旧项目生成器确实因寻找
`info-codex.exe` 失败，未留下目标；修复后识别 manifest 平台，
核对两种 shell 的准确命令、事件、匹配器与超时，不复制多余执行设置。
实际三个程序均为 ARM64 且签名校验通过。重复生成被拒绝，
原项目所有文件摘要保持不变。另有 5 项配置测试通过，包含 6 类 hook
改写拒绝；Windows 仅验证合成布局兼容，不算 Windows 实机回归。

可审查项目位于当前仓库
`build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目`。
保留其同级固定路径 bundle，不移动或单独删除；项目没有注册到客户端，
没有写入现有用户配置、创建聊天或授予 hook 信任。第一条准备条件已具备，
其余真实客户端条件仍待。验收清单扩充为 13 项，全为 `not_run`，
包括独立 stdin、compact/fork/clear、非根结束、凭据复用和普通附件实际消费。

本机 `codex-cli 0.158.0` 生成的 schema 明确支持 `command/exec` 与
`command/exec/write`。通过实际独立 app-server、只读禁网命令沙盒发送
105 字节随机合成输入，接收摘要一致；目标与 app-server 的 argv 及本次
响应/标准错误不包含该输入，双方退出码 0。没有调用模型、创建 thread、
安装或信任 hook，**不能替代模型工具通道或真实会话事件**。
首次使用 `/usr/bin/python3` 包装器时，虽收到正确摘要，但只读沙盒拒绝
其 Xcode 缓存写入，因 stderr 非空而失败；改用已解析的 Python 实体路径
后通过，未放宽沙盒，失败与成功记录均保留。

[官方 hook 文档](https://learn.chatgpt.com/docs/hooks)于 2026-10-21 核对：
项目配置可被发现，但非托管 hook 需用户审查并信任准确的当前定义；
准备材料不等于已信任。本会话已向用户请求仅限该合成测试项目的明确授权，
尚未收到答复，未使用信任绕过参数。

## 当前实现

- Mac 使用 Darwin FFI 核对 PID/启动时间、POSIX 会话与进程组。worker 先等持久登记确认，目标暂停装载后再核对实际身份；kqueue 保留短进程及信号退出结果，避免与 Dart 的 SIGCHLD 回收竞争。
- worker 随 Runner 构建编译、单独签名，并继承应用沙盒。当前构建入口显式将 Runner、worker 和 CLI 固定为 ARM64；最低构建目标为 macOS 14.0，仅在当前 macOS 27.0.1 实测。Intel、完整通用二进制发行、Developer ID、公证与其他设备安装不在本轮已验证范围。
- 文件材料的目录为0700，文件为0600。核对本用户、ACL、硬链接数、设备/inode/创建身份；不跟随链接，不递归清理，不删除未知子项。Windows 原生驱动保留。
- Mac 启用可复用凭据执行与普通附件交付；焦点填充仍只在 Windows 宣告。SSH 接收器固定到本机独立验证的 Apple `OpenSSH_10.3p1`，Windows 原版本限制保留。其他 SSH 版本拒绝，升级后须重新验收。
- Mac版本探测为独立子进程，隔离用户认证环境，最多等待30秒且输出上限64KiB，超时/超限回收探测进程。首次解包AWS工具时曾超过旧5秒限制；6秒延迟与无限输出回归已通过。Windows仍保持原5秒路径。
- 系统面板支持普通附件、known_hosts 和另存；另存通过 native 创建同卷 replacement 目录，再由Core完成完整性校验及不覆盖发布，避免要求对用户选择文件的任意同级路径写入。启用应用沙盒的本机网络客户端能力以访问 loopback 接收服务，未移除沙盒。

进程组与文件释放的含义见 [ADR0013](../adr/0013-macos-runtime-lifetime.md)。本轮不迁移生产信息库，不接入真实服务或凭据，不安装 Codex hook。

## 已完成的独立验证

原始日志保存在本机忽略目录 `build/macos-adaptation/`，不将测试密钥、数据库和私密会话材料提交。

- `core-final-02.log`：核心270项通过、6项跳过；`owner-export.log`、`tool-probe-02.log` 严格分析通过。另存原文、空文件、替换目录、完整性/IO/源事务失败、目标竞争不覆盖、慢版本探测及超量输出回收独立通过。
- `storage-full.log`：真实SQLCipher存储148项通过、12项跳过，包含文件占用后路径释放、已打开描述符仍可读取、加密重开与交付登记。
- `ssh-native-02.log`：系统 `/usr/bin/ssh` 经真实 worker，协议1与2均通过；正确私钥/确认主机成功，错误私钥/未知主机/错误主机密钥拒绝，字面远程参数、重复调用和清理通过。接收端为仅监听127.0.0.1的合成 Paramiko 服务，无真实账号。
- `gh-aws-native-final.log`：本目录内的真实GH 2.102.0和AWS CLI 2.38.1共4项通过。GH仅向GitHub提供假Token，收到401且无本机账号回退；AWS向loopback接收端完成SigV4签名核验、合成读写、错误秘密拒绝、独立操作及文件清理。
- `worker-lifetime-02.log`：登记前EOF不运行目标、第二道门保持目标暂停、任务等待同组后代、worker强制结束后仍观察到后代存活，3项通过。
- `final-check.log` 的CLI部分67项通过、38项跳过，严格分析通过。`cli-full.log` 首次与Release编译并行的3项时限失败，在单独重跑及本次完整回归中均未重现。
- `desktop-final.log`：严格分析通过，界面测试154项通过、4项跳过；Windows焦点填充原生成功路径仅在Windows执行，Mac明确验证其能力不宣告。
- 四包自动化合计639项通过、60项跳过；另有真实接收器6项及下述原生窗口自动验收1项通过。默认跳过项不视为通过，真实接收器通过的是明确给定可执行文件及合成接收服务的另一次运行。
- `build-release-final-04.log`：最终Release构建成功，75.4 MB，`codesign --verify --deep --strict`通过；签名仍为本机开发用途，不能当作发行包。
- `native-sandbox-final.log`、交互验收后的 `native-sandbox-after-ui.log`：真实签名Debug窗口、独立加密库、随包worker与系统SSH通过。覆盖编辑器保存/另存、实际审批组件、0与1两个退出码、防重放、独立进程组、清理、原文领取/释放、历史执行回执、凭据与字段分别撤销；此模式使用测试文件路径替代系统面板，不能算原生面板通过。

## 原生界面验收（2026-10-20 完成）

使用 `macos_workflows_manual.dart` 的普通 `WidgetsFlutterBinding` 启动真实应用，通过 Computer Use 操作；仍使用隔离加密库、合成密钥和仅监听 loopback 的测试服务。`native-live-01.log` 的检查结果为 `PASS`，runner 正常退出0。验收记录及文件摘要保存在忽略目录 `build/macos-adaptation/manual-ui-01/acceptance.json`。

- 实际点击批准及二次确认，界面正确列出凭据15分钟与普通附件8小时两项独立许可。
- 两次真实SSH操作分别返回0与1，清理完成；逐次记录、冻结计划及完整执行回执均在实际窗口中核对。重复操作不重新启动。
- 原文领取内容一致，重复领取保持同一交付编号；显式释放后路径消失，历史显示“已释放”。
- 在界面中撤销凭据使用许可，新执行返回 `grant_revoked`，附件许可仍有效且可再次领取；再独立撤销附件许可，新领取返回 `not_authorized`，受管副本回收，界面显示“已失效”。
- 同一普通应用窗口中实测 `NSOpenPanel` 取消及重新选择。取消保留原附件版本；选择项目内、应用容器外的 `synthetic-简历.pdf`，编辑器显示待保存，保存后产生版本2。
- 实测 `NSSavePanel` 取消及容器外另存。取消保留版本2；另存到 `manual-ui-01/owner-live-01.pdf`，界面显示成功。导出与外部原件逐字节相同，均为7字节，SHA256为 `d9612a8c5bde658ae302a69fb29555c064c1a3af326725fca2eaba4bb7290038`。保留了沙盒及同卷原生暂存方案。
- 新验收入口和集成测试严格分析通过；界面验收后再次运行原生自动工作流，1项通过。

此前 `native-interactive-02.log` 在widget测试预先开启框架语义、原生观察器随后连接的路径触发Flutter引擎辅助功能桥崩溃；测试改为由原生请求语义。`native-interactive-03.log` 中真实选择和另存已成功，但集成测试宿主无法完成后续Computer Use点击，最终超时，保留为失败记录。后续交互验收改用上述普通应用入口，完整操作期间未再出现崩溃；这不表示修改或修复了Flutter引擎本身。

真实通知权限及投递、备份系统面板、Codex生命周期仍需各自验收。GH/AWS的接收器测试来自独立CLI，不把它当成这两种工具的全部Mac桌面路径访问已经验收。

## 重跑原生工作流

```bash
# 独立加密库、真实原生窗口与worker；文件选择器使用测试路径
.tools/qa-python/bin/python scripts/qa/macos-workflows.py --automatic
# 普通应用：实际审批/历史与系统面板，需要桌面已解锁
.tools/qa-python/bin/python scripts/qa/macos-workflows.py
```

runner自动生成一次性SSH密钥、loopback服务和私有测试参数，结束时只停止自己创建的接收服务。默认交互模式预置合成附件，按 `MAC_QA_PHASE` 批准请求、查看执行回执、分别撤销凭据与字段许可。`MAC_QA_RESULT=PASS` 只表示这些程序化断言通过；系统面板和目测结果需另行记录。随后可在信息库实际更换合成附件、取消和完成另存到本项目 `build/macos-adaptation/` 的新文件，并核对导出字节。检查完毕后，在 `MAC_QA_ROOT` 目录创建空的 `finish-qa`，关闭本次隔离库并退出。材料都留在项目忽略目录或本应用隔离的测试临时目录，未读写生产资料库。

## 本地接收器工具

- GH位于`.tools/gh-2.102.0/gh_2.102.0_macOS_arm64/bin/gh`，来源为[官方2.102.0发布](https://github.com/cli/cli/releases/tag/v2.102.0)，下载SHA256与官方Release API中的digest一致。
- AWS位于`.tools/aws-cli-2.38.1-package/aws-cli.pkg/Payload/aws-cli/aws`，从[官方固定版本包](https://awscli.amazonaws.com/AWSCLIV2-2.38.1.pkg)解包，`pkgutil --check-signature`核对AMZN Mobile LLC及Apple公证；未运行系统安装器或修改全局PATH。官方版本选择方式见[AWS说明](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-version.html)。

## 重跑接收服务

项目局部Python虚拟环境可安装 `paramiko==5.1.0`，不修改系统Python。启动时使用不存在的目录：

```bash
.tools/qa-python/bin/python scripts/qa/macos-ssh-fixture.py build/macos-adaptation/ssh-next
```

服务输出本次端口；将目录、端口、`/usr/bin/ssh` 分别传给 `D7_SSH_FIXTURE`、`D7_SSH_PORT`、`D7_SSH_EXE`，再用 `scripts/dev-macos.sh dart test test/ssh_receiver_native_test.dart` 在 `packages/info_cli` 重跑。停止服务只结束该测试服务；测试目录保留为本机诊断资料。
