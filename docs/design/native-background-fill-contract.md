# 原生后台填写实施合同

2026-11-14。用户已授权开发；独立功能票为 [#144](https://github.com/ShiJiJS/chiyo/issues/144)，不归 CLI #143。公共实现基于冻结提交 `296ba1c893cb5ee3131f2d9e25c5039202b465e1`。本文件定义待交付行为，平台和真实控件验证通过前不宣称可用。

## 范围与边界

新增 `via: native`，与 `focus`、`ego`、`chrome` 分开批准。Mac 支持经验证的标准 AppKit 密码控件；Windows 支持经验证的 Win32、WinForms、WPF 原生密码控件。浏览器继续走 Ego/Chrome 表单适配；内嵌网页、WK、Electron 及无法确认原生密码语义的控件拒绝。

整个发现、准备、执行过程不点击、不激活窗口、不抢前台、不改变键盘焦点，不发送键盘事件、不使用剪贴板。通过原设备可信 helper 对固定控件调用 setter。失败不回退 focus、网页适配或凭据原文读取。

原生引用核验只能确认操作系统提供的对象身份和支持的控件类型，不能为任意 App 的业务用途提供原子保证。目标 App 可能在检查与 setter 之间改变业务状态，或拒绝把 setter 的值用于登录。向用户展示这一限制，不通过反复审批制造不存在的技术保证。

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

发现只列出匹配应用内支持的密码目标，不读取值、不创建申请、不准备凭据、不弹系统权限。无匹配项成功返回空列表；缺权限、helper 不可用、平台不支持返回明确非零失败。

成功发现响应沿用 CLI 外层 `schemaVersion:1, ok:true, data`。data 含 `status:ok`、`targets`。每项是 `NativeFillTarget` 的公开快照：

```json
{
  "targetId": "opaque-random-id",
  "helperInstanceId": "opaque-helper-instance",
  "platform": "macos",
  "application": {"executable": "/Applications/Example.app/Contents/MacOS/Example", "sha256": "64 lowercase hex digits"},
  "appId": "example.bundle.id",
  "appName": "Example",
  "windowId": "opaque-window-id",
  "windowTitle": "登录",
  "fieldLabel": "密码",
  "controlKind": "appkit_secure_text"
}
```

`controlKind` 限 `appkit_secure_text`、`win32_password`、`winforms_password`、`wpf_password`。快照不含控件值、进程号、原生句柄、可领取材料的证明或 helper 私有引用。编号不可通过公开信息推导；编号本身不授予写入能力。可信 helper 内部将编号绑定到原 helper 实例、进程代际、窗口及具体字段对象。

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

### 私有平台 wire（format 1）

两端包装层将上述接口映射为同一消息字段。Windows 无窗口 helper 使用私有标准输入/输出上的有界 JSON 消息，Mac 使用 `agent_info_manage/native_background_fill` MethodChannel 到可信 helper；通道自身的私有连接鉴权仍由平台实现。字段中的编号均为 22–128 位 base64url 字符，scope 为 64 位小写十六进制。Mac 方法名与 command 相同；MethodChannel arguments 可包含 command，helper 统一校验。

| command | 请求字段（除 format:1 / command 外） | 成功响应（含 format:1） |
| --- | --- | --- |
| `discover` | `scope, appId`，可选 `windowId` | `state:ready, targets:[NativeFillTarget JSON]` |
| `prepare` | `scope, targetId`，可选 `expected:NativeFillTarget JSON` | `state:prepared, target:NativeFillTarget JSON, leaseId` |
| `setValue` | `scope, leaseId, bytes:[0..255]`（完整 UTF-8 字节） | `state:sent`，或 `state:refused/unknown,errorCode` |
| `close` | `scope, leaseId` | `state:closed` |
| `release` | `scope, targetId` | `state:released` |

普通失败为 `format:1,state:refused,errorCode`，只使用 `nativeFillErrorCodes`。`setValue` 的 sent/refused/unknown 子对象可由 `NativeFillResult.fromJson` 解析，包装层先移除 wire 的 format。准备前拒绝为 refused；setter 开始后失联或异常为 unknown。失去 reply 后不能对同一 lease 再发送 setter；helper 必须记录 lease 已尝试一次并拒绝重放。close/release 幂等。leaseId 仅留在平台包装层与 helper，不进 CLI、服务器批准、备份或普通操作记录。bytes 不得写日志、异常正文或命令行；包装层与 helper 都按平台能力清零临时缓冲。

`setValue` 接收一份完整 UTF-8 密码，不拆成焦点键盘输入批次，不添加换行；仅一次调用原生 setter。平台须检查编码、长度及控件限制，未知写入不再次调用 setter。驱动先完成最后的只读检查，调用并等待 `beforeDispatch` 成功，再由 helper 重新核验引用后直接 setter；回调失败不得写入。最后一次检查与 setter 的平台原子性限制仍按上文说明。

`NativeFillResult` 包含 `state`（`sent/refused/unknown`）和可选的安全 `errorCode`。`sent` 表示 setter 接受，不代表登录或任意 App 业务识别成功；已接受后连接中断、无法确认是否调用等情况为 `unknown`。`refused` 必须能确认没有写入。`close()` 幂等释放本次准备或 reservation，不使同一授权的其他操作扩大范围。

异常采用 `CredentialUseFailure` 及公开原因码：缺权限 `access_denied`、helper/会话不可用 `session_unavailable`、不支持 `unsupported_capability/unsupported_target`、失效 `target_unavailable/destination_changed`、并发 `busy`、写入未知 `fill_unknown`、已知 setter 拒绝 `input_rejected`。原生异常正文不得透传。

## 引用生命周期

helper 为每次运行生成新的 `helperInstanceId`；targetId 不跨 helper 重启恢复。未用于申请的发现项保留最多 5 分钟，每 scope 最多 64 项，单次发现最多返回 64 项；超限明确拒绝或清理已过期未使用项，不驱逐仍被准备的引用。

申请冻结后，helper 可以保留该固定目标供原有效授权复用，但每次操作仍检查原 scope、helper 实例、进程代际、窗口、控件类型和支持状态。保留引用不延长服务器批准期限。进程结束、窗口/字段对象重建、helper 重启、scope 结束或引用丢失均使原目标失效；旧批准及历史仍可查询，但不能按标题、名称或控件位置重新绑定。平台实现须有有界的已保留目标上限和明确拒绝，不无限持有对象。

## 审批、执行与持久兼容

复用 `CredentialBatchDestination` 增加 `native` 目标类型；不得把 native 存为 focus application。批准展示 App、窗口、字段和后台 setter 方式，仍固定凭据版本、原设备、原私密聊天和逐项期限。服务器保管批准和持久操作，helper 仅在原设备执行。

执行依次核对原批准、重新准备所有目标、持久登记稳定操作、领取全部材料、在每个 setter 前重新授权，再调用对应 prepared setter。任何必要项不可用则不开始输入；已经完成前面项后失败使用现有 `partial`。busy 按原固定原生目标隔离，不按当前前台焦点隔离。使用现有未知/部分结果核对机制，未知结果不重放，不靠新操作编号绕过。

CLI/AppHost/服务器显式协商 `credential-native-fill.v1`，且继续要求 `credential-batches.v3`。未接入 native 驱动的平台不广告执行能力，发现/申请返回不支持；旧服务缺能力时在发现或申请检查前停止，不降级。

native 快照进入既有加密申请与操作。第一次保存新事实提高资料库格式；含 native 历史的备份/同步使用新的内容格式，旧读取器明确拒绝。普通旧资料不因安装新版升级。可移植历史仅供查看，不携带 helper 引用、恢复私密聊天或重新填值的能力。具体版本号在公共持久测试中冻结。

## 首个可交付检查点

公共模型、CLI 参数和目标发现 IPC、native 申请/审批投影、持久操作执行及能力拒绝可以用合成 driver 做完整专项测试；没有平台 driver 时明确不可用。测试必须证明跨聊天、helper 重启、对象失效不能继续使用旧目标，批准不输入，重复操作不再次 setter，回调拒绝不写入，setter 不确定后保留未知且不重放。真实 AppKit、Win32/WinForms/WPF 控件验收由对应平台执行会话完成后，才开启该平台能力和进入最终交付。
