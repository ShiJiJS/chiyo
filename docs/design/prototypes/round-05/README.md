# round05 已确认视觉基线

> 当前目标更新（2026-10-18）：已确认授权期内复用、普通附件入SQLCipher及本机焦点填充，生产实现尚未开始。当前行为与后续界面要求见[设计修订](../../windows-credential-and-file-update.md)，排期见[Windows计划](../../../planning/windows-next-iteration.md)。下文/现有HTML保留Round05 v1视觉及流程基线，一次启动状态不代表新目标；新增状态由#33/#35及#34下的#36先补原型；附件核心由#37、Windows客户端由#38交付，保持四主题及三栏。

来自2026-10-16的HTML设计探索；2026-10-17 D0补齐流程。保留原型而非生产软件，虚构数据不接后台，刷新重置。见[流程覆盖](../../round05-flow-coverage.md)与[D0证据](../../../development/round05-22-design.md)。

从本目录运行 `python -m http.server 8795 --bind 127.0.0.1`，打开 `http://127.0.0.1:8795/index.html`。端口可自行替换；页面无需原video_viewer工作区。顶部导航切换模块，主题控件切换四主题。原单文件style-explorer重复嵌入字体，未复制；index为可维护的拆分版本，脚本/字体本地提供。

字体许可见fonts/OFL.txt；Alpine.js版本/许可证声明在vendor/alpine.min.js头部。audit-screens为原审计截图，不是Flutter实现证据。

index.html是唯一完整交互入口。baseline-index.html保存已确认基线，旧碎片HTML作为来源归档；新增在lifecycle.js/css和lifecycle-surfaces.html。运行 `node assemble-lifecycle.cjs` 从基线重新组合，重复运行结果一致，不依赖Git历史或原video_viewer。`node check-flows.cjs`运行15项设计状态检查。

直接查看：`?state=editor`、`scope`、`proposal-edit`、`credential-rotate`、`credential-discovery`、`backup-enable`、`restore-preview`、`execution-start_failed`、`execution-token`、`no-results`、`large-data`；完整清单见覆盖表。异常验收通过URL，不显示在产品流程。纯HTML不读取所选文件内容、不生成可用恢复密钥；文件选择和另存是交互设计，真实IO/加密由后续票实现。
