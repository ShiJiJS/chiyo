# Mac 原生后台填写（#144）

本实现按 [ADR0033](../../../../docs/adr/0033-native-fill-by-control-capability.md) 和[公共合同](../../../../docs/design/native-background-fill-contract.md) 判断当前 AX 控件能力。`NativeBackgroundCompatibility.swift` 仅定义 `macos_ax_password` 和公开标签处理，不含应用、版本、签名、系统构建、语言或 AXIdentifier 允许名单。旧证据仍保留，不能把接口资格当作任意应用的业务成功保证。

Dart 入口 `MacOSNativeBackgroundFillDriver()` 由公共 Launcher/AppHost 注入。可选 channel/timeout 仅为测试 seam；每个 AppHost 拥有自己的 driver。Runner 通过私有 MethodChannel 连接同包签名校验的 XPC helper；所有 AX 读取及 setter 位于非沙盒 helper。公共模型/协商改造由公共分支负责；本平台发现项采用新 kind，旧解析器应明确拒绝，不能伪装成旧 kind。

## 当前能力与身份

`appId` 只是发现选择器。helper 根据实际运行应用取得唯一进程、同用户与启动代际、规范路径、持有文件描述符及文件摘要；签名程序还固定实际运行代码的 CDHash 并复核有效性。无签名本身不排除，仍须可靠取得其余身份事实。不会接受 Agent 指定的 PID、路径、摘要或 profile 作为授权。

字段须有密码语义（AXTextField + AXSecureTextField subrole，或 AXSecureTextField role）、启用且 AXValue 可写。发现只查询能力，不试写、不读取密码。单个明确不支持的字段被排除；仍有可用字段则返回它们。没有密码候选返回空列表，发现密码/网页候选但全部不支持返回 unsupported_target；权限和枚举通信失败单独传播。

AXIdentifier 可选；实际窗口和字段由 helper 持有原 AX 对象，校验进程、窗口成员关系、祖先链和存活状态。缺少开发者标识但窗口/字段标签可区分时可用。公开标签附带已有标识，按 UTF-16 限长；仍歧义则拒绝，不用坐标、排序或随机编号让 Agent 猜框。窗口 opaque ID 缓存弱持有身份，寿命随有界目标引用结束，不能累计已关闭窗口而永久耗尽。

网页排除仅针对目标及通向其窗口的祖先（AXWebArea/WebView、DOM、Chrome 标记等）；已识别网页子树跳过，旁边独立原生密码字段仍可用。AX 元数据不能绝对证明内部框架实现，也不能保证未知应用会把 setter 的值用于业务。

不读取密码控件 AXValue、选中文字或原值。仅在 AXTitleUIElement 确认为 AXStaticText 后读取其标签值。写入前重新核验实际文件、签名、进程代际、原对象、公开描述、密码语义及可写性；失效后不按名称重建引用。

## 生命周期与授权

- 每个原私密聊天的发现项最多保留五分钟、64 项；已绑定申请的保留目标最多 256 项。超限拒绝，不驱逐有效目标。
- 申请前 prepare 成功即保留同一对象，保持至显式 release、原宿主连接结束或失效。保留引用不产生或续期服务器批准。
- prepare 票据最长 30 秒，一次完整 setter 消费一次票据。prepared.close 幂等，只释放该票据；仍有效目标可供原授权的下一独立操作复用。
- driver.dispose 幂等关闭其拥有的全部 resident 连接，使该 driver 的所有发现项、保留目标和票据失效。不同 driver 使用独立私有 owner bookkeeping，互不清理；每条 CLI 短连接结束不触发它。
- Mac MethodChannel 的私有传输信封为 `{owner, request}`；request 是冻结的 format-1 wire。owner token 只隔离生命周期，不作鉴权，也不进入公共快照/服务器。真正的 peer 身份由既有 sealed-package/签名 XPC 连接验证。
- scope 摘要只隔离聊天。写入必须来自已认证 AppHost，先完成只读 preflight，等待其 beforeDispatch 复核持久操作/批准，再由 helper 紧邻 setter 重新检查原目标。

