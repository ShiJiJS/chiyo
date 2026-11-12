# macOS 本机焦点填充

Mac 默认构建包含独立 XPC helper；本机资料库直接使用本机驱动，NAS 资料库由同一电脑上运行的App领取已批准的使用操作并调用同一驱动。能力取决于实际执行设备、App当前连接、helper 权限和当前输入目标，不能用 NAS 的操作系统或一次权限检查代替目标发现。

凭据交付方式和原文读取边界以 [ADR0031](../adr/0031-device-credential-delivery-and-reveal.md) 为准；申请、授权、逐操作审计和防重放沿用 [v2 协议](runtime-protocol-v2.md)及[本机焦点填充合同](local-focused-fill-contract.md)。本文规定 Mac 平台接口及执行边界，授权期限由当前公共模型处理，不在原生层另设业务期限。

## 设置与公开接口

设置页通过私有 MethodChannel `agent_info_manage/focused_fill` 检查本机权限。权限属于实际执行 AX/输入调用的 helper，沙盒主程序自身的可信状态不能代替它。

| MethodChannel 方法 | 参数 | 行为 |
| --- | --- | --- |
| `permissions` | `null` 或空对象 | 建立经过签名核验的短连接，只读查询 helper 的 AX 和事件投递权限。 |
| `requestPermission` | `null` 或空对象 | 仅由用户在设置页主动点击申请调用；helper 请求辅助功能权限，必要时请求事件投递权限。 |

两者返回 `{format: 1, platform: "macos", state: "ready" | "permission_required" | "unavailable", errorCode?: string}`。`ready` 只表示该 helper 当前权限就绪；`permission_required` 的错误码为同名值，`unavailable` 使用 `session_unavailable` 或 `busy`。启动、能力查询、普通权限刷新和目标发现均不弹出系统权限申请。系统授权后重新检查；换签名、升级或改变启动方式后的许可保持情况须以实际产物为准。

核心使用既有 `FocusedFillDiscoveryDriver` / `PreparedFocusedFill`，由 `MacOSFocusedFillDriver` 适配：

| 核心接口 / Channel 方法 | 约束 |
| --- | --- |
| `inspectTarget()` / `inspect` | 只返回目标就绪状态及公开应用身份；不保留焦点、不读取控件值、标题或页面正文。 |
| `prepare(application)` / `prepare` | 核对获批应用和真实前台密码框，固定本次进程创建身份与原生目标。 |
| `sendBatch(units)` / `send` | 核心登记本次输入放行并核查授权后，传递最多 16 个 UTF-16 单元；原生每批重查同一目标。 |
| `close()` / `close` | 终止当前连接与租约；失联、重启或超时后不恢复旧目标、不重发批次。 |

填充 Channel 参数中的 `connection` 是 Dart 生成的 32 位小写十六进制取消标识；`prepare` 另传 `application`，`send` 另传小端 UTF-16 字节。原生租约和批次序号保留在 Swift/XPC 内部，不作为 Agent 可指定的目标。权限状态与目标发现的 `ready` 回复形状不同，不能互换。

应用身份由规范可执行路径和 SHA-256 组成。Mac 使用绝对 POSIX 路径并保留大小写；实际检查解析规范文件，核对当前用户、PID、内核创建时间和文件身份。网页网址仅供用户判断，不证明浏览器来源或域名。每次操作只填一个获准的字符串凭据，沿用公共模型的长度与控制字符限制。

申请形状示例（凭据 ID、应用路径及摘要均为合成值；真实请求使用目标发现返回的身份）：

```json
{
  "protocolVersion": 2,
  "command": "request-use",
  "purpose": "登录合成测试页面",
  "credentials": [{"alias": "password", "credentialId": "synthetic-password", "version": 1}],
  "fill": {
    "application": {
      "executable": "/Applications/合成浏览器.app/Contents/MacOS/SyntheticBrowser",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "targetHint": "https://portal.example.invalid/login"
  }
}
```

## 原生执行与签名边界

主 App 及现有 worker 保留沙盒。只有 `apps/desktop/macos/focused_input/` 中独立编译的 helper 包含跨应用 AX 观察和系统输入实现；helper 不打开资料库、不持有资料库密钥。默认 `scripts/dev-macos.sh build` 和完整 Mac 打包流程将其放入 `Contents/XPCServices`，先签内层，再保留主 App 权限重签外层。

