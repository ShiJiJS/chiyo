# Mac 原生后台填写（#144）

平台实现基于公共合同 `dd03d22e`。Dart 入口是 `MacOSNativeBackgroundFillDriver`，实现 `NativeFillDriver`，供公共 Launcher/AppHost 注入；本目录不修改公共审批、持久操作或 CLI。Runner 注册私有 MethodChannel，使用既有签名校验的 XPC 服务；所有 AX 发现、引用和写入都只在非沙盒 helper 中执行。未正式安装应用或修改系统权限。

正式构造为 `MacOSNativeBackgroundFillDriver()`，不需要异步 factory、路径、摘要或 Agent 配置。可选 `MethodChannel`、timeout 参数仅为 Owner 测试 seam。每个 AppHost 持有一个 driver；交给 `ownsNativeDriver: true` 的 AppHost 成功之前由装配方拥有，启动失败须 `dispose()`，成功后由 AppHost 关闭流程销毁。单次 prepared.close 只关闭票据，CLI 短连接结束不能销毁 resident driver。公共 Launcher 由公共会话唯一修改。

## 首批真实兼容范围

`NativeBackgroundCompatibility.swift` 是可信构建维护的版本名单，当前只登记：

- 系统归档实用工具 `com.apple.archiveutility`，10.15（178）。
- macOS 构建 `26A434`、该条目固定的可执行文件 SHA-256 和实际 arm64e CodeDirectory hash。
- 中文 UI 的归档密码提示；窗口 `_NS:8`、唯一安全文本字段 `_NS:280`、提示静态文本 `_NS:270`。提示必须匹配已验证的密码请求形状，并在每次检查中保持原文相等。
- 本轮实际业务验收为合成加密 ZIP：后台填写后，由独立 UI 操作提交，解压文件与输入内容哈希精确一致。也通过了“签名沙盒测试宿主 → 真实 XPC helper → 真实归档工具”路径。

这不是所有 AppKit 应用或所有系统版本的通用支持。OS/App 更新、不同签名切片、UI 形状不符、多个同标识窗口或目标不可核验时拒绝；不会放宽到相似角色或自动改绑新控件。Preview 的 PDF 密码场景虽然 setter 接受、UI 就绪，但指定打开密码的业务验收未通过，因此未登记。

正面依据来自准确版本的原生 AppKit 资源、原生安全文本行为和真实业务测试。公共 AX 不能证明任意对象的具体实现类；仅有 AXSecureTextField 绝不构成兼容证据。运行时还排除整窗 AXWebArea、AXDOMIdentifier、ChromeAXNodeId。内嵌网页/WK/Electron 不支持，浏览器继续专用 API。

名单是 helper 源码的一部分，经可信 App 构建、签名和分发。更新条目需重新验证版本、结构及业务接收。Agent、请求 JSON、用户偏好、PID、scope 摘要或“我是原生”的声明都不能注册或覆盖它。

## 发现与身份

helper 从获准应用的身份匹配实际运行进程，核验同用户、启动代际、规范可执行路径、文件见证和实际进程签名。窗口/字段元数据只用于第一次唯一定位；之后保持原 AX 对象，重新核对树成员、唯一性、类型、可用/可写及上下文，不按名字恢复已失效目标。

快照只包含公共合同的 opaque ID、App 身份、窗口及字段说明；不含 PID、AX 地址、密码值或 private lease。可读描述总是附带稳定标记，不能只靠随机 targetId 猜同名框。标记及标题按 UTF-16 边界限制长度。

不读取密码控件 AXValue、选中文字或原值。兼容规则可读取经 AXStaticText 角色校验的非值标签元数据，用来展示归档名并冻结可见上下文；这些静态标签不能代替授权。

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

默认仅运行无系统输入的控制器检查和源码类型检查。`--platform` 运行合成 AppKit/WK 排除夹具，覆盖后台/遮挡/最小化/隐藏、B 保留响应者、前台合成输入、鼠标/剪贴板保持、整值替换、只读/禁用/重复/重建/关闭/重启/上下文改变，以及 beforeDispatch 后再次复核。观察器运行 RunLoop，验证焦点元素自身 PID，nil 不算保持。临时 App、二进制和缓存自动清理，JSON 和源哈希留在 `build/native-background-macos/`。

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
5. 在普通 App 的真实审批界面核对应用、ZIP、稳定字段标记及 b1，再实际批准；确认批准后尚未填写。保持原 helper/AppHost，不重启。不得由脚本调用 Owner API 或数据库改状态。
6. 独立观察器先做稳定/焦点切换校准，然后采样真实填写区间；该阶段不进行其他 UI 自动操作。`python3 scripts/qa/macos-native-product-flow.py run <QA根>` 只读查询真实批准后执行一次 fill run，先落盘 runAttempted 和稳定 operation ID。超时或 unknown 后只能 status，脚本拒绝再次 run，不生成替代操作。并发执行由独占 QA 锁拒绝。
7. `python3 scripts/qa/macos-native-product-flow.py status <QA根>` 查询 operations show。必须见 executionState=filled、itemResults.b1=sent，同时独立观察器有效样本保持前台/焦点/鼠标/剪贴板。sent 仍不代表解压成功。
8. 结束观察区间后单独在归档工具提交，再执行 `python3 scripts/qa/macos-native-product-flow.py business <QA根>`。只将本次 ZIP 解压出的固定文本与原始字节比较并记 SHA256，不读取密码控件值。

脚本的 prepare 与命令格式/拒绝路径可以在接线前检查；request/run/business 的真实产品通过必须在最终接线和实际审批后另行记录。结束时正常退出该合成 AppHost/聊天，确认没有本次 helper/夹具残留，再清理专属 profile 与它自己的合成库/钥匙串项；不使用宽泛进程名退出或清理真实库。
