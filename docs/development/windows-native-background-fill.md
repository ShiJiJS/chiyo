# Windows 原生后台填写

设计更新（2026-11-14）：[ADR0033](../adr/0033-native-fill-by-control-capability.md) 已确定按实际 UIA 密码控件能力开放。当前实现没有逐应用允许名单，但下述三家族与 AutomationId 硬限制仍待按新合同解除；本页先保留现有实现及测试证据，不代表通用路径已经完成。

Windows 平台实现位于 `apps/desktop/windows/native_background_fill/`，Dart
适配器为 `apps/desktop/lib/windows_native_background_fill.dart`。它实现
[公共合同](../design/native-background-fill-contract.md) 中的 `NativeFillDriver`，
由 App 持有的常驻 helper 保存真实控件引用。`sent` 仅表示原生 setter 接受调用；
填写、提交和业务登录结果分别记录。

## 支持边界

| 控件 | 限定条件 |
| --- | --- |
| Win32 | `Win32` UIA provider、原生 `Edit`、`IsPassword`、可写 `ValuePattern` |
| WinForms | `WinForm` provider、`WindowsForms10.EDIT.*` 原生密码文本框 |
| WPF | `WPF` provider、`HwndWrapper[` 根窗口下的标准 `PasswordBox` |

控件必须具有可唯一解析的 AutomationId 路径。发现结果组合真实标签与该路径；
两个窗口的完整公开描述相同（含标题截断、控制字符规范化后的碰撞）时拒绝发现。
浏览器、Document 子树、已知 WebView/Electron 宿主及其他自绘 provider 不在支持范围。
进程必须属于同一用户与会话，完整性级别不能高于 helper；只支持已解锁的 Default 桌面。
锁屏、UAC 安全桌面与跨用户使用不支持。

后台、遮挡与最小化窗口受支持；隐藏根窗口拒绝。目标固定可执行文件的规范路径、
SHA256 和只读文件句柄，固定进程代际、窗口、UIA 对象及完整祖先身份。
控件或容器结构变化、销毁、重建、标题或标签变化、禁用、只读以及进程重启会使旧引用失效。
结构事件采用保守失效策略，普通 App 动态修改同一窗口其他子控件也可能要求重新发现并申请。
发现未用于申请的引用五分钟过期；已保留引用由释放、失效或宿主退出结束。

helper 使用窗口外的 MTA，显式关闭 UIA `AutoSetFocus`。唯一写入路径为
`ValuePattern.SetValue` 整值替换；不读取字段值，不调用聚焦、激活、键盘输入或剪贴板写入。
Win32/WinForms 在发送前用只读 `EM_GETLIMITTEXT` 检查标准 Edit 的声明上限；
这不是写入通道。输入须为合法 UTF-8，解码后不超过 4096 个 UTF-16 单元，
不接受空值、NUL、C0 控制字符或 DEL；保留空格、引号、反斜线和 Unicode。
WPF 的键入长度限制不等同于编程设置限制；标准夹具核对实际整值，不据此承诺其他 provider 行为。

原生检查与其他 App 的业务状态之间没有通用原子保证。setter 开始后的异常、超时或
helper 丢失均返回 `unknown/fill_unknown`，不重放，不用其他方式降级。每个执行票据只调用一次
setter；关闭票据保留原目标，下次获准操作使用新票据。跨 scope 共享同一物理控件的 busy，
公开引用、保留额度和释放行为仍各自隔离。

## 宿主与交付接入

`WindowsNativeFillDriver` 的 `helper` 身份必须来自 App 构建绑定的可信包路径与摘要，
不能由 Agent 请求、环境变量或用户任意配置提供。驱动在启动前后核验该身份，
通过继承的私有 stdin/stdout 管道启动 helper，并发送父进程及 helper 摘要的二进制握手。
helper 核对真实直接父进程，父进程结束或管道断开即退出；不监听公共端口或公开命名管道。
后续使用公共合同的有界长度帧。输出只含元数据及白名单事实，异常文本和 stderr 不返回给 Agent。
尽力清零可变材料缓冲区；Dart/WinRT 不可变字符串及目标 App 内存不承诺可验证清零。