XPC 使用固定私有服务名，两侧从封装包推导准确原生架构 CodeDirectory 哈希要求，并核对运行代码及规范路径。客户端在连接启动前设置 helper 要求；helper 对接受的 `NSXPCConnection` 在 `resume` 前设置调用者要求，并检查用户和进程身份。`NSXPCListener.service()` 不支持 `setConnectionCodeSigningRequirement`，不能在该 listener 上调用；签名约束施加在实际接受的连接上。版本变化不恢复旧连接。

每个准备好的目标只属于当前连接，原生租约最多 60 秒，与业务授权期限分开。用户级文件锁只允许一个活动输入租约，忙碌立即拒绝。父进程退出、连接失效、租约到期或时钟异常均释放目标；5 秒 XPC 截止和一次完成处理避免阻塞界面及迟到重放。AX 单次消息有 0.15 秒截止，一轮目标观察有 2 秒预算。

秘密仅通过有界内存批次进入 helper，使用定向 `CGEvent` down/up 发送 Unicode。生产实现不读取密码值，不自动清空已有内容、激活目标或提交登录，也不使用普通剪贴板、命令参数、环境变量、明文文件或日志传递秘密。可变缓冲尽力清零，不能保证语言运行时、编解码和系统事件中的全部副本可擦除。

## 当前桌面与目标检查

每批输入前组合核查当前事实：

- `CGSession` 的当前用户、控制台和登录完成状态，以及 AppKit 受保护数据可用状态；系统锁屏键明确为真时拒绝。
- 实际前台必须是活动、可见的普通应用；拒绝 loginwindow、SecurityAgent 等系统登录或授权应用。
- 获批可执行文件、进程创建身份、系统焦点、应用焦点和捕获的 AX 控件一致；窗口及控件提供者属于同一目标进程。
- 控件为启用且有焦点的安全文本框，公开声明值可写；窗口未最小化，控件几何位于可见窗口和显示器范围内，修饰键已释放。

当前 macOS 在未锁定会话可能省略 `CGSSessionScreenIsLocked`。缺键本身不证明已解锁；实现结合上述现场会话、前台及 AX 所属关系决定是否可填。该锁屏键不是公开稳定 API 的保证，真实锁屏、快速用户切换与睡眠场景仍需系统验收。睡眠、屏幕休眠、会话失活和受保护数据不可用通知只使旧目标失效，恢复通知不会恢复租约。

目标属性缺失、超时、权限变化或提供者归属不明均停止输入。最后复核到系统投递之间仍有竞态，定向事件不构成原子焦点锁，也不承诺防止获批程序或同用户进程主动泄露凭据。

## 结果与验证范围

沿用 `checking`、`sent`、`refused`、`partial`、`unknown`。Mac 的 `sent` 表示事件已提交系统，不证明目标完整接收或登录成功。已放行批次回复丢失视为未知；部分或未知后查询原操作，不自动重试或换操作 ID 重填。恢复仍按公共合同由用户确认，历史与备份不恢复输入目标、连接或授权。

已验证范围是从开发环境启动的隔离、ad-hoc 签名产物：沙盒合成主程序与真实 helper 完成私有 XPC 通信；helper 无提示返回实际权限状态；AppKit `NSSecureTextField` 收到两批包含中文及 emoji 的完整合成字符串；普通 `NSTextField` 被拒绝且保持空白。只有合成目标读取自身假数据作比对。控制器检查另覆盖批次防重放、目标变化、超时、断连、部分及未知结果，封装检查覆盖签名和沙盒保持。

可复现入口：

```sh
python3 scripts/qa/check-macos-focused-controller.py
python3 scripts/qa/check-macos-focused-xpc.py
python3 scripts/qa/check-macos-focused-xpc.py --synthetic-target
python3 scripts/qa/check-macos-focused-xpc.py --plain-target
```

后两条会短时激活临时合成窗口；所有临时 App/helper 在检查后移除，小型回执保留于被 Git 忽略的 `build/macos-adaptation/`。

正式安装包独立启动后的 TCC 归属、换签名后的许可保持、Chrome/WebKit 密码框、锁屏及快速用户切换尚未验收。开发环境 helper 的 `ready` 不能替正式安装授权，也不能扩大为所有浏览器或应用均支持。构建回执中的能力启用表示代码与封装已接通，系统验收状态仍单独记录。
