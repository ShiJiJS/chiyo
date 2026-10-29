阶段：前端界面预览。仅使用独立示例数据，完成不代表真实功能已接入。领取前检查本票原生阻塞关系。

2026-10-26最新指令：**持续推进Mac开发，按现有tickets完成能做的改造。Mac ARM64优先，Windows适配后置**。从#62已保留的实机输入缺口和#63已有代码继续，不从零重做；实机输入集中到固定候选，未验项保持开放。改动留在独立codex/zhiyu-macos分支，不运行Windows CI，不使用子Agent或computer use。界面完成后由#69拆分真实服务和Mac交付。[当前计划](https://github.com/ShiJiJS/agent-info-manage/blob/fc8f71e3e900d599689ffc878e4fc8f5db462358/docs/planning/zhiyu-round09/macos-continuation.md)。

当前进度：**10/12、OPEN**。Mac外壳、共享控件和可替换示例接口已实现；产品代码保持`ca45fa58`的弹窗焦点修复。当前检查后继为`9d8ccfec4e6175709394a7c530f3c56f287088a1`，仅修改检查工具。14项编码、24项相关检查、严格分析、基础原生1项/10条、信息库原生1项/20条及固定普通arm64构建通过。完整S5、正常速度动效与真实系统输入仍待验。

