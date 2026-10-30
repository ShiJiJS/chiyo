# 知予 Mac M04：固定候选联合验收记录

对应 #73，前置业务范围为 #70–#72。本记录区分候选打包、完整界面接缝、原生系统以及真实AI宿主，不把分项证据拼成已经日用交付的结论。

## 2026-10-30：正式换包前的载荷核对和程序归档

新增 `scripts/prepare-macos-upgrade.py`，实际核对固定旧安装 package23（7972项）与
1443d358候选（7983项），包含文件字节/模式、内部链接、bundle身份及deep/strict签名。
旧安装完整归档至私有目录，逐项验证7972个成员并复查原目录/候选未变；只增加一个
压缩归档，不增加展开App/dSYM。原资料库及Keychain未打开、原预览未操作。

[准备回执](evidence/zhiyu-round09/m04-upgrade-preparation.json)与
[本机升级步骤](macos-local-installation.md)已更新。当前固定安装仍是旧版。
程序归档不等于资料备份；按现有升级约定，正式替换前等待主人从旧版导出当前资料的
最新备份并确认另存恢复密钥。当前不使用computer use，因此原生备份面板需本人操作。
取得备份后先验证恢复，再确认原应用退出，整体替换、普通启动及必要的系统允许；
不能把当前准备状态算作Release或钥匙串升级已完成。#73保持OPEN。

## 2026-10-30：实际旧版导出与新界面适配层兼容

新增 `check-owner-legacy-export.py` / `check_owner_legacy_export.dart`，限定读取既有 package23 普通 App 导出的合成备份（格式9）和另存恢复文件，原件前后摘要一致。未打开原资料库、调用系统钥匙串或替换已安装 App。旧安装仍为 `7b19d34`，当前产品候选仍为 `1443d358`；当前改动只有检查工具与记录。

```sh
python3 scripts/qa/check-owner-legacy-export.py build/macos-adaptation/m04-legacy-export-3
```

三个独立 Flutter 测试进程通过：恢复到空 SQLCipher 库 → 从生产 OwnerWorkspaceSource 编辑一个旧文字字段 → 独立重开、核对持久编辑回执，并重新导出格式12、恢复到另一空库。覆盖2条资料、5份凭据/7个版本、3份附件/3073字节及原授权/访问/执行/交付历史；新增修订后为4条修订。恢复后的有效能力为空。附件支持仍是底层保留与恢复证据，不代表新版附件操作界面已接入。

直接对照已认证原备份的资料/字段行与新版详情映射，检查原名称、字段身份、类型和值；独立参考恢复在内存中比较资料、凭据材料、历史及逐块附件字节。编辑后保留其他字段及附件引用，不输出正文、凭据或恢复密钥。服务编辑时钟固定到同一时刻，独立参考可准确核对修订时间；比较报告中的原始计数来自格式9预览，实际修订数单列，格式12往返计数为编辑后的结果。

首次运行发现检查器把文件字段当文本访问而失败，修正检查器后通过；不是产品数据丢失。最终静态分析通过。临时恢复库、再导出文件及合成密钥均已清理，无新增 App/dSYM，未操作已有预览或 Windows。

[完整证据](evidence/zhiyu-round09/m04-legacy-export.json)。本项证明真实旧导出兼容及新界面适配层编辑/重开，不证明正常 Release 原地升级、Keychain 授权、原生输入或备份界面接入。正式换包前仍需最新资料保护；旧备份不是今天原库的完整快照。#70/#73 保持 OPEN。

## 2026-10-30：完整 Flutter 界面与包内 CLI

新增 `scripts/qa/check-owner-ui.py` / `apps/desktop/tool/check_owner_ui.dart`，在两个独立Owner测试进程运行正式DesktopLauncher/OwnerWorkspaceHost/WorkspaceApp。SQLCipher、HTTP服务和包内独立CLI为真实实现；OS平台使用NativeDesktopFixture，界面输入使用WidgetTester。没有产品代码变更或另加演示模式。

候选为 `b0578cf6ed9890a2c689ec7ee65af5f6ba869bb4` 的 `AgentInfoManage`，UI/核心/存储/CLI实现及pubspec依赖文件已核对与该候选源码一致，CLI摘要与清单一致。Owner界面是Flutter测试进程运行同源实现，不是直接启动已打包的Release App；因此不能据此勾选同候选原生系统验收。

两阶段共12个具名检查通过：

- 完整界面从空加密库录入服务器资料，独立CLI查询公开目录而读不到正文；AI申请出现在真实收件箱。
- 主人在界面取消一个字段并部分批准；CLI只读获批字段，未选字段和另一个聊天被拒绝。
- 主人从信息库编辑已授权字段，实际CLI读取修正值；稳定字段身份和固定期限不变。
- 从审批打开准确历史，新读取刷新实际访问次数（包含拒绝的访问结果，不把批准当读取）。打开批准时快照仍显示原值，而不是当前修正值。
- 从历史页撤销后缓存读取能力被拒绝，返回原审批保持同一请求及撤销状态；另一次申请通过界面拒绝，CLI看到denied。
- 留下一个有效授权后走正式runtime关闭；另一个Owner进程重开同库，通过列表实际打开资料详情，显示修正后的内容。历史对应原请求并显示会话结束，新会话不能领回旧授权。

