# Round09 GitHub发布清单

2026-10-26已将原8张票调整为Mac优先、Windows适配后置，并完成GitHub回读核验。最初文档在`codex/zhiyu-mac-plan`；随后已整合到独立`codex/zhiyu-macos`并保存首轮Mac准备。最新指令仅调整tickets和文档，暂不继续开发。当前阶段安排见[Mac接手计划](macos-continuation.md)，同步结果见下方记录。

2026-10-25已完成发布和回读核验：**7张前端任务 + 1张后续规划票，共8张**。旧T01–T20不发布；最小前端准备并入U01，其余由F01在界面完成后重新拆分。

规格、票据内容和冻结原型的固定引用版本：[7fc2072d](https://github.com/ShiJiJS/agent-info-manage/commit/7fc2072d18dc56731ea71f07926d9b49d0539f66)。已推送分支codex/zhiyu-round09-plan，主分支及正式软件未修改。

| 本地编号 | GitHub任务 | 直接前置 |
| --- | --- | --- |
| U01 | [#62 知予前端 U01：软件外壳、明暗外观与通用控件](https://github.com/ShiJiJS/agent-info-manage/issues/62) | 无 |
| U02 | [#63 知予前端 U02：三栏信息库与服务器、应用资料界面](https://github.com/ShiJiJS/agent-info-manage/issues/63) | [#62](https://github.com/ShiJiJS/agent-info-manage/issues/62) |
| U03 | [#64 知予前端 U03：个人档案、文档、文件与凭据界面](https://github.com/ShiJiJS/agent-info-manage/issues/64) | [#63](https://github.com/ShiJiJS/agent-info-manage/issues/63) |
| U04 | [#65 知予前端 U04：插件管理、专属设置与旧资料采用模板界面](https://github.com/ShiJiJS/agent-info-manage/issues/65) | [#62](https://github.com/ShiJiJS/agent-info-manage/issues/62) |
| U05 | [#66 知予前端 U05：普通信息与凭据使用的访问审批界面](https://github.com/ShiJiJS/agent-info-manage/issues/66) | [#62](https://github.com/ShiJiJS/agent-info-manage/issues/62) |
| U06 | [#67 知予前端 U06：录入提案与授权历史界面](https://github.com/ShiJiJS/agent-info-manage/issues/67) | [#62](https://github.com/ShiJiJS/agent-info-manage/issues/62) |
| U07 | [#68 知予前端 U07：全局设置界面](https://github.com/ShiJiJS/agent-info-manage/issues/68) | [#62](https://github.com/ShiJiJS/agent-info-manage/issues/62) |
| F01 | [#69 知予后续规划 F01：界面完成后拆分真实功能、测试与 Mac 交付](https://github.com/ShiJiJS/agent-info-manage/issues/69) | [#64](https://github.com/ShiJiJS/agent-info-manage/issues/64)、[#65](https://github.com/ShiJiJS/agent-info-manage/issues/65)、[#66](https://github.com/ShiJiJS/agent-info-manage/issues/66)、[#67](https://github.com/ShiJiJS/agent-info-manage/issues/67)、[#68](https://github.com/ShiJiJS/agent-info-manage/issues/68) |

U01–U07已添加enhancement、ready-for-agent；领取时按原生依赖判断前置是否完成。F01只有documentation标签，等待全部前端完成后继续规划，不是当前后台实现任务。恢复开发后的首项是U01（#62）的Mac接手准备；本轮不启动开发。

## 2026-10-25原始发布核验

- 8张issue均为OPEN，标题、完整正文和标签回读一致；没有重复发布旧20张任务或额外规格父票。
- 11条GitHub原生blocked-by关系与计划完全一致。图无环；F01传递等待全部7张前端票，U01不等待不存在的T01。
- 各前端票都链接#69后续规划入口；#69反向列出全部7张前端票。
- 8张票的74处Markdown链接均指向本仓库固定版本资料或真实issue，不依赖localhost和个人电脑路径。
- 40份本地规格/规划Markdown的185处相对链接在发布前已检查；本记录回填后再次检查新增链接和文档格式。
- 未修改或关闭旧父票、旧任务；未开发产品、未连接真实资料库、未启动子Agent或computer use。

发布记录只证明规划与tracker同步成功，不代表界面已经实现或Windows真实流程已验收。

## 2026-10-26 Mac优先调整与回读

- 原#62–#69的8份正文已更新，#69标题改为“知予后续规划 F01：界面完成后拆分真实功能、测试与 Mac 交付”；未新增票、未关闭票。
- 票内规格/计划链接固定到[c4750011](https://github.com/ShiJiJS/agent-info-manage/commit/c47500111daa2d836f3bce61a9ba6a59ec586173)，冻结原型继续使用原始7fc2072d版本；全部固定commit/path均存在。后继2632dfa6只将历史分类ADR引用与Mac分支对齐，避免接手合并时的文档冲突。
- #62新增两条基线整合、原生预览隔离、Mac标题/菜单/输入、字体和检查工具准备；保留Windows已实现/未验记录。#63–#68沿用原功能范围并使用Mac验收合同；#66明确真实填充关闭，#68采用Mac平台文案。
- #69继续等待全部UI完成，届时复用已有Mac能力和#44/#46/#47/#48/#50等票；#41剩余Windows回归、#45双机迁移、#51真实填充及其他Windows专项后置。旧票正文、完成条件、勾选和状态未改动。
- 通过已登录GitHub页面重新读取8份完整正文与标题，均与提交载荷逐字一致。8票仍OPEN；#62–#68保持enhancement/ready-for-agent，#69仅documentation；原评论数量和内容未改动。正文中的暂停说明优先于标签，不将ready-for-agent视为本次开始开发的授权。
- 原生Relationships逐票核对，#69展开全部5个前置；仍为表中的11条直接依赖，无新增或删除。
- 冻结原型15文件摘要全部保持，相关Markdown相对链接与格式检查通过；准确范围和正文摘要见[同步回执](macos-publication-20261026.json)。只运行文档检查和只读merge-tree，不把它们当作Mac构建或UI验收。
- main、Windows前端分支和原Mac适配工作区保持原检查点；仅推送独立规划分支。没有开发产品代码、启动原生应用、访问个人资料或运行Windows CI。临时同步材料在保存回执后清理。

## 最新指令回读：本轮只整理，不继续开发

- 原8张票已统一为Mac ARM64优先、Windows专项后置，并明确本轮暂停实现。#62保留8/12，#63–#68未开始，#69继续等待全部前端完成；没有新增或关闭任务。
- 已反映实际接手状态：`codex/zhiyu-macos`已整合两侧基线，已保存首轮Mac准备。未提交的实现原样保留，不写成新的通过结论，恢复时先审阅diff和未完成检查。
- 本轮规格和计划固定引用[5a561ad2](https://github.com/ShiJiJS/agent-info-manage/commit/5a561ad24b4f617bca054364bb5c9cc529b2caf7)；历史源码、原型和检查点引用保留。8份正文已逐字回读，标题、OPEN状态、标签、勾选和原评论均保持。
- GitHub完整Relationships及#69展开列表核对为原11条直接依赖；无环，#69传递等待全部7张界面票。只修改这8张票正文，旧Mac/Windows任务不改。
- 43份相关Markdown的219处相对链接和15个冻结原型文件摘要检查通过；18份原有源码/脚本改动逐字节未变，本轮提交仅含文档。没有构建、运行产品检查或Windows CI。
- [本轮同步回执](macos-scope-confirmation-20261026.json)记录正文摘要、状态、标签、勾选、评论数及原生依赖。临时GitHub工作页已关闭，临时同步文件在回执保存后清理。
