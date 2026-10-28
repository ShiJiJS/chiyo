阶段：前端界面预览。仅使用独立示例数据，完成不代表真实功能已接入。领取前检查本票原生阻塞关系。

2026-10-26最新指令：**持续推进Mac开发，按现有tickets完成能做的改造。Mac ARM64优先，Windows适配后置**。从#62已保留的实机输入缺口和#63已有代码继续，不从零重做；实机输入集中到固定候选，未验项保持开放。改动留在独立codex/zhiyu-macos分支，不运行Windows CI，不使用子Agent或computer use。界面完成后由#69拆分真实服务和Mac交付。[当前计划](https://github.com/ShiJiJS/agent-info-manage/blob/2346dc1dfa0b52550f028bb56596085cfb026327/docs/planning/zhiyu-round09/macos-continuation.md)。

当前进度：#62已推进到10/12，仍OPEN。共享查询/选中/详情/返回与保存合同已补齐，原生菜单、六组动效、两种真实窗口尺寸及明暗主题检查通过。实际⌘编辑、真实中文输入法、触控板和辅助功能仍待固定候选实机检查。[Mac实施记录](https://github.com/ShiJiJS/agent-info-manage/blob/cffc1754de2f743fd6c997c9f9f0b2fcb4a9408a/docs/development/zhiyu-macos-foundation.md) · [r2固定证据](https://github.com/ShiJiJS/agent-info-manage/blob/cffc1754de2f743fd6c997c9f9f0b2fcb4a9408a/docs/development/evidence/zhiyu-round09/u01/macos/r2/checkpoint.json)。Windows原收尾评论保留其历史范围。

实现已提交为8645c10b，证据与说明已推送到本Mac分支。数据仍为31条集中虚构资料，未接真实库或新后台；普通安装和个人Keychain未操作。

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

## 2026-10-26 Mac r1历史检查点