最终命令：

```sh
python3 scripts/qa/check-owner-ui.py \
  --package build/macos-adaptation/m03-candidate-b0578cf6/AgentInfoManage \
  --report build/macos-adaptation/m04-ui-interop-5.json
```

结果见 [持久证据](evidence/zhiyu-round09/m04-owner-ui-interop.json)；本机日志为 `build/macos-adaptation/m04-ui-interop-5.log`。两阶段分别9项、3项，进程PID不同；测试库、固定测试密钥与临时资料已删除。桌面包 `flutter analyze --no-pub --fatal-infos` 通过，Python AST和diff检查通过。

最初驱动仅等待真实I/O，导致widget zone中的异步审计未推进；随后普通pumpAndSettle也会在等待历史读取时耗尽虚拟时间。已改成同时推进真实I/O和界面帧，并设定有界等待；没有修改产品审批或历史代码来迁就检查。首次分析误在仓库根目录执行，包含SDK及过程文件，不作有效分析结论；最终分析明确在apps/desktop下执行并通过。

本轮没有使用个人资料/Keychain、computer use或Windows CI，没有新建App/dSYM，没有修改已有候选/预览或全局hooks。#73仍OPEN；下一步是原生窗口及独立App重开、真实AI宿主事件/聊天流程和必要系统配合。完整备份UI等后续范围仍未接入。

## 2026-10-30：原生完整界面与独立进程重开

将已有完整界面场景复用于独立沙盒 Debug App：`owner_workflow_native_test.dart` 使用真实 Cocoa/Flutter、系统字体、SQLCipher、正式 bootstrap/runtime 与实际 loopback HTTP。客户端为进程内 CLI AgentClient；包内独立 CLI 另由 widget 回归覆盖，两类证据不混称同一 Release App 或真实 AI 宿主。

```sh
python3 scripts/qa/check-owner-native.py build/macos-adaptation/m04-native-workflow-2 --workflow
```

同一 kernel 的两个独立原生进程分别通过9项和3项检查：界面保存、申请接收、部分批准、越界/跨聊天拒绝、编辑后读取最新值、准确历史及批准时快照、撤销、拒绝、关闭服务，以及独立重开显示已保存修正值且不恢复旧授权。截图为1280×800，已逐张查看；中文及布局正常。发现申请范围与关联资料使用通用“资料字段”标签，缺乏资料名称，作为后续产品修正项，不能因此宣称全部界面验收完成。

驱动仍报告 `Failed to foreground app`；输入由 Flutter 集成框架产生。此结果不证明物理输入、真实 AI 宿主、个人 Keychain 或交付 Release App 通过。没有使用 computer use、Windows CI 或个人资料。原生库已删除，测试 App/dSYM/Xcode产物已清理，原预览摘要保持一致。

第一次运行未注册实际场景，驱动输出null；检查器拒绝把空测试算通过。已将异步准备放入同步注册的测试内部，第二次实际执行通过。最终共享场景重新运行包内独立CLI/widget两进程回归通过12项，desktop静态分析无问题，Python AST检查通过。

[原生结果、截图和回归证据](evidence/zhiyu-round09/m04-native-workflow/result.json)保留准确范围与测试源码摘要。#73保持OPEN；接下来修正上述资料辨识问题，然后更新交付候选并继续真实宿主/系统验收。

## 2026-10-30：修正审批资料名称与多资料分组

原生截图发现真实来源将所有字段的 section 写成“资料字段”，界面又把 section 当关联资料名称使用，导致主人看不到实际资料名称；仅以 section 分组也会混合不同资料。已修正为真实资料名称，并按资料身份与 section 分组；展开状态同样按该组合隔离。关联资料按钮直接使用 recordName，不再拆分显示标题，含“ · ”的名称不会截断。

新增真实 Owner 服务控件回归覆盖不同名/同名两份资料、相同字段名称：各自独立分组、完整名称和准确跳转；取消第二份资料字段后批准，仅第一份可读，第二份拒绝，正文不出现在审批页。三个审批相关测试文件共24项通过，desktop静态分析通过。

修正后再次执行 `check-owner-native.py build/macos-adaptation/m04-native-record-labels --workflow`：同一沙盒Debug App的两个独立进程共12个具名检查通过，原生截图已确认申请范围和关联资料显示“界面合成服务器”。[结果](evidence/zhiyu-round09/m04-native-workflow/record-labels-result.json)和[修正截图](evidence/zhiyu-round09/m04-native-workflow/record-labels-corrected.png)保留源码摘要。窗口置前仍未成功，不计物理输入或真实AI宿主验收。

本轮测试库及App/dSYM/Xcode临时产物均已清理，既有预览保持。已保存的Release候选b0578cf6不含此次修正，需要在后续交付时更新；没有将源码修正冒充用户安装完成。#72/#73继续OPEN。

## 2026-10-30：纳入资料辨识修正的 Release 候选

