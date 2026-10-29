# Mac 示例界面候选 · 2026-10-29

本轮交付入口与当前状态以 [#62 顶部](https://github.com/ShiJiJS/agent-info-manage/issues/62)为准。本页只提供本机启动指引和检查边界，取代继续自动扩展开发范围的历史排期。

源码：`e6ac4fa3dac8a056384149c8312fdd23fbc06a09`，分支 `codex/zhiyu-macos`。固定应用：`/Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app`。

双击该应用，或在终端运行：

```bash
open /Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app
```

需要从源码重建并启动时，在仓库根运行 `./scripts/dev-macos.sh preview`。窗口标题为“知予 · 界面预览·示例数据”。这是独立身份、沙盒内的 ARM64 示例预览；不打开正式资料库，不请求 Keychain、通知或真实 hooks。保存、批准、恢复和设置修改只作用于本次示例会话，重启恢复样例。

| 模块 | 实现及本轮主路径 | 正式验收 |
| --- | --- | --- |
| U01 外壳 | 五个主入口、明暗往返、Cocoa 退出/关闭 | #62 仍 10/12、OPEN |
| U02 信息库 | 查找、详情、关联返回、保存失败保稿及重试 | #63 仍 6/7、OPEN |
| U03 内容类型 | 文件版本确认/取消；复用同产品源码的凭据材料、两个尺寸/明暗检查 | #64 仍 6/7、OPEN |
| U04 插件 | 示例包预览/安装、新建资料、模板采用并保留字段身份 | #65 仍 6/7、OPEN |
| U05 审批 | 减选、批准、同源授权历史中的准确范围 | #66 仍 7/8、OPEN |
| U06 提案与历史 | 确认、结果、当前资料与返回原提案 | #67 仍 6/7、OPEN |
| U07 设置 | 修改失败保留选择、重试、八个入口及返回 | #68 仍 7/8、OPEN |

当前严格分析、57项相关检查、一次同窗口原生连续路径、两种Cocoa正常退出通过。原生路径使用真实Flutter渲染和Widget输入；不等于真实OS键盘、中文输入法或触控板已通过。当前信息库Profile检查有20条功能断言，使用同一产品源码；运行时滚动条模式由overlay切为legacy，原生、Dart和实际0/11px占宽按实时状态核对。

有限剩余：

1. 七项UI的完整S5：其余同条件视觉/基线/阴影、完整正常速度动效复核。局部几何、原速片段抽样和时序通过不替代整票验收；Profile仍有超帧预算记录。
2. 在同一候选集中配合真实⌘编辑、中文输入法、触控板、窗口焦点及辅助功能。当前未使用computer use，也未要求新的系统密码操作。
3. #69后续拆分真实资料库、持久化、平台服务与交付；当前示例结果不代表这些能力已经接入。Windows继续后置。

候选交付后结束本轮。原规格、失败证据和未通过项保留，不关闭七张UI票。检查与产物摘要见[本轮证据](evidence/zhiyu-round09/u01/macos/r5/checkpoint.json)。