App 接线通过 `package:info_desktop/bundled_windows_native_fill.dart` 的
`Future<WindowsNativeFillDriver> loadBundledWindowsNativeFill()` 取得驱动。
此工厂调用 `agent_info_manage/desktop` 通道的无参数 `nativeBackgroundFillHelper`，
核对构建绑定的身份、固定同目录文件名和实际字节，再完成私有握手；没有配置或环境查找。
身份、路径、字节或握手不可用返回安全的 `CredentialUseFailure('session_unavailable')`，
非 Windows 返回 `unsupported_capability`。可选参数仅是 Owner 测试注入点。

AppHost 持有一个常驻驱动，启动时传入 `nativeDriver` 并设置 `ownsNativeDriver: true`。
单个 CLI 连接不能拥有或关闭它。宿主退出时幂等 `dispose` 立即终止自有 helper，
不等待可能卡住的 setter；已发送操作仍按未知结果处理。helper 重启后所有旧快照失效，
只有显式新发现能创建新 incarnation。

工厂在失败时自行销毁已创建的 driver；工厂成功而 AppHost.start 失败时，调用方仍拥有
driver，必须在失败路径 dispose。AppHost.start 成功后才转移所有权。

本目录可独立构建。父 Windows CMake 构建并同目录安装 helper，按配置生成
`native-background-fill-identity/<CONFIG>/native_background_fill_identity.h` 与 `.sha256`；
摘要编入 runner，sidecar 仅用于构建/包装核对。产品 launcher 和包 manifest/验真规则
由各自接线维护者一起接入后才能宣告完整可用；仅构建本目录不会自动启用产品入口。
正式签名、打包和安装验收遵循 [Windows 交付](windows-delivery.md)。

## 可重复的合成检查

从仓库根目录，在可交互且已解锁的 Windows 桌面执行。需要 VS2022 C++ 工具链、
Windows SDK、系统 .NET Framework 4.8 和已按锁文件准备的桌面 Dart 依赖。
下例假定 `cmake` 与固定 SDK 的 `dart` 已加入当前进程 PATH；不需要修改用户 PATH。

```powershell
cmake -S apps/desktop/windows/native_background_fill -B build/native-background-windows/out -G 'Visual Studio 17 2022' -A x64 -DCHIYO_NATIVE_BACKGROUND_BUILD_BROKER=ON
cmake --build build/native-background-windows/out --config Release --target native_background_broker native_background_target_test
ctest --test-dir build/native-background-windows/out -C Release --output-on-failure

$nativeOut = (Resolve-Path build/native-background-windows/out).Path
dart --packages=apps/desktop/.dart_tool/package_config.json apps/desktop/windows/native_background_fill/tests/driver_live_check.dart "$nativeOut/Release/info-native-background-broker.exe" "$nativeOut/tests/Release/native_background_fixture.exe" "$nativeOut/tests/managed/native-managed-fixture.exe"
dart analyze apps/desktop/lib/windows_native_background_fill.dart apps/desktop/windows/native_background_fill/tests/driver_live_check.dart
```

可信 bundle 工厂的定向检查在 `apps/desktop` 下运行；测试 helper 只用于 Owner 测试，
产品工厂不读取该环境变量：

```powershell
$env:CHIYO_NATIVE_BUNDLE_TEST_HELPER = (Resolve-Path ../../build/native-background-windows/out/Release/info-native-background-broker.exe).Path
flutter test --no-pub test/bundled_windows_native_fill_test.dart test/bundled_focused_fill_test.dart
```

该检查覆盖无参数通道调用、真实私有握手、缺失/变更/越出同目录的 helper、错误身份与
不可用执行文件的安全失败，以及 driver 销毁后的拒绝；原焦点 bundle 检查一同回归。
没有显式提供测试 helper 时，真实握手用例跳过，不能宣称真实握手已通过。

公共 App→Host→CLI 审批 harness 使用同一组 fixture 的显式 JSON 模式，无需另建接收程序：

| NATIVE_FILL_KIND | NATIVE_FILL_RECEIVER（相对上述 out） |
| --- | --- |
| `win32_password` | `tests/Release/native_background_fixture.exe` |
| `winforms_password` | `tests/managed/native-managed-fixture.exe` |
| `wpf_password` | `tests/managed/native-managed-fixture.exe` |