数据仍为集中虚构资料，未接真实库或新后台。[当前实施与历史记录](https://github.com/ShiJiJS/agent-info-manage/blob/fc8f71e3e900d599689ffc878e4fc8f5db462358/docs/development/zhiyu-macos-foundation.md) · [r4证据与检查范围](https://github.com/ShiJiJS/agent-info-manage/tree/fc8f71e3e900d599689ffc878e4fc8f5db462358/docs/development/evidence/zhiyu-round09/u01/macos/r4)。

## 要做什么

做出可运行的知予窗口和五个主页面入口，统一明暗主题、按钮、菜单、提示、弹窗、滚动和动画。

## 规格与原型依据

[S5 视觉与动画](https://github.com/ShiJiJS/agent-info-manage/blob/5a561ad24b4f617bca054364bb5c9cc529b2caf7/docs/specs/zhiyu-round09/05-fidelity.md)、[S6-C06 示例与正式数据边界](https://github.com/ShiJiJS/agent-info-manage/blob/5a561ad24b4f617bca054364bb5c9cc529b2caf7/docs/specs/zhiyu-round09/06-architecture-and-delivery.md)、[先界面再接功能](https://github.com/ShiJiJS/agent-info-manage/blob/2346dc1dfa0b52550f028bb56596085cfb026327/docs/planning/zhiyu-round09/frontend-first.md)。参照状态：R01、R03、R13。

## 完成条件

- [x] 从现有Mac适配与前端后继整合开发基线，保留PR #61及Mac原生修正；在独立codex/zhiyu-macos分支记录准确来源，不修改Windows分支。
- [x] 原生窗口启动同样隔离示例模式：不初始化正式目录授权存储或恢复bookmark、不触发Keychain/个人配置/hooks/通知/执行；退出后可清理预览专用状态。
- [ ] Mac标题标记“知予 · 界面预览·示例数据”，系统菜单、查找/设置导航和正常退出通过最小预览接缝可用；保留⌘编辑、中文组合输入、触控板与辅助功能支持。
- [x] Mac系统字体/PingFang同文本参照、截图及原生检查命令可重现；移除检查工具的Windows前提，保留原平台证据；只保留必要预览及证据产物。

- [x] 将原T01最小前端准备并入本票：约定查询/选中/详情/返回、操作结果和错误结构，保留现有正式入口与行为；不开发新的数据库、全套真实服务适配或大范围重构。
- [x] 主题切换可在预览会话中生效；只提供明亮和黑暗两种主题；顶栏、字体、间距、图标和动效按冻结原型，不等待真实偏好存储。
- [x] 提供一个独立示例数据入口和集中状态来源；页面通过可替换接口查询/操作，同一组件将用于后续正式服务。
- [x] 菜单键盘操作、单侧展开、提示关闭、滚动轨道、焦点恢复及快速开关均可实际操作。
- [x] 使用正式Flutter组件与控制器；从界面入口走到示例结果，正常、空数据、等待和失败状态可重现。不是另一套HTML或截图展示。
- [ ] 1440×900、1280×800、明暗主题、200%文字、键盘和本票相关动效完成S5对照；提交实际Mac Flutter截图/录屏，注明示例数据、Mac字体和输入检查范围。
- [x] 预览不连接真实资料库、秘密、hooks或系统执行能力；数据集中维护并可重置，未来通过同一接口换真实服务，不靠逐页isMock分支。
- [x] 记录页面需要的数据、操作和失败结果，并完成相关前端检查；未接后台内容汇总给F01，不以示例成功宣称真实功能完成。

## 怎么演示和检查

启动带“界面预览·示例数据”标记的Mac程序，切换五个主入口和明暗主题；演示按钮悬停/按下/焦点、贴边菜单翻向、弹窗滚动和关闭后焦点返回，再触发加载失败并恢复。

在Mac原生预览的明暗主题和两个指定内容尺寸下对照S5平台参考，提交实际Flutter截图及正常速度交互录屏；Windows历史图不能代替本票Mac结果。

## 执行边界

用户明确要求先整套前端，因此本票不被新后台接口、数据库或CLI实现阻塞。只先确定页面所需数据合同，现有技术栈和安全规则保留；无子Agent、无服务器同步。界面反馈仅属于独立预览，不进入正式发布的成功分支。

## 开始位置

没有其他issue前置；已在codex/zhiyu-macos整合已有Mac适配、前端及规划分支后继，当前继续补齐自动可完成的S5检查，真正系统输入留到固定候选集中完成。保留PR #61与Mac修正，不修改main/Windows分支，不等待Windows专项或新后台。

## 固定参考版本

[整套规格](https://github.com/ShiJiJS/agent-info-manage/blob/5a561ad24b4f617bca054364bb5c9cc529b2caf7/docs/specs/zhiyu-round09/README.md) · [冻结原型与使用说明](https://github.com/ShiJiJS/agent-info-manage/tree/7fc2072d18dc56731ea71f07926d9b49d0539f66/docs/design/prototypes/round-09-zhiyu) · [前端先行顺序](https://github.com/ShiJiJS/agent-info-manage/blob/2346dc1dfa0b52550f028bb56596085cfb026327/docs/planning/zhiyu-round09/frontend-first.md)

冻结原型保留原始固定版本；依照本次Mac规划版本的S5核对样式和动画、S6核对组件职责与示例/真实数据替换；不以“编译通过”代替界面验证。

<!-- zhiyu-round09-ui-first-20261025:U01 -->

## 完成界面后接着看

[后续阶段与待拆分内容 · #69](https://github.com/ShiJiJS/agent-info-manage/issues/69)。只汇总未接真实服务的范围；全部前端完成后再由该票重新拆分，不直接照搬旧20项草稿。

<!-- zhiyu-round09-mac-first-20261026:U01 -->

## 当前Mac进展与剩余项（r4）

Mac截图现与录制共用采样锁，应用内保存无损RGBA源，退出后由宿主编码PNG；47张实际PNG逐张解码后与源像素摘要一致，保留原尺寸、文件名和透明像素。源帧/PNG摘要、资源上限、实际间隙及捕获开销均有记录。基础录制122帧/5.418s，间隙中位34ms、最大137ms；信息库92帧/8.400s，中位59ms、最大469ms。这些是不同负载下的观测，不是稳定性能基准。

六组原生时序本轮满足原有20ms门槛，但首次属性读取延迟仍最高118.331ms，post-frame回调也不代表OS已呈现像素。[r3的三组时序失败](https://github.com/ShiJiJS/agent-info-manage/blob/a97dc468a574d1300ad159a6f1a274869c7ec972/docs/development/evidence/zhiyu-round09/u01/macos/r3/checkpoint.json)继续保留，不能用当前一次通过宣告完整动效稳定。

1. 隔离Debug/JIT、首次绘制及GPU读回影响，补适合性能判断的证据；保持一个固定预览App，不靠放宽时限或缩放画面通过。
2. 完成其余控件状态、基线/阴影和完整正常速度动效的S5对照；静态图、构建、局部几何或一次时序通过不替代整票验收。
3. 在同一个固定候选集中完成真实⌘编辑、中文输入法、触控板及辅助功能。Widget注入与系统输入分开记录，未验项不勾选。

12项完成条件、原生前置关系与F01顺序保持。Mac独立分支；本轮无computer use、子Agent、个人资料、Keychain、通知、真实hooks、Windows CI或额外App/dSYM副本。历次详细进展统一查上述实施记录和固定证据，原Windows评论保留其历史范围。
