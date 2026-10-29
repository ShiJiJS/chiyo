## 当前收尾结果（2026-10-30）

产品源码`728d5126`，隔离检查`560b8327`，文档/证据`59a0a51c`，独立分支`codex/zhiyu-macos`。[有限清单](https://github.com/ShiJiJS/agent-info-manage/blob/59a0a51c/docs/development/zhiyu-macos-acceptance-checklist.md) · [本轮证据](https://github.com/ShiJiJS/agent-info-manage/tree/59a0a51c/docs/development/evidence/zhiyu-round09/u01/macos/r10) · [同一轮本人验收步骤](https://github.com/ShiJiJS/agent-info-manage/blob/59a0a51c/docs/development/zhiyu-macos-owner-check.md)。

**清零判断：本轮限定清单内，已知自主开发项和自动检查缺项均为0；整体验收未清零。** D01/D02示例界面已完成；M01-S1连续目视及H01–H03仍需本人，没有用周期截图或Widget事件冒充真实输入/连续视觉。

| ID | 当前结果 |
| --- | --- |
| V01 / D01 | 内置服务器1.1更新横幅有宿主合成目录来源，经版本/新旧摘要核对后复用原差异预览及确认；取消不更新、失败可重试、未知查原回执。安装后横幅消失，新建增加维护负责人，旧资料保留1.0快照；外部JSON仍不能覆盖builtin。 |
| V02 / D02 | 已补导入known_hosts的选择、纯格式校验、文件/摘要/主机/指纹核对、明确确认、失败保留、未知冻结与原回执、结果读回。仅用隔离合成公钥文件夹具；不调用系统文件选择器、生产信任配置或真实服务。逐台确认和凭据许可不变化。 |
| V03–V07 | R9审批/提案/历史/设置布局、基线、语义色和共用阴影的通过范围保留；未变模块不重复开发或整票重新宣告通过。 |
| M01 | 本轮新流程原生6.5秒/183次采样，最大间隙87ms；原速播放抽样已查看。共享六组原生时序按未变token/控件源码复用，保留R9超帧记录。连续主观画面仍差M01-S1。 |

相关范围61项、新流程两尺寸明暗/200%共12项、隔离守卫和严格分析通过，计数重叠不相加。最终产品树在一个Mac原生窗口完成10阶段断言，录制只覆盖D01/D02；Widget输入不代表实际OS输入，系统置前请求返回1的限制保留。普通预览已恢复。

本人只需集中一轮：H01在示例编辑框测试⌘A/C/V/X/Z和中文组合/提交；H02触控板滚动及⌘Tab离开/返回；M01-S1连续看菜单、弹窗和详情的短过渡/快速关闭；H03实际Tab/Enter/Escape及本人系统辅助功能。具体入口和通过表现见上方验收单，可全程取消；无需新的系统密码、Keychain、通知授权或真实主机。

固定预览仍为`/Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app`，独立沙盒arm64示例身份，普通入口`lib/preview_main.dart`。本轮清理过程帧/缓存副本，只保留一个固定App与必要证据，`.local/`和既有Release符号保留。

原勾选/依赖不变：#62为10/12，#63/#64/#65/#67各6/7，#66/#68各7/8，全部OPEN。#69真实服务未启动，Windows后置；没有computer use、子Agent、正式资料、系统信任配置、秘密、hooks或真实执行。D01/D02的示例结果不代表生产接入完成。

---

## 上轮已交付：Mac 完整界面候选（2026-10-29 流程试验）

用户已授权先调整现有 tickets、继续开发并观察交付效果，本轮不修改技能。本节取代下文历史“下一步”的排期；原规格、安全隔离、正式完成条件与未通过记录保留。

**本轮目标**：在现有 `codex/zhiyu-macos` 上交付一个可启动、可连续体验 U01–U07 的固定 Mac 示例界面候选，并明确已实现、未验收和需要本人配合的内容。候选交付不等于七张 UI 票正式验收通过，也不等于接入真实服务。

**实现进度**：固定U01–U07示例界面候选已交付，准确入口、版本与模块表见下节。
**验收进度**：候选主要路径检查通过；完整S5与实际OS输入仍未全部通过。七张UI票保持OPEN，原勾选不因候选交付改变。

### 已交付候选

**本轮候选交付已完成；七张UI票的正式验收尚未完成。** 源码 `e6ac4fa3dac8a056384149c8312fdd23fbc06a09`，分支 `codex/zhiyu-macos`；文档/证据提交 `8fb849a8c5e979fafa7f98edfa82167ac1016c58`。普通预览已恢复并成功启动，留给用户体验。

固定本机入口：`/Users/jiangxinyi/Documents/Project/agent-info/apps/desktop/build/macos/Build/Products/Debug/info_desktop.app`。双击，或运行 `open` 加此路径；源码启动为仓库根的 `./scripts/dev-macos.sh preview`。这是独立沙盒ARM64示例身份，窗口标记“界面预览·示例数据”；不接正式资料库、Keychain、通知或真实hooks，重启重置会话样例。[启动指引](https://github.com/ShiJiJS/agent-info-manage/blob/8fb849a8c5e979fafa7f98edfa82167ac1016c58/docs/development/zhiyu-macos-candidate.md) · [检查与失败证据](https://github.com/ShiJiJS/agent-info-manage/tree/8fb849a8c5e979fafa7f98edfa82167ac1016c58/docs/development/evidence/zhiyu-round09/u01/macos/r5)。

| 模块 | 实现与候选主路径 | 正式验收/阻塞 |
| --- | --- | --- |
| U01 / #62 | 五入口、明暗往返、菜单退出/关闭窗口 | 10/12，完整S5及OS输入未过 |
| U02 / #63 | 查找、详情、关联返回、编辑失败保稿/重试 | 6/7，完整S5及OS输入未过 |
| U03 / #64 | 文件版本确认/取消；同产品源码的凭据材料版本及两尺寸/明暗 | 6/7，完整S5及OS输入未过 |
| U04 / #65 | 插件预览/安装、新建、采用模板并保持字段身份 | 6/7，完整S5及OS输入未过 |
| U05 / #66 | 减选、批准、同源历史准确范围 | 7/8，完整S5及OS输入未过 |
| U06 / #67 | 提案确认、结果、当前资料与返回 | 6/7，完整S5及OS输入未过 |
| U07 / #68 | 设置失败保选择/重试、八入口及返回 | 7/8，完整S5及OS输入未过 |

当前严格分析、57项相关检查、同一窗口1次连续原生流程/8个阶段断言、两种Cocoa正常退出均通过；普通入口`open`返回0。信息库Profile完整20条功能断言通过，复用未受影响的版本/材料检查。Profile取证问题（AOT键盘推导、文本客户端、运行中滚动条模式变化）与产品问题分开记录，失败不记为通过；没有据此放宽时限/占宽门槛。

原生流程为真实Flutter渲染与Widget输入。八个阶段、原时间轴联系图及浏览器原速播放抽样已查看；4.959s片段116帧，最大间隙141ms，只证明已观察主路径可用，不能接受全部短过渡。原始Profile也仍有超帧预算记录。

**有限剩余**：① 七项UI完整S5，包括其余同条件视觉/基线/阴影、完整正常速度动效复核；② 同一候选上的本人⌘编辑、中文输入法、触控板、窗口焦点和辅助功能；③ #69后续真实持久化/平台服务/交付，Windows后置。候选不因这些后续项自动扩展；本轮到此结束，正式OPEN状态、原完成条件和依赖不变。


### 本轮完成条件

1. 一个固定路径的可运行 Mac ARM64 示例预览，记录源码版本、启动方式及数据隔离；复用现有产物，不影响正式资料库或 Windows。
2. 在该候选上走通已有的六组路径：主入口/明暗/退出；查找→详情→关联返回→编辑失败保稿/重试；文件与凭据版本确认/取消；插件预览/采用；审批及提案→结果/历史；设置修改/失败/返回。修复阻止这些路径完成的缺陷，复用未受影响的有效检查。
3. 对本轮实际改动做必要定向回归，候选统一做一次主路径检查；正常速度观察可用性，完整 S5 缺项和系统输入单独列明。已要求的严格最终验收仍保留，不通过更名宣告通过。
4. 在本 issue 顶部给出七模块的“实现/验收/阻塞”简表、候选入口、检查结果和有限剩余清单；交付给用户体验。达到以上条件后结束本轮，不继续自动扩展动效测量、测试设施或真实后台。

### 执行边界

开发前置按实际所需接口/控件判断；不能仅因上游还缺集中验收而重复或停止已有页面收尾。原生依赖关系保留为正式关票次序。#69仍承接真实功能阶段，本轮只交付候选和已有接入缺口，不提前开发新后台。

与上述路径直接相关的缺陷属于本轮；独立增强进入原有待办。若验证工具失败，区分产品问题和取证问题，选能回答当前问题的已有方法；没有足够证据就标记受阻，不升级成无边界测试工程，也不记为通过。

本轮当前进度以本 issue 顶部为准；各票只维护自身结果，仓库记录链接到这里。历史正文和证据继续可追溯，不在多处追加同一篇开发日志。

---

## 原规格与历史记录

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