- 实现源码：[9cd5314e](https://github.com/ShiJiJS/agent-info-manage/commit/9cd5314e)。独立应用身份、原生服务隔离、实际窗口标题和菜单连接已落地；预览包不含执行worker。
- 当前源码严格分析通过；桌面296项通过、2项Windows专用条件跳过；预览/离屏6项通过（有范围重叠，不相加）；独立Mac原生集成1项通过。
- 两个指定尺寸、明暗外观，32组顶部几何对照最大偏差1.0078125逻辑像素。只覆盖顶部，不代表全部页面。实际preview_main入口已启动并由Flutter q退出0，普通安装未替换。
- r1时8/12条已勾选；最小查询/详情/操作结果合同尚需扩展（当前仅有外壳摘要与导航），原生窗口/实际输入、共享控件剩余状态和完整S5动态对照也继续待收尾。原生framebuffer与Widget输入不扩大为OS输入通过；录屏生成/抽帧检查不等于所有120/150/180ms时序已达标。
- 不运行Windows CI、不连接个人资料库、不发起Keychain或通知授权、不使用子Agent。此为r1时顺序；当前#63已接续这份实现并归档到Mac分支，不重复从零实现。

## Mac r2：数据合同与原生控件

- 实现源码8645c10b。查询不检索字段正文，凭据内容不进入通用详情/保存；全局过滤分组排序后分页，版本化保存、失败保稿、跨页变化通知和晚到读取保护均有检查。中文组合区与光标不会被共享刷新清空。
- 严格分析通过；桌面311项通过/2项Windows条件跳过在最终IME保护之前完成，最终影响范围16项通过。原生集成1项、4种离屏场景和Cocoa关闭/退出均通过；不同范围有重叠，不相加。
- 六组动效帧时钟均在原定20ms误差内，位移符合3/7/−3/1/6逻辑像素；实际NSWindow调整为1440×900、1280×800，各有明暗画面。原生Flutter/Widget输入与AppKit菜单分发不代表全局OS输入。
- 录屏已按原时钟保存并抽帧查看；顶部32组几何相对r1保持不变，最大参考差仍1.0078125逻辑像素。真实系统输入和完整S5关闭审计继续待验，保持10/12，不提前关闭本票。
- 当前按用户先改造、集中验证要求继续#63，原生依赖与未验记录保留；不把#62开放中的本人输入检查伪装成已完成。

<!-- zhiyu-shell-scaled-counts-u07-r7-20261028 -->

## Mac共享顶栏：200%计数修正

源码`edf42af293641771ff05670e1ec789ff9238c8af`修正固定20px徽标裁切，改为最小高度与内容收缩居中。两个视口/明暗/两种文字比例的8组检查通过，四位和两位计数完整；普通字号徽标20px、顶栏66px保持，1440明亮8组顶栏几何较旧Mac测量逐项差0，仅证明局部保持。

454项相关回归、严格分析和固定路径Mac arm64构建通过。当前隔离预览调用同一Cocoa菜单退出处理器、窗口performClose两条路径均正常exit0，随后恢复普通预览入口；没有实际⌘Q/IME输入结论。[完整合同与范围](https://github.com/ShiJiJS/agent-info-manage/blob/09107ab39d38ac9695ad127a9aa9b4e8ad47edee/docs/development/zhiyu-settings-contracts.md) · [r7检查、几何、图及Cocoa输出](https://github.com/ShiJiJS/agent-info-manage/tree/09107ab39d38ac9695ad127a9aa9b4e8ad47edee/docs/development/evidence/zhiyu-round09/u07/macos/r7)。

本票仍**10/12、OPEN**，勾选保持。完整S5、真实⌘编辑/中文输入法/触控板/辅助功能及正常速度审阅仍未完成。#68推进7/8后继续其他UI的S5差异，不据局部修正宣告产品完成。Mac独立分支、Windows后置，无computer use/子Agent/Windows CI/个人资料/系统权限；固定一个App，`.local/`不动。


<!-- zhiyu-overlay-u02-r14-62-20261029 -->

## U02 r14共用控件后继：浮层和关闭保护

源码`9d8aea71`补齐共用弹窗2px背景模糊、标题/关闭SVG/阴影颜色和详情19px图标/动作提示。Round09只播放入场，弹窗/菜单直接关闭，完成后归还焦点；旧主题退场和原有未知结果禁用关闭、PopScope、嵌套确认与减少动态效果保留。

22项定向、444项相关回归通过；仅移除冗余import后，严格分析、当前Mac原生1项（12条功能断言）及恢复普通预览入口的固定arm64构建通过。四组选择器/关闭外框最大差0.4046875px，比较器拒绝五种错误条件；原生DPR2的四组弹窗/关闭逻辑外框与Widget相同，未扩大为同DPR像素验收或OS输入。范围重叠，不相加。

当前原生GIF保留1倍原时钟（8692ms→8690ms），20帧采样稀疏，只查看限定画面，完整入场/流畅度和正常速度S5审阅仍开放。#62保持10/12，#63/#64保持6/7，均OPEN；原依赖、标签和评论不变。继续R05/R06等内容/表单、其他页、完整阴影/基线和动效，本人OS输入留固定候选；F01真实库/服务/交付仍后续。未用computer use、子Agent、个人资料、系统权限或Windows CI，只保留同一固定App和必要证据，过程帧核对Git blob/hash后清理。

[实施与准确范围](https://github.com/ShiJiJS/agent-info-manage/blob/c297f0b85a3b64ce1decc58e0b26b42f9bbe2c90/docs/development/zhiyu-macos-library.md) · [固定证据](https://github.com/ShiJiJS/agent-info-manage/blob/c297f0b85a3b64ce1decc58e0b26b42f9bbe2c90/docs/development/evidence/zhiyu-round09/u02/macos/r14/checkpoint.json) · [读图和录制限制](https://github.com/ShiJiJS/agent-info-manage/blob/c297f0b85a3b64ce1decc58e0b26b42f9bbe2c90/docs/development/evidence/zhiyu-round09/u02/macos/r14/visual-review.md)。


## Mac共享字段后继（U03 r13）

`2cd82ab5`在原Desktop controls/Round09主题接缝统一标签13px/500、标签到输入8px、输入内边距13/11px、字段外间隔12px；旧主题保持并有独立检查。凭据移除重复间隔，换选材料保留已有或手改引用（包括明确清空）。

39项定向、严格分析、500项相关回归、Mac原生1项/18条断言及固定普通arm64构建通过。八组共同单行指标最大差0.3984375px，原生一组两字段逻辑差0（DPR2/1区分）；200%实际布局另测，整张表单、完整S5/正常速度动效和真实OS输入未因此通过。复用[同一U03 r13证据](https://github.com/ShiJiJS/agent-info-manage/blob/f0d7910a593d5a3d2f5aa3a1ca786f6afe0bbabf/docs/development/evidence/zhiyu-round09/u03/macos/r13/checkpoint.json)及[共享接缝说明](https://github.com/ShiJiJS/agent-info-manage/blob/f0d7910a593d5a3d2f5aa3a1ca786f6afe0bbabf/docs/development/zhiyu-macos-foundation.md)，不复制产物。

本票保持 **10/12、OPEN**，本人⌘编辑/IME/触控板/辅助功能及完整S5缺口仍开放，全部原生依赖不变；#64保持6/7，F01等待七项UI。本轮无computer use、子Agent、个人资料、系统权限或Windows CI。


<!-- zhiyu-native-focus-recording-u01-r3-20261029 -->

## Mac r3：修复弹窗入场焦点，保留原生时序失败

源码`ca45fa5898ac59f7f62c192f38c209f521d443c0`修复触发按钮持有焦点并随模态禁用时，重开弹窗入场期间Escape无效。新增回归先在第1轮失败，内部自动焦点节点修复后连续3次关闭通过；不占Tab顺序，旧主题、PopScope和关闭后焦点归还保持。

严格分析、517项相关回归、10项编码检查和固定普通arm64预览构建通过。当前信息库原生1项/20条功能断言通过；基础原生9条功能检查完成，包括快速关闭、200%文字、减少动画及NSWindow两尺寸/明暗，但**基础原生整项仍失败**：弹窗243.055ms（目标180ms），菜单帧时钟138.888ms/墙钟77.577ms（目标120ms），反馈472.219ms/474.635ms（目标180ms）。保持20ms误差标准，不以稍后的一次通过替换已有失败。更早详情201.387ms的失败也保留；需隔离Debug首次绘制、布局、JIT和帧调度影响。

录制改为完整1440×900、比例1的无损RGBA/zlib源帧，宿主生成关键PNG/原速GIF；有缓冲/像素预算、真实间隙、捕获耗时、跳过次数和源帧摘要。当前信息库126帧/7.267s，间隔中位35ms、最大331ms；基础88帧/8.197s，中位59ms、最大480ms。同步PNG截图仍可能干扰基础录制，后续应移出交互阶段。各轮场景/负载不同，不作严格基准，亦不据采样密度接受完整短动效。

[源码](https://github.com/ShiJiJS/agent-info-manage/commit/ca45fa5898ac59f7f62c192f38c209f521d443c0) · [实施与失败范围](https://github.com/ShiJiJS/agent-info-manage/blob/a97dc468a574d1300ad159a6f1a274869c7ec972/docs/development/zhiyu-macos-foundation.md) · [检查点、完整时序、GIF、PNG和失败日志](https://github.com/ShiJiJS/agent-info-manage/tree/a97dc468a574d1300ad159a6f1a274869c7ec972/docs/development/evidence/zhiyu-round09/u01/macos/r3)。

仍**10/12、OPEN**，原生依赖和勾选保持。完整S5、正常速度动效、真实⌘编辑/中文输入法/触控板/辅助功能仍待验；其余UI门槛与F01前置关系保持。固定App恢复普通preview_main入口，核对后清理本轮原始中间帧；Mac独立分支，无computer use、子Agent、个人资料、Keychain、通知、真实hooks、Windows CI或App/dSYM副本。
