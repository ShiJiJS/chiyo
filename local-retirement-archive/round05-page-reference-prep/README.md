# round05 四页 HTML 还原准备

2026-10-17。只读参考整理，供信息库、录入提案、授权历史、设置的后续实现复用。
**本目录不构成 Flutter 忠实还原验收；D1 仍未完成，所有页面样式通过前不进入服务器同步。**

唯一规范仍是 `C:/Project/network_config/info-manage/docs/design/prototypes/round-05/index.html`
及它依次加载的 CSS、脚本、字体、SVG。依据同仓库 `prototype-fidelity.md` 与
`prototype-reference/README.md`。本次全部访问已运行的
`http://127.0.0.1:8797/index.html`，未托管单个文件、未改服务器/HTML/CSS/业务代码，
未操作用户浏览器、未写 GitHub，也没有以 Flutter 中间截图作为规范。

## 从这里取用

- [完整截图索引](screenshots.md)：23 个页面/状态，每个均有 1440×900、1280×800 原始 PNG，共 46 张。
- [精简几何测量](measurements.md)、[结构化测量](measurements.json)：各状态关键节点的坐标、字体、留白、网格和滚动高度。
- 每个 `cases/<case>/report.json` 的 `dom` 保留更多选择器的最终 computed CSS、DPR、加载字体、CSS 顺序、资源请求；`command.json` 是该次完整命令参数。
- [工具与资源验证](validation-summary.json)、[源文件哈希](source-sha256.json)、[按加载顺序排版的原 CSS](css-source-order.txt)。CSS 文件未改写，后者仅在本目录增加换行供阅读。
- `review-sheets/` 是带标签的缩小总览，方便导航；**还原比较必须打开原 PNG，不用总览的缩放尺寸作几何依据**。

## 捕获环境与结论边界

所有截图是应用内容视口：默认100%缩放、1x DPR、无原生标题栏。`dom.viewport` 逐张记录宽高、DPR 和 visualScale。
Chromium 在独立临时 profile 中运行，使用原型附带 NotoSansSC Regular（CSS family `ProductSans`，font-weight 400，全部报告 `loaded`）；
宋体 `SimSun / Songti SC`、Georgia、Consolas 使用本机系统字体。截图中无缺字；未复制系统字体资产。
浏览器合成的 500/600/700 字重不能擅自换成另一份 Medium 字体来追图。

工具46份截图记录的 `issues=[]`、`lint=[]`；没有脚本异常、横向溢出或加载失败图片。
额外检查 Resource Timing 发现每个独立浏览器首次自动请求 `favicon.ico` 返回404，工具按既有规则忽略这一项；
CSS、JavaScript、字体资源正常，未为 favicon 修改原型或服务器。五份 CSS 均加载，规则数量依次为219/175/105/39/61。
捕获后重新核对所有已记录源文件 SHA-256，一致。

已实看全部46张的分组双视口总览，并打开原尺寸的四个默认页面及编辑/备份等代表弹窗核对。
这是原型参考取证与实施准备，不是新审美评审，也没有独立评审者；无 Flutter 对比、业务实现、200%文字、四主题全状态或 macOS 通过结论。
紫棠作为此次默认基准；其余主题继续直接使用原CSS色值。没有应当修正的 lint 提示，未修改/删减任何界面文案。

## 公共组件先复用 D1，但允许原型明确的局部变体

共同的颜色、ProductSans 正文、宋体/Georgia/Consolas角色、顶部导航、主题组、SVG图标、搜索、quiet/secondary/primary按钮、输入边框、焦点环和蒙层，
应从 D1 公共控件复用。API 定型以后，在公共组件上表达以下页面变体；不要把 D1 的尺寸硬套进所有页面。

- 顶栏72高，左右28，品牌18/600和26图标；nav gap23，品牌与nav gap24；选中3px底线。
  两个目标视口仍是同样尺寸，1280仅因 `max-width:1320px` 隐藏连接状态。
  `max-width:1250px` 的290队列、27设置留白等规则**不适用于1280**。
