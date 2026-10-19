# round05 已确认视觉基线

> 当前目标更新（2026-10-19）：#33 Windows凭据复用、#36附件原型及[#35焦点填充Windows范围](../../../development/issue35-completion.md)已完成。HTML仍是虚构交互，不能替代真实平台证据或最终新包。当前行为与后续界面要求见[设计修订](../../windows-credential-and-file-update.md)，排期见[Windows计划](../../../planning/windows-next-iteration.md)。旧一次启动状态用于保留v1历史，新复用/附件/填充有独立状态；附件核心由#37、Windows客户端由#38交付，保持四主题及三栏。

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

## #33 复用原型（Windows生产实现已完成）

`reuse.js`、`reuse-history.html`和`reuse-assembly.cjs`在同一入口扩展新批准及多操作历史：`?state=reuse-approval`、`reuse-result`、`reuse-history`、`reuse-running`、`reuse-failed`、`reuse-unknown`、`reuse-revoked`。`node check-reuse.cjs`检查6项复用设计状态；旧15项基线用显式legacy夹具保留v1历史合同，当前新复用目标另行检查。

字段与凭据的期限分别显示，逐次操作命令是不可执行的虚构状态数据；HTML没有调用真实CLI/SSH。生产复用能力见[#33完成记录](../../../development/issue33-completion.md)与[v2合同](../../runtime-protocol-v2.md)，不以HTML状态证明生产通过。

## #35 本机焦点填充原型

`focused-fill.js/css`、`focused-fill-{approval,history,dialog}.html`和`focused-fill-assembly.cjs`沿用同一收件箱、决定栏和历史。`?state=fill-approval`、`fill-confirm`、`fill-result`、`fill-history`、`fill-sent`、`fill-refused`、`fill-partial`、`fill-unknown`、`fill-checking`、`fill-revoked`、`fill-rejected`、`fill-save-failed`、`fill-incompatible`、`fill-tip`、`fill-long-target`直达相应状态；主题参数不变。

`node check-focused-fill.cjs`检查14项填充设计状态，连同原15/14/6项检查共49项。部分/未知结果增加“我已检查并处理输入框”的人工确认，失败保留暂停和原结果；确认不输入、不续期。逐次记录每页最多8项，原操作选择独立。密码框填充不要求建议环境变量名，不展示命令/退出码/文件清理；批准后等待Agent点击目标，原型不发送任何真实输入。流程、类型和生产接口目标见[填充合同](../../local-focused-fill-contract.md)；Flutter渲染与原生输入检查点分别取证，均不替代完整用户流程验收。
