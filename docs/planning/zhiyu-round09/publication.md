# Round09 GitHub发布清单

2026-10-26正在按用户确认调整为Mac优先，范围仍是原8张票。本轮文档在codex/zhiyu-mac-plan；本页下方2026-10-25核验为历史发布记录，Mac变更同步完成后在本页追加固定版本与回读结果。当前产品开发仍暂停。

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

## 已核对

- 8张issue均为OPEN，标题、完整正文和标签回读一致；没有重复发布旧20张任务或额外规格父票。
- 11条GitHub原生blocked-by关系与计划完全一致。图无环；F01传递等待全部7张前端票，U01不等待不存在的T01。
- 各前端票都链接#69后续规划入口；#69反向列出全部7张前端票。
- 8张票的74处Markdown链接均指向本仓库固定版本资料或真实issue，不依赖localhost和个人电脑路径。
- 40份本地规格/规划Markdown的185处相对链接在发布前已检查；本记录回填后再次检查新增链接和文档格式。
- 未修改或关闭旧父票、旧任务；未开发产品、未连接真实资料库、未启动子Agent或computer use。

发布记录只证明规划与tracker同步成功，不代表界面已经实现或Windows真实流程已验收。