三者接受 `--native-fill-fixture --nonce NONCE --kind KIND`，直接由当前 fixture 进程创建
控件，真实目标 exe 与 receiver 路径一致。JSONL `ready` 返回 nonce、含 nonce 的窗口标题、
appId、`fieldIdentifier:"101"` 和 controlKind；`expect` 只保留私有比较目标并清空焦点观察，
`check` 只返回匹配、激活和获得焦点的布尔值，`rebuild` 重建同名控件，EOF 正常退出。
完整字段与运行参数以 [公共验收合同](native-background-fill-acceptance.md) 为准。
未传该模式时保留平台定向检查使用的旧文本协议；两者都仅为合成测试，不进入生产 helper wire。

原生检查包括三类夹具的整值替换、内部焦点变化、遮挡/最小化、隐藏拒绝、失效、
进程代际、身份摘要、保留及单票据行为。可用 `ctest -R native_background_limits`
单独重跑新增长度边界。Dart 检查使用真实 helper 管道，覆盖公共快照、scope、busy、
批准回调、释放、格式拒绝、丢失回复、停止与重启；最后一个参数可限定
`Win32`、`WinForms` 或 `WPF`。

前台观察先通过实际切换另一个自有测试窗口做负校准，再做稳定正校准；测量有效的前台/
焦点快照、WinEvent、1ms 采样、鼠标位置与剪贴板序号。持续输入检查使用前台夹具内
控件定向 `WM_CHAR` surrogate，不能作为物理键盘、全局输入注入或任意第三方 App 并发输入的验收。
fixture 中的激活、输入、读取假值与提交仅用于测试布置或 oracle，不参与生产填写。

## 真实软件兼容性核对

已用官方 [7-Zip 下载页](https://www.7-zip.org/download.html) 的 26.06 x64 GUI
“添加到压缩包”对话框核对标准 Win32 密码框与确认框，AutomationId 分别为 `120`、`121`。
核对使用官方 `7zr` 解出安装包中的文件，未运行安装器或修改 PATH。
随机 Unicode 合成密码在后台、完全遮挡和最小化三种场景都经本实现发送；随后单独提交创建
合成加密包，CLI 通过私有 stdin 使用同一密码校验成功、错误密码失败。
填写测量期间已校准前台/焦点保持稳定，鼠标、剪贴板未变，控件定向输入 surrogate 保留。
这项兼容性记录只覆盖该版本的上述控件，不代表所有 7-Zip 模式或其他应用均可用。

真实软件检查脚本、下载文件、压缩包和详细结果是一次性任务证据，放在被忽略的 `build/`，
不作为产品依赖。具体提交、运行结果与后续集成进度记录在 [#144](https://github.com/ShiJiJS/chiyo/issues/144)。

## 普通 main 候选的业务验收准备

`scripts/qa/windows-native-product-flow.py` 分阶段驱动公开 CLI，复用交付会话已验真的
同一冻结提交候选，不另编普通 main。先运行
`python -m unittest discover -s scripts/qa -p test_windows_native_product_flow.py -v`。

`prepare <本工作树build下的新QA目录> --receiver <已核验的build内7zG.exe>` 创建合成输入、
唯一 profile/凭据名称和 APPDATA、LOCALAPPDATA 子目录。只把返回的两个目录作为
本次 App 与 CLI 子进程的环境；不更改用户环境。以 `--connection-profile <profileName>`
启动候选 `app/info_desktop.exe`，在真实 UI 创建独立本地库及唯一字符串凭据，
公开测试值为 `Synthetic-Zip-42!`。通过已核验的 7-Zip 打开该新压缩包的压缩对话框。

`request <QA目录> --candidate-root <交付候选AgentInfoManage目录> --source-commit <冻结40位SHA> --connection-directory <QA目录/appdata/Chiyo/online/profiles/profileName>`
核对候选来源、必要载荷字节与 runner 摘要绑定，再走 doctor、credentials、targets、request。
同窗 AutomationId 120/121 两项复用该合成凭据；通过普通 App 真实审批 UI 批准 b1、b2。
脚本不调用 Owner API、不改数据库状态，也不代替界面批准。

独立前台/焦点观察器校准后开始测量，`run <QA目录>` 先持久记录单次发送标记，再执行
公开 fill run；超时或未知后只能 `status <QA目录>`，不能再次 run 或换 operation ID。
状态须为 filled、b1/b2 均 sent 且独立观察保持。测量结束后单独在 7-Zip 提交压缩，
`business <QA目录>` 经私有 stdin 验证正确密码成功、错误密码失败，并解出合成文件比较字节和哈希。
脚本仅有准备/保护性自检通过时不能宣称产品端到端已通过；实际候选、批准、操作和业务结果须另记 #144。
