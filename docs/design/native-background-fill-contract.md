# 原生后台填写实施合同

2026-11-14 修订：按用户要求，将应用兼容名单改为按当前控件能力判断。决策见 [ADR0033](../adr/0033-native-fill-by-control-capability.md)，实施与进度统一在 [#144](https://github.com/ShiJiJS/chiyo/issues/144)，不归 CLI #143。本文件定义目标设计；当前生产代码仍有 Mac 应用名单和 Windows 控件家族限制，本次文档修订不代表代码已经完成适配。

## 范围与边界

`via: native` 与 `focus`、`ego`、`chrome` 分开批准。对任意应用，可信 helper 根据实际密码控件是否提供可用的后台写入接口决定是否支持；不要求软件事先登记，也不按应用名称、版本、系统构建号、界面语言或开发框架建立允许名单。当前范围仍是密码控件，不扩大为任意普通文本框或自动提交登录。

Mac 使用系统辅助功能（AX）的密码控件与可写 `AXValue`；Windows 使用 UI Automation（UIA）的密码控件与可写 `ValuePattern`。浏览器页面继续走 Ego/Chrome 专用接口；识别为内嵌网页的目标不进入原生填写路径。AppKit、Win32、WinForms、WPF 是需要验证的常见实现，不是其他实现取得支持资格前必须匹配的名称。

helper 在整个发现、准备、执行过程中不点击、不激活窗口、不抢前台、不改变键盘焦点，不发送键盘事件、不使用剪贴板。通过原设备可信 helper 对固定控件调用 setter。失败不回退 focus、网页适配或凭据原文读取。

原生引用核验只能确认操作系统提供的对象身份与接口能力，不能证明目标 App 内部的具体类，也不能为任意 App 的业务用途提供原子保证。目标 App 可能在检查与 setter 之间改变业务状态，或拒绝把 setter 的值用于登录。向用户展示这一限制，不通过逐应用登记或反复审批制造不存在的技术保证；沿用 [ADR0002](../adr/0002-local-authorization-boundary.md) 的本机信任边界。

## 怎样判断一个控件能否后台填写

发现时只查询结构与能力，不用测试密码试写，不读取原密码。通过以下检查的目标可供 Agent 申请，真正写入仍须用户批准。

| 检查 | Mac | Windows |
| --- | --- | --- |
| 它是密码框吗 | `AXTextField` / `AXSecureTextField` 语义 | `ControlType=Edit` 且 `IsPassword=true` |
| 能直接写值吗 | 启用，`AXUIElementIsAttributeSettable(AXValue)` 为真 | 启用，提供 `ValuePattern`，`IsReadOnly=false` |
| 可以固定同一个目标吗 | 持有 AX 应用、窗口及字段对象，核验所属进程、祖先关系和存活状态 | 持有进程、窗口及 UIA 字段对象，使用运行期对象身份与 `CompareElements` 复核归属和存活状态 |
| 怎样写入 | 一次 `AXUIElementSetAttributeValue(..., AXValue, secret)` | 设置 `IUIAutomation2.AutoSetFocus=FALSE` 后，一次 `IUIAutomationValuePattern.SetValue(secret)` |

Mac 不再使用预置 bundle ID、可执行文件摘要、签名 hash、控件编号或中文提示正则决定资格。Windows 不再要求 FrameworkId/ClassName 必须属于现有三类；符合上述能力的其他原生 UIA provider 也走通用路径。框架专用检查只用于该框架，例如 `EM_GETLIMITTEXT` 仅用于已确认的标准 Edit/兼容 Edit，不能向任意带 HWND 的 UIA 控件发送该消息，也不能因某控件没有 HWND 就排除它。

两端保留必要的系统权限与会话检查。Mac 要有已授予的辅助功能权限；Windows 要求相同用户和会话、目标不高于 helper 的完整性级别，并确认能关闭 UIA 自动聚焦。helper 不点击、激活或设置焦点；不靠申请更多权限、提升进程或聚焦来补救不支持的控件。操作系统接口不能保证第三方应用在收到值后不会自行激活窗口；已知需要聚焦的写入方式不进入后台路径，测试也要区分 helper 行为与应用自身反应。

网页排除检查针对目标及其通向所属窗口的祖先链：例如 AXWebArea、DOM 标记、已识别的 WebView/浏览器节点。不能因为同窗另一个区域嵌有网页，就拒绝独立的原生密码框。接口证据冲突或无法确认密码语义时返回不支持；仅凭 AX/UIA 元数据不能绝对证明内部实现，不能把“未发现网页标记”宣传为对所有自定义控件的证明。

### 应用身份仍然核对，但从实际目标取得

helper 在发现时读取实际进程的可执行文件路径、文件摘要、进程启动代际和对象归属，申请固定这些事实，写入前与原对象再次比较。Mac 对已签名程序还核验并固定运行中签名身份；不是要求该签名事先在产品代码中登记。无签名本身不等于不支持，能可靠核验进程、文件及控件的其他事实时仍可继续；无法取得必要身份事实则拒绝。知予自身与 helper 之间原有的包完整性、签名及私有连接鉴权不放宽。

例如：一个首次遇到的原生应用只要满足控件能力、目标身份与授权条件，就可以填写。该应用升级后，旧申请不能沿用到新进程；重新发现和批准后仍可填写，无须等待知予发版添加新版本名单。

`AXIdentifier`、`AutomationId` 是可选的定位与展示信息，不是应用加入支持范围的门票。缺少这些开发者命名的编号时，helper 仍可通过持有的对象和归属关系固定目标；但返回的窗口、字段标签和必要的分组说明必须足以区分候选。描述仍有歧义则拒绝，不用坐标、排列序号或随机 targetId 让 Agent 猜框，也不依赖名称重建失效引用。

### 兼容性测试记录与运行条件分开

测试过的软件、版本及真实业务结果放在兼容性记录中，用来说明证据范围，不参与是否允许调用 setter 的判断。不设置“未经本团队测试即拒绝”的默认分支。已知不支持的接口能力、控件状态或网页目标可以在运行时明确拒绝；发现平台缺陷应修复相应能力检测或实现，不退回逐应用允许名单。

## CLI 与发现

```sh
chiyo fill targets --via native --app APP_ID [--window WINDOW_ID] --json
chiyo fill request --via native --target TARGET_ID --credential CREDENTIAL_ID \
  [--version N] --purpose TEXT [--operation ID] --json
chiyo requests wait REQUEST_ID --timeout 60 --json
chiyo fill run --request REQUEST_ID [--item b1] [--operation ID] --json
chiyo operations show OPERATION_ID --json
```

发现必须使用当前已认证的私密聊天和原执行设备 App。`APP_ID` 只是过滤条件：Mac 通常为 bundle ID，Windows 桌面程序为可执行文件的完整路径；helper 仍须核验真实可执行文件身份、进程代际和控件。不接受 PID、HWND、AX 地址或坐标作为写入授权。`WINDOW_ID` 必须来自同一 helper 返回的不透明窗口编号。

发现只列出匹配应用内支持的密码目标，不读取值、不创建申请、不准备凭据、不弹系统权限。应用未运行或没有发现密码候选时可以成功返回空列表；已发现密码候选但全部因接口不支持、网页类型或歧义被排除时，返回 `unsupported_target`，不能伪装成空列表。部分候选可用时返回可用项。查询权限不足、helper 不可用、枚举失败或平台不支持返回相应非零失败，不将错误吞成“没有密码框”。

成功发现响应沿用 CLI 外层 `schemaVersion:1, ok:true, data`。data 含 `status:ok`、`targets`。每项是 `NativeFillTarget` 的公开快照：

```json
{
  "targetId": "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN",
  "helperInstanceId": "HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH",
  "platform": "macos",
  "application": {"executable": "/Applications/Example.app/Contents/MacOS/Example", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  "appId": "example.bundle.id",
  "appName": "Example",
  "windowId": "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW",
  "windowTitle": "登录",
  "fieldLabel": "密码",
  "controlKind": "macos_ax_password"
}
```

本版新发现项的 `controlKind` 为 `macos_ax_password` 或 `windows_uia_password`，描述使用的系统密码控件接口，不声称识别了 App 内部类。原 `appkit_secure_text`、`win32_password`、`winforms_password`、`wpf_password` 保留历史解析，不把新的未知家族伪装成 WPF。快照不含控件值、进程号、原生句柄、可领取材料的证明或 helper 私有引用。编号不可通过公开信息推导；编号本身不授予写入能力。可信 helper 内部将编号绑定到原 helper 实例、进程代际、窗口及具体字段对象。

Agent 提交申请只传 `targetId`，不能自行构造快照。AppHost 按原私密聊天摘要向 helper 准备该发现项，取得并冻结经过核验的快照。多项业务 JSON 的 destination 为 `{"via":"native","targetId":"..."}`，与其他填写方式共用一份申请和逐项批准。

## 平台驱动合同

公共类型在 `packages/info_core/lib/native_fill_models.dart`，由 `info_core.dart` 导出。平台包装层实现下列 Dart 接口；两端原生实现及私有传输由平台会话负责：

```dart
abstract interface class NativeFillDriver {
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  });
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  });
  Future<void> release({required String scope, required String targetId});
  Future<void> dispose();
}

abstract interface class PreparedNativeFill {
  NativeFillTarget get target;
  Future<NativeFillResult> setValue(
    List<int> utf8Bytes, {
    required Future<void> Function() beforeDispatch,
  });
  Future<void> close();
}
```

`scope` 为 AppHost 对原连接和私密聊天作出的固定摘要，不包含聊天证明或密码，也不采用公开聊天 ID。发现项和引用不得跨 scope。`prepare(expected:null)` 仅用于申请前解析发现项；`expected` 非空时必须与原快照完全相同，不能通过新发现项替换目标。准备只核验并保留引用，不写密码。

`scope` 摘要不是授权凭证。helper 所有命令仍必须经原私有 AppHost 连接鉴权，不能开放一个仅凭 scope/targetId 就能写值的公共入口。`prepare(expected:null)` 成功后将发现项提升为保留目标，保证提交申请及随后批准期间仍指向原对象；本次 `close()` 不删除它。显式 `release(scope,targetId)` 幂等忘记目标，AppHost 仅在没有其他原申请需要该目标时调用；原私有宿主连接结束时 helper 释放该连接保留的全部目标。每 scope 最多保留 256 项，达到上限拒绝新的提升，不驱逐有效目标。服务器批准失效后仍不得写入，保留引用不产生或续期授权。

`dispose()` 幂等结束该 driver 持有的 resident AppHost→helper 私有连接，使该连接的全部发现项、保留目标和 lease 失效；共享 helper 服务只清理此连接，不代其他连接销毁目标。AppHost `start(nativeDriver:..., ownsNativeDriver:true)` 成功后取得驱动所有权，默认 true；其关闭路径在 finally 中调用 dispose，包括清理期间出错的情况。显式借用 `ownsNativeDriver:false` 时，AppHost 只关闭自身准备，保留目标及 resident driver 的销毁由调用方负责。start 失败时所有权尚未转移，装配方负责销毁。每条 CLI 命令结束、CLI 回复丢失或其短连接断开都不触发 resident driver dispose，不取消 AppHost 已接收的操作，也不删除仍有效的目标。

### 私有平台 wire（format 1）

两端包装层将上述接口映射为同一消息字段。Windows 无窗口 helper 使用私有标准输入/输出上的有界 JSON 消息，Mac 使用 `agent_info_manage/native_background_fill` MethodChannel 到可信 helper；通道自身的私有连接鉴权仍由平台实现。字段中的编号均为 22–128 位 base64url 字符，scope 为 64 位小写十六进制。Mac 方法名与 command 相同；MethodChannel arguments 可包含 command，helper 统一校验。

| command | 请求字段（除 format:1 / command 外） | 成功响应（含 format:1） |
| --- | --- | --- |
| `discover` | `scope, appId`，可选 `windowId` | `state:ready, targets:[NativeFillTarget JSON]` |
| `prepare` | `scope, targetId`，可选 `expected:NativeFillTarget JSON` | `state:prepared, target:NativeFillTarget JSON, leaseId` |
| `setValue` | `scope, leaseId, bytes:[0..255]`（完整 UTF-8 字节） | `state:sent`，或 `state:refused/unknown,errorCode` |
| `close` | `scope, leaseId` | `state:closed` |
| `release` | `scope, targetId` | `state:released` |
| `dispose` | 无额外字段（仅原 private owner 连接） | `state:disposed`；随后关闭该连接 |

dispose 的确认是尽力而为；包装层即使收不到确认也必须关闭自己持有的私有传输/进程连接。helper 应在 owner 连接断开时执行同样的引用失效。Mac 对应 resident bridge 连接销毁，Windows 对应无窗口 helper 的 owner 管道/进程生命周期；不得把此规则套到每次 CLI→AppHost 的请求连接。

dispose 不能排队等待某次 setter 的回复：AppHost 停止接受新操作后，先关闭 owned native driver，使待决 helper 读取能结束，再等待操作收尾。包装层必要时直接断开管道/连接或终止自己拥有的 helper，且须在异常路径的 finally 中释放传输；不终止目标 App。若 setter 已开始，关闭后无法确认结果就保留 unknown，不推断未写入，不重放。

普通失败为 `format:1,state:refused,errorCode`，只使用 `nativeFillErrorCodes`。`setValue` 的 sent/refused/unknown 子对象可由 `NativeFillResult.fromJson` 解析，包装层先移除 wire 的 format。准备前拒绝为 refused；setter 开始后失联或异常为 unknown。失去 reply 后不能对同一 lease 再发送 setter；helper 必须记录 lease 已尝试一次并拒绝重放。close/release 幂等。leaseId 仅留在平台包装层与 helper，不进 CLI、服务器批准、备份或普通操作记录。bytes 不得写日志、异常正文或命令行；包装层与 helper 都按平台能力清零临时缓冲。

`setValue` 接收一份完整 UTF-8 密码，不拆成焦点键盘输入批次，不添加换行；仅一次调用原生 setter。平台须检查编码、长度及控件限制，未知写入不再次调用 setter。驱动先完成最后的只读检查，调用并等待 `beforeDispatch` 成功，再由 helper 重新核验引用后直接 setter；回调失败不得写入。最后一次检查与 setter 的平台原子性限制仍按上文说明。

`NativeFillResult` 包含 `state`（`sent/refused/unknown`）和可选的安全 `errorCode`。`sent` 表示 setter 接受，不代表登录或任意 App 业务识别成功；已接受后连接中断、无法确认是否调用等情况为 `unknown`。`refused` 必须能确认没有写入。`close()` 幂等释放本次准备或 reservation，不使同一授权的其他操作扩大范围。

异常采用 `CredentialUseFailure` 及公开原因码：缺权限 `access_denied`、helper/会话不可用 `session_unavailable`、不支持 `unsupported_capability/unsupported_target`、失效 `target_unavailable/destination_changed`、并发 `busy`、写入未知 `fill_unknown`、已知 setter 拒绝 `input_rejected`。原生异常正文不得透传。

### 不支持、写入失败与结果未知

| 遇到的情况 | 返回与用户提示 | 后续行为 |
| --- | --- | --- |
| 写入前发现没有可写接口、属于网页控件或不能区分目标 | `refused / unsupported_target`：“这个控件暂不支持后台填写” | 不写入，不要求为该 App 添加名单 |
| 无系统权限或会话不可用 | `access_denied / session_unavailable`：“缺少辅助功能权限”或“当前会话不可用” | 不写入；不要误报不支持该软件 |
| 原进程、窗口或字段已经改变 | `target_unavailable / destination_changed`：“原来的输入框已失效，请重新选择” | 重新发现并申请，不能改绑相似框 |
| 控件明确拒绝，并且能确认没有写入 | `refused / input_rejected`：“该控件拒绝了本次填写” | 不自动换键盘、剪贴板或其他写入方式 |
| setter 已开始，超时、断连或异常，无法确定有无写入 | `unknown / fill_unknown`：“无法确认是否已填入，请检查目标应用” | 不自动重试，包括换操作编号重试 |
| setter 返回成功 | `sent`：“已向所选控件送入密码” | 不宣称登录、解压或其他业务已经成功 |

不能把 setter 之后的所有错误统一报为“不支持”：有些失败发生前可能已产生写入。只有有平台证据确认无副作用时才能返回 `refused`；默认不确定就保留 `unknown`。也不通过读回密码、自动提交或发焦点事件来证明业务成功。

## 引用生命周期

helper 为每次运行生成新的 `helperInstanceId`；targetId 不跨 helper 重启恢复。未用于申请的发现项保留最多 5 分钟，每 scope 最多 64 项，单次发现最多返回 64 项；超限明确拒绝或清理已过期未使用项，不驱逐仍被准备的引用。

发现返回的 windowTitle/fieldLabel 必须帮助 Agent 识别具体控件。平台已知的 AXIdentifier、AutomationId 应组合进可读描述，例如 `密码 [AutomationId=loginPassword]`，不因显示名称为空就丢弃这些标识；这些标识只用于描述，不能替代 helper 固定引用作写入授权。同窗或同 App 的候选若结合可见 App/窗口/字段描述和控件类型仍无法区分，应以现有 `unsupported_target` 明确拒绝该歧义发现，不返回一组只能靠随机 targetId 猜测的候选。不增加密码值、原生句柄或私有引用字段。

Windows 本轮拒绝隐藏根窗口；平台内部 `target_not_visible` 在公共 wire 边界映射为已有 `target_unavailable`，不扩充原因码白名单。最小化窗口的支持由 Windows 专项验证决定，不能把隐藏根窗口误标成已支持。

申请冻结后，helper 可以保留该固定目标供原有效授权复用，但每次操作仍检查原 scope、helper 实例、进程代际、窗口、控件类型和支持状态。保留引用不延长服务器批准期限。进程结束、窗口/字段对象重建、helper 重启、scope 结束或引用丢失均使原目标失效；旧批准及历史仍可查询，但不能按标题、名称或控件位置重新绑定。平台实现须有有界的已保留目标上限和明确拒绝，不无限持有对象。

## 审批、执行与持久兼容

复用 `CredentialBatchDestination` 增加 `native` 目标类型；不得把 native 存为 focus application。批准展示 App、窗口、字段和后台 setter 方式，仍固定凭据版本、原设备、原私密聊天和逐项期限。服务器保管批准和持久操作，helper 仅在原设备执行。

执行依次核对原批准、重新准备所有目标、持久登记稳定操作、领取全部材料、在每个 setter 前重新授权，再调用对应 prepared setter。任何必要项不可用则不开始输入；已经完成前面项后失败使用现有 `partial`。busy 按原固定原生目标隔离，不按当前前台焦点隔离。不同 scope 或发现项若指向同一底层控件，helper 必须按持有的原生对象身份拒绝并发，不仅比较 targetId 字符串；不得排队到稍后的控件。使用现有未知/部分结果核对机制，未知结果不重放，不靠新操作编号绕过。

通用控件新发现/申请显式协商 `credential-native-fill.v2`，继续要求 `credential-batches.v3`；v1 记录仅保留原语义与历史读取。CLI 命令、目标 JSON 的字段结构和私有 wire 的 format 1 消息封套不改，更新公共解析器与两端 driver 对新 `controlKind` 的检查；不能仅替换 helper 就宣称完成。与 helper 的传输仍限同包可信实现，旧解析器必须明确拒绝新类型，不能强行标成旧家族绕过兼容检查。未接入相应驱动的平台不广告 v2，缺能力时在发现或申请前停止，不降级。

native 快照进入既有加密申请与操作。v1 使用资料库格式 69、备份/同步内容格式 30；首次保存上述新控件类型时必须提高这两类最低读取版本，防止旧读取器把新事实当作已有类型。实施时从各自版本登记处分配下一可用编号，并在同一提交补齐本文具体数值和旧版拒绝测试；不另建批次表，不占用其他并行迁移的编号。只有既有结构的操作结果或删除编号、没有目标快照的增量仍可使用原结构内容版本；接收端必须已持有对应的只读父申请，不能从孤立操作恢复 native 批准。普通旧资料不因安装新版升级。

可移植历史仅供查看，不携带 helper 引用、恢复私密聊天或重新填值的能力。升级 helper 后必须重新发现目标和申请，不扩大旧批准。批次外层沿用 filled 表示本批流程结束，native 逐项结果只返回 sent；审批/历史文案据此说明 setter 接受，不宣称登录或业务识别成功。

## 本次实施改动与验收

| 部分 | 要修改的现有位置 | 完成条件 |
| --- | --- | --- |
| Mac | `NativeBackgroundCompatibility.swift`、`SystemNativeBackgroundEnvironment.swift`、`NativeBackgroundWire.swift` 及 helper 装配 | 生产路径移除预置 profile 门槛，动态取得身份与控件；保留对象、权限和授权检查；不支持不能静默空列表 |
| Windows | `native_background_fill/target.cpp`、`broker_main.cpp` | 加入通用 UIA 能力路径；移除三框架硬门槛；可选 AutomationId；限定 Edit 专用消息；明确映射通用 kind 和错误 |
| 公共部分 | `NativeFillTarget`、能力协商、审批展示、存储及备份/同步版本 | 两端同一新类型合同，旧数据可读、新数据对旧端明确拒绝；申请与执行仍绑定原控件 |
| 文档 | 平台说明、使用说明、填写原理图解 | 实现后按真实能力更新；测试过的软件及失败样例单独记录，不写成允许名单 |

定向验证至少覆盖：

- 同一驱动支持多个未在生产源码登记的应用。Mac 至少两个不同身份的原生夹具；Windows 除既有三家族外，还需一个 FrameworkId/ClassName 不在原三类中的原生 UIA provider。换应用路径、版本、系统构建或界面语言不能单独触发兼容拒绝。
- `AXIdentifier` / `AutomationId` 缺失仍可固定并清楚描述的控件可用；描述歧义拒绝。重新生成同名控件、复用进程号、helper 重启后旧引用不可用；应用升级后新申请可用，旧申请不可用。
- 可写密码控件成功；普通文本、禁用、只读、缺少 setter、已识别内嵌网页明确拒绝。原生字段旁边有无关网页区域不误拒绝。目标/权限查询失败不伪装为空列表。
- 保留跨聊天、原设备、逐项批准、过期/撤销、helper 身份、busy 与操作防重放回归。批准本身不输入；每次 setter 前重新授权；未知/部分结果不自动重放。
- 后台、遮挡、最小化与各平台支持的隐藏状态分别记录。校准后的前台/焦点观察必须覆盖 setter 开始至结束，不能用调用前后的稳定片段替代；helper 不产生鼠标、键盘、焦点和剪贴板操作。
- 每个平台保留真实软件业务样例，分别记录 setter 成功与后续业务接收结果。这用于验证实现与说明限制，不成为其他应用使用功能的先决条件；失败样例（如已知 Preview 场景）不得从证据中删除。

这些检查验证公共路径及失败处理，不要求逐个测试市场上的所有软件。实现与定向验证完成后才能声称已取消名单；Release 仍按用户要求等待其他缺陷修复后再安排。

## 系统接口依据

- Apple：[查询属性是否可写](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable)、[设置 AX 属性](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)。它们描述接口及返回错误，不承诺目标应用业务成功。
- Microsoft：[关闭 UIA AutoSetFocus](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation2-put_autosetfocus)、[ValuePattern.SetValue](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationvaluepattern-setvalue)。关闭自动聚焦后仍须检查目标启用及非只读状态。