- 全局SVG为18、24 viewBox、1.65描边、round cap/join、无填充；局部13/15/24/26尺寸按来源显式传入。
  已有独立 helper 提交 `848bde8cb0b14bc3d39bb62d0d3fab813dd5f251`：
  `PrototypeIcon(PrototypeIconGlyph.layers, size: 26, color: ...)`。
- 正文14/1.5；原型多数13/12/11辅助文字必须保留角色。全局code为Consolas12/1.6，但信息库字段值和提案字段值**局部13**。
- quiet：12字号、7/12 padding、5圆角、1线；secondary：13字号、10/16 padding、4圆角、paper底及1线。
  primary为13/600、4圆角，但 D1 决定栏全宽，提案页底部为auto/min-width165/padding11/22，基础弹窗内为auto/padding10/20。
  信息详情工具条里的按钮又有 `border:0; padding-right:0` 覆盖，不恢复为常规描边按钮。
- 基础焦点环为accent色2px、offset3；disabled opacity .45；active下移1px。
  `settings-retention` 的关闭按钮焦点框来自 select/键盘触发后的 focus-visible，**不是每个弹窗固定画一个框**。
- paper圆角分角色：D1审批纸张6、提案/历史document-card7、信息详情9、基础/流程弹窗9。
  外层框只画其既定分隔线，不新增 Material 卡片阴影/内嵌卡。

## 信息库：保留全部三栏

代表 `cases/library-default`；编辑、目录标签、无结果分别为 `library-editor`、`library-taxonomy`、`library-no-results`。

| 几何 | 1440×900 | 1280×800 |
| --- | --- | --- |
| 主网格，y72起 | 240 / 340 / 860 | 240 / 340 / 700 |
| 目录列 | x0,w240,h828 | x0,w240,h728 |
| **中间信息列表** | **x240,w340** | **x240,w340** |
| 右详情外框 | x604,y93,w812,h786 | x604,y93,w652,h686 |
| 信息正文滚动区 | x605,y149,w810,h660.5 | x605,y149,w650,h560.5 |
| 底部操作栏（本内容自然高度） | x605,y809.5,w810,h68.5 | x605,y709.5,w650,h68.5 |

- 目录列 padding27/18/18、右1线；标题21/600；标题总数Georgia；信息/凭据mode框margin-top20、padding4、gap3；搜索margin-top22、padding9/10。
  展开树、目录与标签/回收站入口、常用标签、底部本机提示均保留。
- 中间列表自己有目录标题/信息总量/新建按钮、可滚动信息列表、底部分页。表头padding28/23/21，当前自然高98。
  `.item-list` padding12/10；列表行padding16/13、gap12；图标壳33×35；标题14/700/1.6，描述12、上距5，metadata11、上距11。
  选中行6圆角、selected底与描边，箭头13。默认六条按原型中文名称排序，文档服务在第五行被选中；不要为了第一屏整齐另行选择第一条。
- 右区padding21/24；纸张9圆角，工具条55高、padding0/25，**无需 D1 的244决定栏**。
  `.info-document` 最终padding **23/33/28**；path12；标题图标47×49/内部SVG24、gap16；标题为 **ProductSans26/700/1.4**，并非宋体；描述13/1.8。
- 属性区margin-top22、padding17/0，上下线，网格1.5fr/.7fr/1fr，gap20。
  字段区margin-top22；字段行padding17/0、155px名称列+弹性值列、gap20，底线；名称13/500，说明11；值Consolas13/1.6。
  当前`read-field`自然77高；不使用审批页checkbox行模板。
- 关联凭据与Agent可见说明保留在正文里；底部按字段授权、修改历史、转换旧秘密字段入口属于独立footer。
  完整脚本已将旧token字段迁为关联凭据，当前文档服务是2字段；不要只读旧prototype.js就画成3字段。
- 目录树、中间列表、右正文分别滚动，header/footer留在各列。1280仍保留340px中栏，右正文相应收窄/滚动。
  无结果时三栏还在，中栏显示空结果及“查看全部”，右栏是空详情；不把中栏合并成目录或详情。

## 录入提案：左收件箱加完整文档

参考 `proposal-new`、`proposal-diff`、`proposal-conflict`、`proposal-editor`、`proposal-confirm`。

