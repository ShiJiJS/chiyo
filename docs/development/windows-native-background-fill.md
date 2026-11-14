# Windows 原生后台填写

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

AppHost 持有一个常驻驱动，启动时传入 `nativeDriver` 并设置 `ownsNativeDriver: true`。
单个 CLI 连接不能拥有或关闭它。宿主退出时幂等 `dispose` 立即终止自有 helper，
不等待可能卡住的 setter；已发送操作仍按未知结果处理。helper 重启后所有旧快照失效，
只有显式新发现能创建新 incarnation。

本目录可独立构建。父级 runner 的 helper 身份通道、同包安装规则、manifest 和
App 启动工厂必须一起接入后才能宣告平台能力可用；仅构建本目录不会自动启用产品入口。
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
