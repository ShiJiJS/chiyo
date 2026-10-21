# Mac 实际应用退出与重开（#46）

2026-10-21，独立 Mac 分支，QA 源码
`19914f3ad342652a14bb21faa3d3c2bc07a647a0`。普通 Flutter binding、Release
沙盒应用、生产 Cocoa channel 与实际 SQLCipher；合成内存密钥与合成授权，
不打开生产资料库或 Keychain，不是最终交付包。
[原始日志、界面及字节摘要](evidence/macos-native-lifecycle-ui/verification.json)。

本轮实际操作结果：

| 操作 | 实际结果 |
| --- | --- |
| 红色关窗两次 | 均收到原生 `closeWindow`；首次关窗后原进程及服务仍在。CUA 随后读取应用会重新激活它，收到 `openApprovals`，不能据此声称点击了 Dock/状态栏。 |
| 应用菜单 `Quit info_desktop` | 实际原生菜单点击，收到 `quit`，Cocoa 正常退出 0。此菜单是应用菜单，不是右侧状态栏菜单。 |
| ⌘Q | CUA 原生按键触发 `quit`，Cocoa 正常退出 0。 |
| 设置→应用运行→完全退出 | 实际按钮打开确认，先选“继续运行”，原进程与服务仍可达；再次打开确认并选“完全退出”，正常退出 0。 |
| 每次退出后的独立进程重开 | 正文、历史中的允许读取及 `applicationClosed` 事实保留；原授权凭证拒绝。重开检查由测试代码执行，最后通过原生终止退出。 |

三个实际 UI 退出和三个恢复检查，共 **6 个应用进程退出 0**，每次关闭库恰好一次，
退出后对应监听端口均不可达；没有使用强杀收尾。7 个依赖/严格分析/构建/签名
步骤退出 0。日志没有 Flutter exception 文本；本入口未安装异常计数器，
不将文本扫描称为计数为零。152 个生产文件与固定产品基线 `01c1f14` 的原字节
一致，只改 QA 入口及驱动；源码副本仅修改 QA bundle identity。

驱动已删除专属合成库、私密关联、控制文件，注销测试应用并清除生成的 app、
dSYM 和 Flutter 编译缓存。没有改变保留的 #50 产品包。

## Mac 支持的控制入口

正常退出可使用应用菜单退出、⌘Q 或设置“完全退出”；红色关闭按钮走后台隐藏
路径，不等于结束授权服务。状态栏设计提供重新打开与完全退出，Dock 重开设计
走 `applicationShouldHandleReopen`，但这两个直接交互仍未在本轮验收。
状态栏不可用时应保留可达窗口，该故障条件也尚待原生联合验收。

当前 Mac CLI **不支持 `info app status` / `info app quit`**。本轮对保留的
`issue50-package-7` 实际 ARM64 CLI 分别运行，两者均退出 69 并返回
`{"controlVersion":1,"status":"unsupported_platform"}`，没有新增任意 PID
控制入口。二进制摘要及完整 stdout/stderr 见 `raw/mac-cli-control.json`。

## 验收边界与复跑

SystemUIServer 与 Dock 的 CUA 绑定均超时；不把它们当作对应功能失败，也不以
工具激活应用冒充点击了 Dock/状态栏。菜单截图不可取得，保留真实菜单 AX
文本；退出确认截图可取得且已查看。CUA 重激活意味着没有独立证明隐藏期间的
屏幕外观，因此本轮不勾选 #46 第一条复合条件。

尚需实际状态栏/Dock 重开、状态栏不可用回退、可见启动错误窗口、睡眠/唤醒及
期限跨越、#50 最终包联合验收。退出审计失败与运行中 worker 异常恢复的既有
证据另见 [生命周期验收](macos-lifecycle-recovery.md)，不与本轮进程数相加。
#46 保持 OPEN；本轮只使“Mac 控制方式明确且 Windows CLI 在 Mac 明确不支持”
这一条具备直接证据。

```bash
.tools/qa-python/bin/python scripts/qa/macos-lifecycle-ui.py \
  build/macos-adaptation/NEW_NATIVE_LIFECYCLE_UI
```

驱动依次等待实际 UI 操作，不写入退出标记、不注入 quit 代替前三个 UI 退出。
等待超时或异常清理会记录失败，不能计为正常退出。
