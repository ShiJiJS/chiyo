# 原生后台填写完整 App 验收

对应 [#144](https://github.com/ShiJiJS/chiyo/issues/144) 和[公共合同](../design/native-background-fill-contract.md)。只使用独立构建目录的合成接收程序、临时加密资料库、临时 HTTPS 服务和独立 App 配置。此脚本不连接真实资料库，不操作用户应用。

入口为 `apps/desktop/integration_test/native_background_fill_test.dart`。必须等统一 native 分支装配两端真实 adapter 后运行；未装配时 native targets 明确失败，不能用注入的假 driver 或 focus shim 通过此项。

在平台正常的 Flutter 集成测试命令上提供以下 dart-define：

- `NATIVE_FILL_CLI`：同一提交构建的公开 chiyo/chiyo.exe 绝对路径。
- `NATIVE_FILL_RECEIVER`：`build/` 下合成接收程序的实际可执行文件路径，Mac 使用 bundle 内实际程序。
- `NATIVE_FILL_KIND`：Mac 为 `appkit_secure_text`；Windows 分别为 `win32_password`、`winforms_password`、`wpf_password` 各跑一次。
- `NATIVE_FILL_EVIDENCE`：本工作树 `build/` 下本次公开回执目录。

未给参数时此项显式跳过，不视为真实平台通过。不运行旧全套验收，不构建或替换 #143 的冻结安装包。

## 合成接收程序接口

平台会话提供对应原生控件的 receiver；该接口仅用于测试，不进入产品 helper wire。进程参数为 `--native-fill-fixture --nonce NONCE --kind KIND`。应创建可见且不激活的原生根窗口及密码框；窗口标题必须包含 nonce。不能读取或操作其他 App。标准输出只写 JSON-lines，不输出密码或字节。

1. 就绪回执：`{"state":"ready","nonce":"...","appId":"...","windowTitle":"...","fieldIdentifier":"...","controlKind":"..."}`。fieldIdentifier 对应已知 AXIdentifier/AutomationId，须能在 helper 的可见字段描述中找到。
2. 私有 stdin `{"command":"expect","bytes":[...]}`：只设置接收程序内部的比较目标、清空测试观察计数，不向控件写值；返回 `{"state":"armed"}`。密码不在程序参数、普通 CLI 输出或证据文件中。
3. `{"command":"check"}`：接收程序只检查自己的合成控件，返回 `{"state":"checked","matched":false,"active":false,"focusedSinceArmed":false}`。matched 表示值是否准确相等；后两项观察目标 App 是否被激活、目标是否在 expect 后获得过键盘焦点。不得返回字段值。
4. `{"command":"rebuild"}`：销毁并重建原密码控件，保留同名标识和窗口说明；返回 `{"state":"rebuilt"}`。旧目标必须失效，不可按名字恢复旧批准。
5. stdin EOF 退出并清理合成接收程序。若退出迟滞，测试只终止自己启动的 receiver 进程，不终止用户 App。

现有平台探针若使用不同测试接口，可由平台会话适配上述 receiver 外壳；生产 NativeFillDriver 的接口和 wire 不因此变化。

## 验证事实

脚本实际启动 StorageDesktopLauncher，公开 CLI 发现唯一描述匹配且真实程序路径一致的控件，提交 native 申请，经与 App 相同的 owner 审批 HTTP 端点作出决定，再从 CLI 执行。审批界面的实际显示与按钮另由 `native_background_fill_approval_widget_test.dart` 覆盖。

批准前和批准后、执行前，接收程序均须报告未收到密码。执行后真实 setter 的逐项回执为 sent，接收程序准确匹配包含首尾空格、中文和 emoji 的合成密码，期间没有激活或获得键盘焦点。重复操作编号不得新增执行记录；控件重建后，旧批准的执行返回目标失效且不能领取新材料。公共输出扫描拒绝密码、私密聊天证明、设备凭证、管理 Token 及 privateProof。证据文件仅保留公开编号、结果和布尔见证，不保留密码或配置。

公开 sent 仅表示 setter 接受；接收程序的 matched 是合成夹具的独立验真，不扩大生产 helper 对任意 App 业务识别的承诺。
