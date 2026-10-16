# 已确认HTML的截图基准

来源为仓库`docs/design/prototypes/round-05/index.html`，未修改CSS或通过缩放追随Flutter。2026-10-17由独立浏览器以原逻辑尺寸、默认100%缩放截图，使用原型附带Noto Sans SC Regular和本机宋体、Georgia、Consolas。所有截图工具报告均无脚本、资源加载或横向溢出错误。

| 文件 | 内容视口及进入方法 |
| --- | --- |
| `approvals-purple-1440.png` | 1440×900，`theme=purple`，点击“部署北辰文档站” |
| `approvals-green-1440.png` | 1440×900，同申请，`theme=green` |
| `approvals-purple-1280.png` | 1280×800，同申请，`theme=purple` |
| `scope-purple-1440.png` | 1440×900，`theme=purple&state=scope`，大量目录信息的补选弹窗 |
| `handled-purple-1440.png` | 1440×900，同普通申请，点击右侧批准，展示已处理状态 |
| `organization-pending-purple-1440.png` | 1440×900，下一页后点击“整理常用联系资料”，两项待审批 |
| `organization-complete-purple-1440.png` | 1440×900，点击“整理项目服务资料”，原型预置四项已完成 |

可复现：从原型目录启动本地HTTP预览，再运行oil-ui-pro的`shoot.mjs`，使用表中视口、query与点击动作。不能直接只临时托管单个HTML文件而漏掉相邻CSS/脚本。

这些是参照，不能用实现中间稿覆盖。实际Flutter证据另放各任务的`docs/development/evidence/`，标明源码、运行方式和视口。数据量不同时区分自然内容高度与固定框/控件的样式差异；例如scope的836px是大量内容触发最大高度，非所有弹窗固定高度。真实来源名称、随机请求ID、时间与倒计时可以不同，不能为对图伪造事实。文字的Chromium次像素/Flutter灰阶抗锯齿单独记录，不调整主题实色来补偿。