唯一输入变更是 `AXUIElementSetAttributeValue` 的 AXValue 整值设置。没有键盘、剪贴板、点击、窗口激活、AXFocused 或 AXMain 后备。输入为一次完整 UTF-8、非空、最多 4096 个 UTF-16 单元；拒绝无效编码和控制字符，保留空格、非 ASCII、emoji 和组合字符。不分批追加，不自动提交。

## 结果和限制

sent 只表示 setter 返回成功，不代表登录、提交或业务接收。setter 调用后不确定即 unknown，不重放票据；公共持久操作必须阻止 unknown 后自动重试，不能靠新 prepare 绕过原操作状态。普通日志/回执不含密码、长度或原生异常正文。包装层尽力清零临时字节缓冲，Swift/Foundation/传输副本不保证可验证零化。

最后检查后窗口关闭、业务状态改变或撤销仍可能与 setter 竞态；不能保证原子撤止。可见上下文变化可拒绝，但不可见语义变化、同名文件复用等不能由外部 AX 证明；严格业务事务需要应用合作接口。内部焦点改变不会把定向 AXValue 写入 B。

## 验证

```sh
python3 scripts/qa/check-macos-native-background.py
python3 scripts/qa/check-macos-native-background.py --platform
python3 scripts/qa/check-macos-focused-xpc.py --native-status
```

默认运行无系统输入的控制器断言及系统/桥接源码类型检查。`--platform` 启动两个不同 bundle 身份/路径的合成 AppKit 接收器、原生前台 Cover 和 WK 子树。覆盖后台/遮挡/最小化/隐藏、无 AXIdentifier、语言变更、原生与网页混合、部分/全部禁用和只读、普通文本、歧义、重建/关闭/重启、回调期间变化、权限拒绝及文件身份不匹配。权限拒绝通过收紧的测试 seam 验证，不改系统权限。

独立进程观察器持续采样前台、真实焦点对象/PID、鼠标及剪贴板，开始就绪后才允许进入 controller.write，结束标记在 write 返回之后；测试断言采样时间覆盖整个调用区间，nil 焦点不算保持。先校准稳定、焦点切换及前台切换。窗口轮换测试超过256次；wire 测试覆盖新 kind/format1、scope、保留/释放、helper重启及dispose。测试夹具/临时可执行文件与缓存清理，回执和源哈希留在 `build/native-background-macos/`。这些不是正式产品签名/TCC或最终业务验收。

## 历史真实软件证据（不参与运行资格）

首轮 Archive Utility 10.15(178)、OS build 26A434、中文合成 ZIP 已验证实际解压与原文哈希；旧 b857/434/9619 回执保留原归属。Preview PDF 密码场景曾出现 setter 接受、UI 就绪但业务未打开，失败证据保留。二者都不再是支持名单：本次新通用路径的第三方软件、版本、来源和实际结果必须在 #144 另行记录。

真实软件验收使用公开测试口令 `Synthetic-Zip-42!` 和唯一名 `NativeBackgroundProofSigned.zip`，只在本工作树 build 下生成固定文本与加密 ZIP，先由测试操作者在归档工具打开该 ZIP。随后可运行：

```sh
python3 scripts/qa/check-macos-focused-xpc.py --native-archive-target
```

它只接受包含该合成归档名的唯一目标；不读取用户资料，不自动提交。需要独立前台/焦点/鼠标/剪贴板观测时加 `--dispatch-gate`，并按 `tests/DispatchObserver.swift` 驱动合成 Cover 和 gate；gate 超时不会输入。提交仍是独立 UI 步骤，之后必须比较解压内容哈希，不能只看 sent。测试生成物与一次性程序均放 build，不正式安装。

本轮已验证签名的沙盒合成宿主和实际 XPC helper 的真实填写；正式完整 Flutter AppHost/CLI 装配、最终分发签名和升级后的 TCC 归属仍须在统筹冻结候选上验收。原生后台仅需要 helper 辅助功能权限，不需要键盘或录屏权限；本路径从不请求/修改系统权限。

## 普通产品构建和后续完整流程

普通 `lib/main.dart` Release 构建、helper 同包和签名检查：

