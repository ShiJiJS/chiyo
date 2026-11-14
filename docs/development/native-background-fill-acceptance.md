# 原生后台填写完整 App 验收

对应 [#144](https://github.com/ShiJiJS/chiyo/issues/144) 和[公共合同](../design/native-background-fill-contract.md)。只使用合成资料、临时加密资料库和专属 App 配置，不连接真实资料库或操作用户文档。验收使用同一候选源码构建的正式驱动、helper 和公开 CLI。

## 通用控件改造的验收要求

本轮按 [ADR0033](../adr/0033-native-fill-by-control-capability.md) 验收。2026-11-14 用户明确收回第三方软件业务测试要求：只使用自制测试程序，不下载、安装或启动其他软件。生产 helper 不得登记测试应用的名称、路径、摘要、版本或控件编号来使测试通过。证据注明源码提交、系统版本、真实驱动/helper、夹具、场景及结果；测试清单不参与运行资格判断。

- Mac：至少两个未在生产代码登记的不同应用身份的 AppKit 夹具，核对后台填写与原目标。
- Windows：既有 Win32/WinForms/WPF 夹具回归；增加一个不匹配原三家族名称但提供原生 UIA 密码写值能力的 provider。
- 两端覆盖缺少 AXIdentifier/AutomationId 但描述明确的目标，以及歧义、只读、禁用、网页、目标重建、进程/helper 重启、权限不足、批准过期或撤销等拒绝用例。证明拒绝时未调用 setter；不更改用户系统权限来布置用例。
- 前台应用、焦点、鼠标和剪贴板观察覆盖 setter 开始至结束，观察器先做正反校准。后台、遮挡、最小化和隐藏分别记录，不拼接调用前后的稳定片段冒充完整证据。
- setter 返回 sent 与合成控件收到正确值分别记录，不推断第三方软件业务成功，不读回真实密码或自动重试 unknown。

平台夹具通过后，公共 CLI → AppHost → 批准 → 可信 helper → 控件的链路还需使用同一整合提交验证。隔离候选可以验收；本轮不替换用户正在用的 App，不发布 Release。

## Windows：合成控件完整链路

入口为 [native_background_fill_test.dart](../../apps/desktop/integration_test/native_background_fill_test.dart)，使用合成 receiver 和临时 HTTPS 服务。Windows 的 Win32、WinForms、WPF 和通用 UIA provider 夹具必须各运行一次；新版公开 controlKind 统一为 `windows_uia_password`，夹具实现家族另行选择。不能用注入的假 driver 或 focus shim 通过此项。

在 Windows 正常的 Flutter 集成测试命令上提供以下 dart-define：

- `NATIVE_FILL_CLI`：同一提交构建的公开 chiyo/chiyo.exe 绝对路径。
- `NATIVE_FILL_RECEIVER`：`build/` 下对应 Win32、WinForms 或 WPF 合成接收程序的实际可执行文件路径。
- `NATIVE_FILL_KIND`：新版公开目标类型，Windows 为 `windows_uia_password`，Mac 为 `macos_ax_password`。夹具家族选择须与公开类型分开，由同提交 harness 和 receiver 的参数约定说明，不能把所有目标标成 WPF 来通过。
- `NATIVE_FILL_EVIDENCE`：本工作树 `build/` 下本次公开回执目录。

未给参数时此项显式跳过，不视为真实平台通过。清理等待正常 quit 的资源关闭 Future；测试只延后最终 OS 进程终止，以便 Flutter 返回回执，原生驱动仍由正式工厂加载。

## Windows 合成接收程序接口

receiver 提供对应原生控件；该接口仅用于测试，不进入产品 helper wire。进程参数为 `--native-fill-fixture --nonce NONCE --kind KIND`。应创建可见且不激活的原生根窗口及密码框；窗口标题必须包含 nonce。不能读取或操作其他 App。标准输出只写 JSON-lines，不输出密码或字节。

1. 就绪回执：`{"state":"ready","nonce":"...","appId":"...","windowTitle":"...","fieldIdentifier":"...","controlKind":"..."}`。有开发者标识时，fieldIdentifier 对应 AXIdentifier/AutomationId；缺失标识的专项用例使用明确的可见标签和分组说明选择目标，不为通过验收而给控件补编号。harness 与 receiver 须在同一提交约定该用例的描述匹配字段。
2. 私有 stdin `{"command":"expect","bytes":[...]}`：只设置接收程序内部的比较目标、清空测试观察计数，不向控件写值；返回 `{"state":"armed"}`。密码不在程序参数、普通 CLI 输出或证据文件中。
3. `{"command":"check"}`：接收程序只检查自己的合成控件，返回 `{"state":"checked","matched":false,"active":false,"focusedSinceArmed":false}`。matched 表示值是否准确相等；后两项观察目标 App 是否被激活、目标是否在 expect 后获得过键盘焦点。不得返回字段值。
4. `{"command":"rebuild"}`：销毁并重建原密码控件，保留同名标识和窗口说明；返回 `{"state":"rebuilt"}`。旧目标必须失效，不可按名字恢复旧批准。
5. stdin EOF 退出并清理合成接收程序。若退出迟滞，测试只终止自己启动的 receiver 进程，不终止用户 App。

使用不同测试接口的探针须适配上述 receiver 外壳；生产 NativeFillDriver 的接口和 wire 不因此变化。

## Windows 验证事实

脚本实际启动 StorageDesktopLauncher，公开 CLI 发现唯一描述匹配且真实程序路径一致的控件，提交 native 申请，经与 App 相同的 owner 审批 HTTP 端点作出决定，再从 CLI 执行。审批界面的实际显示与按钮另由 `native_background_fill_approval_widget_test.dart` 覆盖。

批准前和批准后、执行前，接收程序均须报告未收到密码。执行后真实 setter 的逐项回执为 sent，接收程序准确匹配包含首尾空格、中文和 emoji 的合成密码，期间没有激活或获得键盘焦点。重复操作编号不得新增执行记录；控件重建后，旧批准的执行返回目标失效且不能领取新材料。公共输出扫描拒绝密码、私密聊天证明、设备凭证、管理 Token 及 privateProof。证据文件仅保留公开编号、结果和布尔见证，不保留密码或配置。

公开 sent 仅表示 setter 接受；接收程序的 matched 是合成夹具的独立验真，不扩大生产 helper 对任意 App 业务识别的承诺。

## 历史参考：Mac 普通主入口与归档实用工具

下述是既有 AU 业务流程记录，本轮不执行。新版使用生产通用 AX 路径与 AppKit receiver 验证整值与目标失效，不能注入宽松测试 profile，也不能给测试程序新增兼容名单。历史真实软件结果不代表通用路径已在任意应用中验证。

使用普通 `lib/main.dart` App、同源 AOT `chiyo`、本次唯一的 `--connection-profile <profileName>`，按 [Mac 产品完整流程](../../apps/desktop/macos/native_background/README.md#普通产品构建和后续完整流程) 和 [macos-native-product-flow.py](../../scripts/qa/macos-native-product-flow.py) 执行：

1. `prepare` 在本工作树 `build/` 下创建合成 ZIP 和唯一 profileName、credentialName；在普通 App 的该命名 profile 中通过正常 UI 新建合成库及凭据。
2. 用真实 AU 打开该 ZIP。`request` 使用公开 CLI 发现唯一合成目标并申请，在普通 App 的真实审批界面核对并批准；批准后尚未填写。
3. 完成独立观察器校准后运行一次 `run`，用 `status` 确认 `b1: sent` 及有效的后台观察。超时或 unknown 后只查询原操作，不重放 setter 或更换操作编号。
4. 结束观察区间后，独立在 AU 提交，再用 `business` 核对解压内容与 SHA-256。sent 本身不代表解压成功。

签名、helper 权限归属、命名 profile 的定位及正常退出清理要求均以 Mac 说明为准；脚本不伪造批准，不读取密码控件值。
