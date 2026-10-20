# #24 取证索引

`review-round4/manifest.json` 固定最终一轮的 35 张原始 Flutter PNG 和 SHA-256。主任务从未提交的 #24 源码采集；提交后按本目录所在 Git 提交定位源码。截图加载实际 ProductSans、Windows SimSun/Georgia/Consolas，DPR1，`debugDisableShadows=false`。全部内容为隔离的合成信息，未读取用户资料。

| 路径 | 内容 |
| --- | --- |
| `review-round4/purple-{1440,1280}.png` | 常规默认首屏，与 canonical 同尺寸；240目录+340列表+剩余详情 |
| `review-round4/purple-{1440,1280}-{editor,taxonomy,empty}.png` | 常规编辑、目录标签、无匹配结果双视口 |
| `review-round4/{green,blue,mono}-1440*.png` | 四主题复用同一 palette 和页面状态 |
| `review-round4/purple-1440-{failure,query-failure}.png` | 写入失败保留输入；服务拒绝超长查询后明确错误并清空旧详情 |
| `review-round4/purple-1440-{history,history-empty,revision-confirm,revision-failure}.png` | 真实历史列表、空历史、差异与确认、写入失败 |
| `review-round4/purple-1440-{trash,trash-empty,recycle-confirm,recycle-failure}.png` | 真实回收内容、空列表、恢复确认、恢复失败保留条目 |
| `review-round4/purple-{long,200}*.png` | 独立长内容和200%首末可读性/可达性；long-last为最后字段定位，long-bottom为真正到底；不替代常规对照 |
| `compare-r4/` | oil-ui-pro `--compare` 的8对同尺寸参考/Flutter/叠加/差分与 report；QA HTML 仅放置未改写的 Flutter PNG |
| `reference-recovery/` | 未改原型 HTTP 页面取得的回收站/历史参考及 report |
| `review-round1/`、`review-round2/`、`review-round3/` | 历次固定实际图；只表示对应阶段，不是最终当前画面 |
| `review-round3-recovery/` | 最先修复 r2 历史黑块的独立替代图和 manifest，完整 r3 又包含同一修正 |
| `fidelity/` | 工具工作输出，可由再次运行覆盖；盲审和交付使用固定 review-round4 |

默认参考在仓库 `docs/design/prototype-reference/library-default-purple-{1440,1280}.png`。编辑/taxonomy/empty 原参考由 `round05-page-reference-prep/cases/library-{editor,taxonomy,no-results}/` 的最终 HTML 取得，完整参考图已嵌于 `compare-r4` 四格中。原型和 CSS 从未为匹配实现而修改。

已知数据差异：名称按 Unicode/ID 稳定排序，文档服务位置与 HTML fixture 不同；#27 未关联凭据不造假，关联区自然高度随真实数据变化；目录“编辑”和差异确认是本票真实能力。不可把以上差异用于豁免实体线、段落列宽或动作锚点。

独立报告原件为工作树外 `C:/Project/network_config/info-manage-worktrees/24-fidelity-review.md`，r1/r2 只看其固定 SHA 图。r4 收口结论见实现记录；r3固定图保留当时边界问题，不作最终图。Windows native 是实际控制/CLI/DPAPI 重开证据，内容视口与这些 DPR1 canonical 图不同；Mac、真实通知点击未验。
