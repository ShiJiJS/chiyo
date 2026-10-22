# 信息库新版原型

关联 #52–#60。保留三栏、四主题与 Round05 字体，改进目录／标签操作和公共控件状态。

从 `docs/design/prototypes` 启动本机 HTTP 服务，打开 `/round-06-library/index.html`。文件引用同级归档 Round05 的字体与 Alpine，不需要外网。不要只以 round-06-library 为服务器根目录，否则相邻资产不可达。

## 状态

`?state=stress` 为56目录（含四级）、100标签、200信息的虚构压力夹具；`empty` 为空库；`create`、`move`、`tags`、`organize` 直接打开对应表面；`error` 在首次提交模拟保存失败。`theme=purple|green|blue|mono` 切主题。

常规数据的目录与标签写入浏览器 localStorage 后可刷新读回；各命名状态独立存储，压力夹具刷新重新生成。只做设计验证，无真实服务、凭据或文件原文。原型内的新建信息与回收说明只表达本轮导航边界，其完整业务继续见旧原型和正式客户端，不计作本轮业务通过。

运行 `node check-ui.cjs`；需要宿主提供 Playwright，默认使用本机 Edge 无头临时实例，结束自动关闭。`PROTOTYPE_URL` 和 `PROTOTYPE_EVIDENCE` 可指定本地地址与证据输出。检查包括失败保留草稿／重试／刷新、移动防环、筛选交集、标签清理及信息归属，另外生成四主题双视口图。200%截图实际放大文本尺寸而非 DPR，正式客户端仍须单独检查 Flutter TextScaler。

设计依据及无人值守自主决定记录见 `../../library-ux-20261021.md`。原型不是正式数据库写入或 Windows 验收证据。
