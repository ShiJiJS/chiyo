# Mac预览：移除演示入口

2026-10-30，产品源码`447e9801`，分支`codex/zhiyu-macos`。用户确认申请由AI发起，主人只审批和管理；不需要另外的演示入口或模式。[反馈逐项记录](../planning/zhiyu-round09/owner-preview-feedback.md)保留审阅基线与实施范围。

已移除主人侧“申请使用”及发起表单、顶栏设计说明测试面板、手工生成申请/使用结果/提案/整理结果、推进到期/改会话状态、故障/规模切换、重置、固定测试候选选择器，以及模拟停止后的“恢复预览运行”。普通App没有隐藏开关、替代演示菜单或运行时演示模式。

正常的已有申请查看、审批/拒绝/撤销、凭据新建/更换/停用/版本/记录、资料和分类管理、提案审阅、插件更新影响核对、通知测试、备份和运行设置仍保留。未接入的本机文件/材料服务明确不可用；文件打开和另存不会返回虚构成功。确认完全退出调用既有Cocoa退出接缝；退出失败的正常重试保留，不恢复旧授权。

自动测试直接准备虚构状态；固定候选负例及共享控件检查面板仅在`test/support/`，普通入口`lib/preview_main.dart`不导入测试目录。旧的测试面板专用用例已移除；审批测试改由Agent来源提交申请，再从正常凭据详情进入同一审批。新增加的默认App检查没有注入测试选择器，覆盖无演示入口、正常管理、Agent申请→主人审批/撤销、未接入服务提示及原生退出调用。

检查范围：

- 38份相关桌面测试：340项通过、4项既有条件跳过。包括默认App路径、管理/审批/提案/历史/设置、明暗/大字及隔离守卫。旧测试依赖被删按钮导致的初次失败，在迁移到直接准备状态后已解决；最终完整命令重新通过。
- `flutter analyze --no-pub --fatal-infos`通过。
- 同一固定目录的ARM64普通预览构建通过；210份lib/Runner源码与上述提交逐字节相符。
- 增量构建留下旧的App.framework资源签名。重新封装该框架和外层App后，`codesign --verify --deep --strict`通过，原沙盒entitlements保持相同。属于本机ad-hoc预览，不宣称公证发布。
- 普通`open`启动成功，观察到固定路径进程。仅一份App，没有CLI worker或新建App副本；既有Release符号未改动。

固定App：`/Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app`。窗口仍标记“知予 · 界面预览·示例数据”，重启恢复样例；真实资料库、备份/文件/Agent系统服务仍待接入。本轮没有computer use、Windows修改/CI、Keychain、通知授权或真实凭据执行，也没有新增连续目视/OS输入/完整S5通过结论。

[产物与检查证据](evidence/zhiyu-round09/owner-cleanup/app.json)记录签名、内核摘要、启动进程与检查计数；同目录保留最终测试、分析、构建及源码摘要。GitHub原勾选、状态和依赖不因这次修改被关闭或重新定义。

GitHub #1/#62/#64/#68已同步用户确认的边界及本次源码/检查范围；正文精确回读，原勾选保持，见[回读记录](evidence/zhiyu-round09/owner-cleanup/tracker-readback.json)。浏览器工作页已结束。只保留上述必要文本证据和同一固定App，已清理本轮临时日志与tracker编辑副本，未生成新的App或dSYM副本。
