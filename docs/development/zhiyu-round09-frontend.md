# 知予 Round09 前端实施记录

本轮按[已发布计划](../planning/zhiyu-round09/README.md)先完成7项正式Flutter界面。使用独立示例数据，后续真实功能由[#69](https://github.com/ShiJiJS/agent-info-manage/issues/69)重新拆分。2026-10-26起改为Mac优先、Windows适配后置；无子Agent、无服务器同步。

**2026-10-26最新指令：仅整理tickets和文档，暂不继续开发。** 此前Mac首轮准备已保存；未提交实现原样保留，不计为新的验收结论。 当前分支codex/zhiyu-macos，#62准备与证据见[Mac外壳实施记录](zhiyu-macos-foundation.md)。下文Windows检查点保留历史范围。 [Mac接手计划](../planning/zhiyu-round09/macos-continuation.md)规定后续基线与顺序。 [交接说明](handoffs/zhiyu-frontend-20261026.md)列出当前源码、证据、限制和接手顺序。

## 当前任务

| 任务 | 进度 |
| --- | --- |
| [#62 外壳和通用控件](https://github.com/ShiJiJS/agent-info-manage/issues/62) | 2026-10-26暂停：基础实现、顶栏几何及原生集成检查已推进；最终视觉/动画验收未完成；Mac原生隔离、字体/菜单/检查工具及Mac验收待实施 |
| [#63 三栏信息库](https://github.com/ShiJiJS/agent-info-manage/issues/63) | 等待#62 |
| [#64 档案、文档、文件、凭据](https://github.com/ShiJiJS/agent-info-manage/issues/64) | 等待#63 |
| [#65 插件与旧资料套模板](https://github.com/ShiJiJS/agent-info-manage/issues/65) | 等待#62 |
| [#66 访问审批](https://github.com/ShiJiJS/agent-info-manage/issues/66) | 等待#62 |
| [#67 提案与历史](https://github.com/ShiJiJS/agent-info-manage/issues/67) | 等待#62 |
| [#68 全局设置](https://github.com/ShiJiJS/agent-info-manage/issues/68) | 等待#62 |

## #62已经实现什么（Windows检查点）

- 独立入口为`apps/desktop/lib/preview_main.dart`。它只创建示例数据来源和新界面，不进入正式启动器、数据库、本机服务、hooks、通知或凭据执行。当前库和安装目录均未替换。这描述Dart入口及当时Windows范围；Mac原生MainFlutterWindow仍有目录授权存储初始化，须在#62补齐隔离后才能作同样保证。
- `workspace`模块中的App/Shell通过调用者提供的页面和数据来源组装；它们不引用示例实现。集中示例来源仅在预览组装入口创建，支持正常、空资料、持续等待、读取失败和重置。
- 控制器保留页面与稳定资料身份、返回位置和明暗外观；晚到的旧读取结果不能覆盖新结果，关闭后不再通知UI。失败不会退回示例成功分支。
- 复用现有颜色、按钮、选择器、锚定浮层、滚动和交互宿主。在同一基础上增加Round09明暗颜色、系统字栈、150ms按钮反馈/1px按下位移、120ms菜单和180ms弹窗/详情/反馈过渡。
- 选中和悬停只产生一个背景；菜单从触发器一侧展开，支持方向键、Enter和Escape；正文与滚动轨道分别占位。弹窗正文独立滚动，标题及底部操作保留；Escape和关闭入口尊重表单的离开保护。
- 修复新增动效过程中发现的旧触发器失效访问和关闭后焦点恢复问题。旧入口未切到新页面，相关既有公共控件测试继续通过。
- Windows字体从本机已安装文件注册，不随软件分发字体。原生启动和离屏截图使用同一字体加载方法；实际字体/几何仍需最终对照，不能凭已加载字体推定一致。

## Windows历史重现方法（Mac命令由#62补齐）

在桌面包目录执行`flutter run -d windows --no-pub --target lib/preview_main.dart`。窗口标题明确标记“知予 · 界面预览·示例数据”。点击右上设计说明可以切明暗、改变读取状态和重置数据；这个面板也用于基础控件检查。

当前五个主入口先连接同一个基础状态检查面板。它是#62的临时承载；三栏信息库、资料详情、审批、提案、历史和设置的完整业务界面分别属于#63–#68，尚不能作为完成页面交付。

依赖沿用现有锁定版本。若本机PUB镜像与锁文件URL不同，按仓库检查脚本的既有方式临时转换镜像地址并在finally还原锁文件；本次没有升级依赖或提交镜像URL变化。

相关检查：

- `flutter analyze --no-pub --fatal-infos`。
- `flutter test --no-pub test/workspace_controller_test.dart test/zhiyu_preview_test.dart test/desktop_controls_test.dart test/library_ux_controls_test.dart --reporter json`。异步/浮层相关检查连续执行3次。
- `flutter test --no-pub tool/capture_zhiyu_foundation.dart --reporter expanded`。使用真实共享Widget和Windows字体生成1440×900、1280×800、明暗各套的窗口、弹窗与菜单截图；这是离屏证据。

最终运行结果及源码摘要见[本次检查记录](evidence/zhiyu-round09/u01/checks-summary.json)。原生基础检查见[截图](evidence/zhiyu-round09/u01/native-smoke.png)和[范围记录](evidence/zhiyu-round09/u01/native-smoke.json)。

## 原生检查的实际范围

已编译并启动独立Windows调试预览，实际打开设计说明弹窗、使用Escape关闭；没有启动正式资料库。检查中收到用户输入提示后重新观察，没有沿用旧坐标继续点击，随后通过Flutter的q正常退出预览，并重置computer-use会话。

原生截图记录的是开发中的基础控件弹窗；它早于本检查点最后的顶栏响应式/表单保护调整。它只能证明原生窗口基本运行，不代表最后源码的完整视觉验收，不替代固定源码重启后的最终取证。

## Windows暂停时剩余项（保留历史，当前顺序见Mac接手计划）

本次暂停收尾新增：[r2检查点](evidence/zhiyu-round09/u01/r2/checkpoint.json)。顶栏的20组对照已达到0.0078125逻辑像素偏差；原生集成覆盖当前DPR=2、200%文字和减少动画，已生成原始时钟GIF。下面旧检查点提出的事项以交接说明的最新状态为准，不能把记录生成等同动态审阅完成。

1. 读取冻结原型最终计算样式，对照顶栏的实际文字和图标边界，完成两个桌面尺寸的几何检查。当前不能声称已经达到S5的≤2逻辑像素目标；不靠改小字体或修改原型迁就实现。
2. 在固定源码重新启动原生预览，补齐菜单、提示、快速开关、焦点、放大文字及减少动画的检查；原生系统DPI和文字放大分别记录。
3. 录制并以正常速度查看实际Flutter交互，补齐过渡时长/位移和取消行为证据。静态截图、构建通过、离屏测试不能替代录屏。
4. 自检剩余视觉问题后才关闭#62，再开始其后继票。无独立子Agent评审，遵循用户要求由本Agent自检。

本记录不关闭任何既有验收票，不宣称整套前端或真实功能完成。
