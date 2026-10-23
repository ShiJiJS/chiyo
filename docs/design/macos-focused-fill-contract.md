# Mac 本机焦点填充：接口与原生实现准备（#51）

2026-10-23。状态：已补公共身份模型；原生输入方案尚未全部冻结，Mac能力仍关闭。
沿用 [ADR0012](../adr/0012-local-focused-credential-fill.md)、
[填充合同](local-focused-fill-contract.md)与
[#51](https://github.com/ShiJiJS/agent-info-manage/issues/51)。
这份记录不表示系统权限、真实密码框、锁屏输入保护或发行包已经验收。

## 已确定的公共 Interface

继续使用现有 `FocusedFillDiscoveryDriver` / `PreparedFocusedFill`，Mac提供另一种Adapter。
调用者不学习AX控件、XPC、PID、窗口或权限处理；技术复杂性集中在原生填充Module内。
Seam仍是核心服务与原生驱动之间，审批/存储不直接调用系统输入方法。

| 调用 | 约束 |
| --- | --- |
| `inspectTarget()` | 只返回ready/refused及公开应用身份；不发输入、不申请权限、不保留焦点、不读取控件值/标题/网页正文。 |
| `prepare(application)` | 核对已批应用、真实前台及密码控件；固定本次进程创建身份和控件引用；不读取或发送秘密。 |
| `sendBatch(units)` | 核心先持久登记输入放行并重新核查授权，再传不超过16个UTF-16单元；原生每批再次核对同一目标，不排队等未来焦点。 |
| `close()` | 关闭该次原生租约；失联/重连不能恢复旧控件、重发已放行批次或继续输入到新目标。 |

私密会话、操作幂等、固定15/30分钟截止、撤销、轮换、根会话结束、部分/未知后的
主人恢复确认，继续由已有Core流程管理。Mac不增加另一套授权，也不借普通字段许可
取得凭据。每次操作只使用一个字符串凭据，控制字符和过长内容沿用现有限制。

## 应用身份模型

传输字段仍是 `executable` 和64位十六进制 `sha256`，不加Agent可指定的PID或句柄。

- Windows继续接受绝对盘符路径及 `.exe`，保持原有大小写比较和原JSON形状。
- Mac接受绝对POSIX文件路径，保留Unicode、空格和字面大小写；不把路径强制转小写。
  拒绝相对路径、URL、`~`、根目录、尾部斜线及双斜线开头。目录/符号链接最终由
  本机检查器解析成实际规范文件，再检查字节摘要；不能仅凭字符串当作可填充程序。
- 两种路径身份不能互相匹配。本机检查器先拒绝另一平台的路径，不能在Windows
  当前盘符下解释POSIX路径，也不能在Mac工作目录下解释Windows路径。
- 准备输入时还需核对实际前台进程的程序路径、创建时间及文件身份；公开SHA不是
  运行中进程/动态依赖的强隔离保证。网址仅供主人判断，不证明浏览器域名。

未来Mac请求形状如下；它只描述模型，当前生产入口仍因能力关闭而不能执行：

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

本轮没有提升SQLCipher库/备份格式。当前持久化格式的填充身份仍限Windows，写入、
重开及备份校验共同拒绝未标记的Mac填充记录。公共模型可序列化Mac身份，不等于
当前库可以写它。启用原生Mac填充前，必须另做明确格式迁移、旧读取器拒绝和双端
备份兼容核查；不能让旧Windows读取器把新历史当坏库，或依赖较宽的JSON解析器
偷偷扩展已发布格式。

## 原生执行方案审查

Apple将跨应用辅助功能访问列为App Sandbox不兼容活动；给当前沙盒Runner直接增加
AX调用或给继承沙盒的worker增加代码，不能据此声称已经获得跨应用控制能力。
主应用和现有worker的沙盒继续保留。
[Apple App Sandbox说明](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)。

候选方案是在App内放置仅负责填充的私有XPC Module，让它持有系统控制许可；主应用
继续负责库、授权和审计。Apple的XPC模型支持独立权限和进程生命周期，但不能据此
推断本项目ad-hoc签名、辅助功能许可归属或权限持久化已可用。这些必须用准确签名
产物确认。当前没有打包、启动或自动注册新的helper，没有改变现有entitlements。
[Apple XPC结构与生命周期](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)。

候选XPC实现必须满足：

1. 仅接受所属App的私有连接，并核对连接者内核身份及构建绑定身份；不提供外部可命名
   的通用控制入口，不接受任意helper路径、目标PID或任意事件类型。
   当前SDK的 `NSXPCConnection.setCodeSigningRequirement` 和
   `NSXPCListener.setConnectionCodeSigningRequirement` 从macOS13可用，低于本项目14.0
   最低目标；候选实现应在处理消息前设置准确代码要求，设置失败就拒绝连接。
   不能把客户端自报PID、相同名称或字符串bundle identifier当作代码身份核查。
2. 每个准备好的目标是短时且只属于该连接的租约。连接失效、父进程消失、超时或
   helper重启都丢弃租约；不在重新连通后自动重放输入。
3. 秘密只以有界内存批次传递，不经命令参数、环境变量、普通剪贴板、临时明文文件
   或日志。helper不打开信息库，不持有数据库密钥，不返回控件值、字符数或按键缓冲。
4. 每个登录用户串行输入，忙碌时拒绝，不等待未知未来焦点。原生AX消息和单次输入
   调用有明确期限；超时不阻塞审批界面，状态未知先查原操作。

当前选择是继续评估这个方案，而不是先移除整个App沙盒或引入常驻特权服务。
当helper身份、权限归属及桌面就绪依据仍不明确时，不能接通秘密发送。

## 系统权限与真实目标

启动、发现及普通申请只进行无提示检查。`AXIsProcessTrustedWithOptions` 的提示选项
和 `CGRequestPostEventAccess` 只允许在主人明确操作的设置/验收入口调用；没有许可
就返回拒绝，不循环触发系统决定。
[AX可信检查](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)、
[输入权限检查](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess%28%29)。
升级后许可是否保持按准确产物实测，不能承诺允许一次永久适用于后续任意签名。

拟支持的首批类型是AppKit安全文本框，之后再逐个评估WebKit/Chromium实际密码框。
这是待验证类型列表，当前支持矩阵仍为空。普通文本框、终端、系统登录/授权窗口、
无法归属到已批应用的跨进程提供者，都不能因外观像密码框而被接受。

每批输入前需要同时核对：

- 本机GUI会话、用户、控制台与可输入状态均可确定；没有确定结论时拒绝。
- 已批程序与本次捕获的进程创建身份保持一致；实际前台应用未变化。
- 系统焦点、应用焦点与原先捕获的AX密码控件一致；控件启用、可编辑且可见。
- 目标窗口、控件归属、几何与未最小化/隐藏状态可核验；修饰键已释放。
- 公开AX属性缺失、超时、权限变化或提供者归属不明时，停止，不降级普通输入框。

生产实现不能读取密码值验证，不主动清空、点击登录、激活别的应用或更改用户焦点。
应先让Agent/主人准备目标，再后台请求输入。即使采用定向的系统输入方法，也不能
把最后复核到系统投递之间的竞态写成原子锁定。

### 尚未解决的桌面就绪依据

当前SDK的 `CGSession.h` 公开了用户、控制台及登录完成信息；这些字段没有给出一个
可直接等同于“该图形会话已解锁”的公开布尔值。AppKit还提供
`isProtectedDataAvailable`，它描述受保护数据状态，不能仅凭名称替代所有屏幕锁定、
快速切换用户和屏幕共享的要求。Apple DTS也明确区分了受保护数据与锁屏通知的语义；
对后续追问还没有完整保证，不能把论坛提问者自己的观测当作官方承诺。
[Apple DTS讨论](https://developer.apple.com/forums/thread/850327)。

因此，`onConsole && loginDone`、缺少未公开锁屏键、一次旧通知或单个成功取值，都
不能单独让实现认定就绪。私有锁屏键/未公开分布式通知不是本合同的默认依据。
接通输入前要明确支持系统/会话条件、启动时如何取得当前状态、每批如何重查，以及
锁屏/切用户/睡眠/共享下拒绝的实际证据；不能把这一项省略为普通焦点测试。

## 结果与启用顺序

继续使用checking、sent、refused、partial、unknown。Mac如果使用无接收计数的投递
方法，sent最多描述已提交系统输入事件，不能沿用“Windows接受完整输入”的更强含义，
也不能表示密码框完整接收或登录成功。放行后回执丢失返回unknown；已有批次发送后
目标变化返回partial/unknown，不把它改成零输入。公共结果仍没有秘密、输入长度、
命令退出码或文件清理状态。

| 阶段 | 当前结果 | 后续门槛 |
| --- | --- | --- |
| 公共身份模型和本机文件检查 | 本轮实现 | 保持Windows线协议与大小写语义；Mac路径精确匹配。 |
| 持久化兼容保护 | 本轮实现 | 当前格式继续拒绝Mac填充记录；正式能力前增加格式迁移。 |
| 原生实现方案 | 有具体候选，尚未冻结全部依据 | 核对私有XPC签名/权限归属、连接验证及桌面就绪依据。 |
| 目标/投递实现 | 未接通 | 先按已审查合同落实现，再用合成目标验收，不访问个人密码。 |
| 正式宣告 | 关闭 | 实现、签名产物、权限/锁屏/目标证据齐备后再更新capabilities、Skill和UI。 |

本轮只做源码/SDK及文档审查，没有系统权限调用、helper启动、屏幕操作或原生输入。
按#51原要求，第一条复合验收尚不能勾选，不能把公共模型和元数据回归算真实填充完成。
