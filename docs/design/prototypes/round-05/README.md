# round05 已确认视觉基线

> 当前目标更新（2026-10-18）：已确认授权期内复用、普通附件入SQLCipher及本机焦点填充，生产实现尚未开始。当前行为与后续界面要求见[设计修订](../../windows-credential-and-file-update.md)，排期见[Windows计划](../../../planning/windows-next-iteration.md)。下文/现有HTML保留Round05 v1视觉及流程基线，一次启动状态不代表新目标；新增状态由#33/#35及#34下的#36先补原型；附件核心由#37、Windows客户端由#38交付，保持四主题及三栏。

来自2026-10-16的HTML设计探索；2026-10-17 D0补齐流程。保留原型而非生产软件，虚构数据不接后台，刷新重置。见[流程覆盖](../../round05-flow-coverage.md)与[D0证据](../../../development/round05-22-design.md)。

从本目录运行 `python -m http.server 8795 --bind 127.0.0.1`，打开 `http://127.0.0.1:8795/index.html`。端口可自行替换；页面无需原video_viewer工作区。顶部导航切换模块，主题控件切换四主题。原单文件style-explorer重复嵌入字体，未复制；index为可维护的拆分版本，脚本/字体本地提供。

字体许可见fonts/OFL.txt；Alpine.js版本/许可证声明在vendor/alpine.min.js头部。audit-screens为原审计截图，不是Flutter实现证据。

index.html是唯一完整交互入口。baseline-index.html保存已确认基线，旧碎片HTML作为来源归档；新增在lifecycle.js/css和lifecycle-surfaces.html。运行 `node assemble-lifecycle.cjs` 从基线重新组合，重复运行结果一致，不依赖Git历史或原video_viewer。`node check-flows.cjs`运行15项设计状态检查。

直接查看：`?state=editor`、`scope`、`proposal-edit`、`credential-rotate`、`credential-discovery`、`backup-enable`、`restore-preview`、`execution-start_failed`、`execution-token`、`no-results`、`large-data`；完整清单见覆盖表。异常验收通过URL，不显示在产品流程。纯HTML不读取所选文件内容、不生成可用恢复密钥；文件选择和另存是交互设计，真实IO/加密由后续票实现。

## #36 普通文件字段扩展

`attachments.js/css`、`attachment-surfaces.html`及`attachments-assembly.cjs`扩展既有视觉和流程；组装器从原基线重新组合，不手改生成入口。`?state=attachment-library`进入虚构“求职资料”混合样本；`theme=purple|green|blue|mono`选择主题。

附件状态：`attachment-editor`、`attachment-file-field`、`attachment-empty-file`、`attachment-failure`、`attachment-long-name`、`attachment-only-file`、`attachment-too-large`、`attachment-converted`、`attachment-template`、`attachment-public`、`attachment-approval`、`attachment-history`、`attachment-trash`、`attachment-revision`、`attachment-restore`、`attachment-proposal`。均用同一个入口，不另造文件库导航。常规编辑中可切换文件类型并用浏览器选择文件；原型只取文件元数据，不读取或持久化原字节。

`node check-flows.cjs`检查包含扩展后的15项基线状态，`node check-attachments.cjs`检查14项附件设计边界。两者不能替代后续SQLCipher/真实CLI/Flutter验收。文件交付历史状态使用预置的交付事实，不伪装实际启动了CLI或上传网站。

服务和字段合同见[接口合同](../../attachment-interface-contract.md)，消费者及逐页责任见[客户端规划](../../windows-attachment-client-plan.md)。本轮沿用四主题、三栏、现有字体/控件；自检而无独立子Agent评审。#33再补授权复用原型，#37/#38接真实文件IO和生产界面。