源码 `1443d358e6069c5ea923c4e3f3386cfe97fc8fd3` 已形成 Mac ARM64 Release 整包 `0.4.1+13-mac-dev.1443d358e606`，位于 `build/macos-adaptation/m04-candidate-1443d358/AgentInfoManage`。含修正后的审批名称/分组、真实保存/申请/审批/历史及同源 CLI。当前为本机 ad-hoc 开发候选、未公证；未启动个人库或替换旧预览。

在独立稀疏源码克隆中构建，20阶段通过，包含签名、架构/依赖、解压逐文件核对、实际SQLCipher存储诊断及6项CLI/worker测试。首次准备因SDK/下载目录的符号链接未被目录式exclude匹配而停止于清洁源码检查；补充准确链接路径的本地忽略后继续，没有修改产品源码或放宽打包检查。

使用新包内CLI再次运行完整Flutter界面检查12项及Owner/CLI授权故障检查14项，两个场景都包含独立Owner进程重开。UI实现/依赖与候选源码相同、CLI摘要匹配清单，测试资料均自动删除。它们分别使用平台fixture/合成hook，不代表交付Release原生启动或实际AI聊天通过。前节原生Debug检查也保持其独立范围。

只读检查已获准的 `issue49-codex-preparation-1/独立 Mac Codex 验收项目`：六份准备文件摘要未变，`codex-cli 0.158.0` 的正式app-server返回三项hook均enabled/trusted，默认模型可列出，进程正常退出。未修改hook/信任、未创建聊天、未调用模型；后续真实场景可沿用该项目。旧QA客户端入口使用旧界面，不能直接用旧结果代替Round09联合验收。

[候选完整证据](evidence/zhiyu-round09/m04-package-1443d358.json)记录载荷、检查与边界。保留一个新候选展开目录及ZIP；删除本轮源码克隆、重复解压App、诊断构建树和旧b0578cf6候选的展开目录，旧ZIP及原验证记录仍保留。现有预览52项文件/链接内容核对保持不变，没有新增系统授权请求。

下一步为真实AI宿主与新版界面的联合接入，以及正常Release入口/个人Keychain升级和集中系统配合；不把生成包或只读信任预检等同于这些项目已完成。#70–#73保持OPEN。

## 2026-10-30：真实 Codex 聊天接通新版原生审批控件

新增独立测试入口 `owner_codex_native_test.dart`，复用正式 DesktopLauncher/WorkspaceApp、SQLCipher、本机服务和新版实际表单/审批按钮。测试先在新界面保存合成服务器，再等待外部真实聊天申请；QA命令只选择已登记的合成资料和指定请求，批准、拒绝、撤销由Flutter集成输入操作控件完成。没有产品演示入口或生产管理后门。

```sh
python3 scripts/qa/check-owner-native.py build/macos-adaptation/m04-real-codex-ui-1 \
  --real-codex-project 'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目' \
  --package build/macos-adaptation/m04-candidate-1443d358/AgentInfoManage
```

`codex-cli 0.158.0` 使用正式app-server及其默认模型 `gpt-6-astra`，两个独立根聊天共7个已完成回合。模型13次实际工具调用，经匿名stdin调用当前候选的info-codex；另外2次明确标为negative-protocol-probe。没有子Agent、个人资料、认证文件/聊天记录读取或全局配置更改。

- 真实SessionStart取得会话关联，AI查询目录后申请主机地址和登录用户；申请准确出现在新版原生收件箱。
- 新版控件只批准主机地址；真实模型领取后两次读取成功。未选登录用户的协议负向检查被拒绝。
- 第二个真实聊天使用自己的关联查询第一聊天公开请求ID，被拒绝。
- 新版控件撤销后，原模型查询到revoked，继续读取被拒绝。
- 新版控件拒绝第二条申请，真实模型查询到denied。
- 第三条申请在界面获批后，通过真实thread/archive触发SessionEnd；其授权撤销，原关联领取被拒绝。两个根聊天均归档，两次SessionStart及两次SessionEnd的完成事件有记录，最终有效授权为0。

原生测试6个步骤通过，客户端/驱动正常退出，desktop静态分析、Python AST和diff检查通过。合成库及测试App/dSYM/Xcode产物已清理，原预览未变。六份已批准项目准备文件的摘要前后相同；旧hook/Skill材料保持原路径与定义，新包info-codex消费真实hook提供的关联，**不是整套旧hook材料已升级为新包的结论**。

[派生证据](evidence/zhiyu-round09/m04-real-codex-ui/verification.json)不包含私密证明或字段正文；[原生截图](evidence/zhiyu-round09/m04-real-codex-ui/partial-approval.png)已查看，显示真实聊天公开标识、准确资料名和部分勾选。截图时收件箱已是0待处理，顶部角标仍是1；源码核对为现有1秒轮询的刷新间隔，并非多出一条申请，保留这个瞬时状态记录，没有据此增加演示或伪造同步。

本次原生App为独立沙盒Debug测试入口，产品源码与1443d358候选一致，使用固定合成密钥及框架输入，驱动仍未成功置前。真实AI请求与新版原生控件已联合通过；正常Release入口、个人Keychain升级、物理输入及系统专项仍未完成，#73和相关未验项继续保持开放。