```sh
./scripts/dev-macos.sh build --target lib/main.dart
python3 scripts/qa/check-macos-native-product.py apps/desktop/build/macos/Build/Products/Release/info_desktop.app --output build/native-package-check.json
```

检查普通入口生成元数据、owner/worker/helper/Dart AOT 的 arm64、实际摘要和 CodeDirectory requirement、深度严格签名、helper 源码回执及 fixture 文件排除。owner 保持沙盒、worker 保持继承、helper 无额外 entitlement。开发包为本地 ad-hoc 签名，此检查不启动 App/helper、不访问库，不等于分发签名、TCC 或产品端到端验收。若公共接线尚未合并，Dart driver 可能被 AOT 树摇移除，不能把原生 bridge 已打包当作 capability 已可用。

公共接线冻结后，在同一最终源码上重新构建普通 App 和 AOT `packages/info_cli/bin/chiyo.dart`，再按以下步骤执行。全过程使用新建的专属 profile，不覆盖默认库，不设置 HOME，不迁移或枚举真实库，不在 QA 中伪造批准。

1. `python3 scripts/qa/macos-native-product-flow.py prepare build/native-product-flow-<unique>`。它创建私有 QA 根、合成 ZIP、唯一 profileName 和 credentialName，不启动产品。
2. 使用普通 App 的 `--connection-profile <返回的 profileName>` 参数启动本次 build 产品（不安装）。可通过 `open -n <准确 App> --args --connection-profile <profileName>` 在执行验收时启动；准备阶段不执行。只选择本地模式、创建新合成库，在正常凭据 UI 新建返回的唯一名称、字符串值 `Synthetic-Zip-42!`、公开目录可见。该库由正常 App 使用自己的独立 libraryId/系统钥匙串项；不读取任何已有库或钥匙串项。若出现未授权的系统权限/钥匙串提示，停止并记录，不代替用户批准。
3. 用 Archive Utility 正常打开本 QA 根的唯一合成 ZIP，保持密码框存活。明确找到该 profile 的实际 connectionDirectory（正常沙盒 App 通常位于其 Container 的 Application Support/Chiyo/online/profiles 下），向脚本传此路径；不读取管理凭据，只核对本 profile 的 local-library.json 与 Agent 连接文件。
4. `python3 scripts/qa/macos-native-product-flow.py request <QA根> --cli <本次同源build下的chiyo绝对路径> --connection-directory <该profile绝对路径>`。脚本建立独立聊天，检查 doctor 的 native capability，仅接受一个指定合成凭据和对应 ZIP 的唯一目标，然后走真实 fill targets → fill request。pending 的 CLI exit 6 是正常等待批准。回执给出 requestId。
5. 在普通 App 的真实审批界面核对应用、ZIP、实际窗口/字段说明及 b1，再实际批准；确认批准后尚未填写。保持原 helper/AppHost，不重启。不得由脚本调用 Owner API 或数据库改状态。
6. 独立观察器先做稳定/焦点切换校准，然后采样真实填写区间；该阶段不进行其他 UI 自动操作。`python3 scripts/qa/macos-native-product-flow.py run <QA根>` 只读查询真实批准后执行一次 fill run，先落盘 runAttempted 和稳定 operation ID。超时或 unknown 后只能 status，脚本拒绝再次 run，不生成替代操作。并发执行由独占 QA 锁拒绝。
7. `python3 scripts/qa/macos-native-product-flow.py status <QA根>` 查询 operations show。必须见 executionState=filled、itemResults.b1=sent，同时独立观察器有效样本保持前台/焦点/鼠标/剪贴板。sent 仍不代表解压成功。
8. 结束观察区间后单独在归档工具提交，再执行 `python3 scripts/qa/macos-native-product-flow.py business <QA根>`。只将本次 ZIP 解压出的固定文本与原始字节比较并记 SHA256，不读取密码控件值。

脚本的 prepare 与命令格式/拒绝路径可以在接线前检查；request/run/business 的真实产品通过必须在最终接线和实际审批后另行记录。结束时正常退出该合成 AppHost/聊天，确认没有本次 helper/夹具残留，再清理专属 profile 与它自己的合成库/钥匙串项；不使用宽泛进程名退出或清理真实库。
