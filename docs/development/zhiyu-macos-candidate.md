# Mac 示例界面候选 · 2026-10-30

当前产品源码为`728d5126`，本轮已补齐内置插件更新提示和隔离合成主机文件导入界面。布局/字形修正及既有通过项继续复用。结果与准确剩余见[有限验收清单](zhiyu-macos-acceptance-checklist.md)及[r10证据](evidence/zhiyu-round09/u01/macos/r10/checkpoint.json)。[普通选择器](zhiyu-macos-menu-selectors.md)、[表单焦点](zhiyu-macos-form-contexts.md)的通过范围继续保留。七张UI正式验收仍未完成。

本轮交付入口与当前状态以 [#62 顶部](https://github.com/ShiJiJS/agent-info-manage/issues/62)为准。本页只提供本机启动指引和检查边界，取代继续自动扩展开发范围的历史排期。

源码：`728d5126`，分支 `codex/zhiyu-macos`。固定应用：`/Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app`。

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

原生路径使用真实Flutter渲染和Widget输入；不等于真实OS键盘、中文输入法或触控板已通过。首候选`e6ac4fa3`的57项检查、两种Cocoa正常退出及信息库Profile20条断言保留为历史范围；本轮的页面回归、标题基线、原生连续路径及共享动效Profile结果分别标注源码，不能把历史截图当新版证据。

有限剩余：

1. 本轮限定的自主开发/自动检查缺项已清零，D01/D02隔离示例界面完成。M01-S1短过渡连续目视仍未完成：新录制最大间隙87ms，不能把原速抽样当完整目视。共享Profile时序复用不代表无超帧，原失败记录保留。
2. H01–H03真实⌘编辑/中文输入法、触控板/窗口焦点、辅助功能。已和M01-S1合并到[一轮本人验收单](zhiyu-macos-owner-check.md)，不要求新的系统密码，也不等待本人配合才完成自主项。
3. #69后续拆分真实资料库、持久化、平台服务与交付；当前示例结果不代表这些能力已经接入。Windows继续后置。

原规格、失败证据和未通过项保留，不关闭七张UI票。当前检查与产物摘要见[r10证据](evidence/zhiyu-round09/u01/macos/r10/checkpoint.json)；r5/r9按原源码保留历史范围。