- 主网格310+剩余，两个目标视口左列均310。复用D1 queue壳与搜索/筛选，但本页 `.new-layout` **行padding19/12、标题14、metadata/队列标签/页脚12**；
  不使用D1普通申请行的16/12、13/11。
- 舞台padding23/28/**22**。contextbar高34、底距20。纸张x338,y149；1440时1074×729，1280时914×629。
  **没有右侧决定栏**。纸张7圆角、1线及原微阴影。
- `.document-body` padding28/34，flex剩余区独立滚动；`scrollbar-gutter:stable`，定制滚动槽8。
  1440文档正文内容宽996，1280宽836（已经扣两侧34和8槽），不将滚动槽当作随机空白去掉。
- 主标题宋体29/500/1.5，margin13/0/16；身份沿用D1头像28但由本页自然内容布局。
  lead最终margin-top17、14/1.9，下面自述提示12/1.9；review-heading最终margin-top21、padding-top18。
- draft-item最终margin-top20；条目标题宋体21、gap10；右侧调整按钮；路径/字段数12；字段行150px+弹性值列、gap20、padding**10/15**、底线、wash底；值Consolas13。
- 底部 `.document-actions` 独立固定于纸张底，padding18/30、上1线、wash底、gap16；说明12/1.8、拒绝文字按钮、auto主按钮，不移到右侧D1决定栏。
  本新增提案页footer自然80.5高；正文在1280滚动，仍可看见底部动作。
- 修改差异为140px字段列+两等宽列，容器1线/5圆角；header12/base底，cell padding17/18、正文13；旧值浅暖底、新值wash底、变更片段selected底/strong字。
  冲突保留warn notice和底部disabled确认，不能把冲突页面当普通diff隐藏提示。
- 调整提案使用与信息编辑一致的780流程弹窗；确认这批变更则是590基础弹窗，不能用同一固定780宽模板替代。

## 授权历史：摘要、范围/访问两种正文

参考 `history-scope`、`history-access`、`history-ended`、`history-revoke`。

- 左queue/舞台/card/body与提案同类：310列，纸张x338,y149，7圆角，正文28/34+稳定8槽；宋体29标题。
  contextbar右侧为“记录保留设置”；纸张底部是说明和secondary撤销按钮，有效与已结束状态保留同一文档框。
- 摘要三等列，margin-top27、padding20/0、上下1线，列内分线与左padding24（首列除外）。small12下距8；strong15/500；数量 **Georgia28**，不是D1的48。
  当前1440摘要x373,y324.688,w996,h100；1280同x/y、w836。
- inner-tabs上距23、gap28、底1线；button14/padding13/0；选中strong/600及2pxaccent底线。
- 批准范围行padding21/0、gap14、底线，图标壳36×38；标题15/700，下距7；字段名称摘要13，不展示值；tag在最右。
  当前每行自然92高；不要使用审批checkbox字段行或信息库155px字段网格。
- 实际访问是时间线：margin-top23；event左距6、左padding28、底padding27、1线及7px圆点；header14、时间Consolas12、正文13上距8。
  实际访问与批准范围切换只替换文档正文，三列摘要和底部操作不消失。
- 已结束的授权隐藏撤销，footer保留结果说明。撤销确认是590基础弹窗，当前自然高206.594；不加入第二张纸或D1大数字决定区。

## 设置：260侧导航与居中940内容

六个代表子页均已取：appearance、notifications、records、templates、backups、application。
额外弹窗为retention、template-dialog、backup-flow、restore-preview。

- 侧导航260，padding28/19、wash底、右1线；标题21；导航按钮padding15/14、gap14、6圆角、底距7，名称14/500、说明12上距4。
- stage从x260起、padding30/40、独立overflow auto。settings-page max-width940、水平auto居中：
  **1440时x380,y102,w940；1280时x300,y102,w940**。这里没有全页外纸张，不把所有设置包成一张审批卡。
- header padding6/0/27、底1线、margin-bottom28；宋体标题30/500/1.5、下距10；介绍14/1.8。
  block间margin-bottom30；block标题16。
- 最终`.color-options`是**四列**，不是sections.css早段的三列；gap18。两种视口都是221.5宽、189高的主题块；
  普通块1线/padding16，选中2accent线/padding15，7圆角；样本高120、4圆角、内部32%/余宽网格。
- setting-row padding22/0、底1线、gap28；h3 15/500，说明13/1.8、上距7；select至少140宽、padding10/12、13字号、4圆角、paper底/line边框。
  通知switch42×24、3padding、18圆钮、on时位移18；这是原型自定义形状，不套默认Material Switch尺寸。
- 模板块是200px模板列表+余宽详情的6圆角纸张；列表wash底/12padding，详情25/28；宋体模板名20；字段行padding15/0、13字号。
  模板编辑为590基础弹窗，保留字段结构/空值的表达；不复用信息编辑780表单并带入字段值。
- 备份intro padding26、1线/7圆角；图标48×51；标题18、说明13/1.9；恢复区说明和历史不生效notice保留。
  备份流程是780流程弹窗，首次启用与恢复预览依内容自然长短；不把截图中的最大高度定成统一固定高度。

## 弹窗最终级联

公共蒙层`#241b274f`、blur2、z30、padding30。基础modal为paper底、1line、9圆角、
`0 20px 80px #211a2633`阴影、padding28/32；标题宋体23/500/1.5；关闭按钮30×30、22字号。

基础modal宽590、max-height85vh、overflow auto；正文14/1.9，基础input padding11/12、wash底、margin-top8。
流程modal宽min(780,100vw-48)、max-height100vh-64，**最终display flex/column、overflow hidden**。
flow标签13/margin10/0，input paper底/padding9/上距7，textarea min-height54，p14/1.85/max-width48ch。
flow-grid默认1fr/1fr、gap15，字段内的grid是1fr/2fr。

flow-panel有独立flow-scroll（flex1、min-height0、overflow-y auto、底padding16）；动作区最终position static、上1line、padding16/0/0、margin0。
这比中间CSS的sticky规则更晚，不能只抄sticky版本。没有flow-panel的内容仍按最终`>div`规则独立overflow auto。
flow-modal与flow-scroll都启用stable gutter；Windows本次外modal的15px槽使780外宽对应699内容宽，
flow-scroll再留15使可读内宽684；具体见report的clientWidth。

| 弹窗 | 1440：x,y,w,h | 1280：x,y,w,h |
| --- | --- | --- |
| 信息/提案编辑 | 330,32,780,836 | 250,32,780,736 |
| 确认提案 | 425,306.359,590,287.281 | 345,256.359,590,287.281 |
| 撤销授权 | 425,346.703,590,206.594 | 345,296.703,590,206.594 |
| 缩短保留期限 | 425,284.063,590,331.875 | 345,234.063,590,331.875 |
| 模板编辑 | 425,162.453,590,575.094 | 345,112.453,590,575.094 |
| 首次备份 | 330,162.219,780,575.563 | 250,112.219,780,575.563 |
| 恢复预览 | 330,66.078,780,767.844 | 250,32,780,736 |

这些高度是本次内容与视口的测量，不能替代自然布局/最大高度规则。
基础/流程弹窗的fade/enter、按钮反馈、tab焦点等均继续复用原型规则；本任务未录屏或声称交互验收。

## 复现

原HTTP服务器已由主任务运行，不在此重新启动。Node22+即可使用：

```powershell
node C:/Project/network_config/info-manage-worktrees/round05-page-reference-prep/capture.mjs
```

也可只取指定case，例如：

```powershell
node C:/Project/network_config/info-manage-worktrees/round05-page-reference-prep/capture.mjs library-default proposal-confirm history-revoke settings-retention
```

`capture.mjs`逐项调用oil-ui-pro的shoot.mjs外部副本；截图、viewport、等待、lint、浏览器生命周期逻辑原样保留，
仅在取图后增加一次只读DOM计算样式抓取并写入report，原Skill文件未改。准备时已记录工具源码SHA-256。
若只要原工具同样截图，替换`command.json`里的`shoot-measured.mjs`为
`C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs`，其余参数不变。
矩阵会自动记录准确query和触发弹窗的步骤；不需要修改页面或注入固定数据。

当前PNG请保留为基准；新一轮捕获使用新输出目录，避免以不同源版本覆盖。相同原输出目录重跑时工具会增加文件名后缀，
因此在读取下一轮report时应以它记录的file名为准。
