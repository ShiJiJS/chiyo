# 凭据与使用流程 HTML 还原准备

2026-10-17。只读整理已确认 round05 原型，供 #27–#31 实施。这里不是 Flutter 实现、业务验证或视觉通过结论。没有修改原型、用户资料、原预览服务或 GitHub。

- `screenshots.md`：23个页面/状态，紫色，1440×900和1280×800，1x DPR，共46张原PNG。
- `measurements.json`：实际DOM矩形和最终computed CSS；每个cases报告还有字体、资源、主题变量和命令。
- `source-sha256.json`：规范HTML、CSS、脚本和字体的SHA-256；捕获结束核对一致。
- `validation-summary.json`：逐图检查，最终46图issues均空，CSS/JS/字体无加载失败，自动favicon404不算页面资源错误。
- `capture.mjs`在独立临时Chromium profile使用oil-ui-pro截图工具的外部测量副本，未改skill或规范来源；源HTTP为127.0.0.1:8797。`summarize.mjs`重建索引与汇总。

工具longMeasure提示保留：SSH完整argv必须展示且是代码行，可换行/滚动，不缩减参数；准备/启动失败的明确说明按原型保留。精确还原不会为了清lint去改已确认HTML。这些提示记录在逐图报告，不视为业务通过。

首次server关联1280点击被固定footer挡住，实际打开了字段转换，不能用作关联参照。该组已改由默认文档服务的可见管理关联按钮进入，双视口重取，已亲自查看1280确为“关联凭据”。原capture.log保留首次过程，credential-links-corrected.log与最终cases/command.json/report.json为更正后证据。

主Agent已实看凭据文件详情1440、添加文件1280、文件使用1440、文件环境变量1280、关联1280、启动失败1440这六张原图，未声称逐张实看全部46图。未做四主题全状态、200%文本、Windows产品或macOS验证。

视觉仍以仓库docs/design/prototypes/round-05/index.html及最终CSS为唯一规范。字符串/文件凭据、运行时注入和执行事实的数据边界按runtime-protocol-v1和各票，不能为追图伪造可用凭据、授权或执行结果。