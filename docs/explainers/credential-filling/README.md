# 跨应用填写机制图解

[阅读 PDF](credential-filling.pdf)：适合在 GitHub 直接预览或下载阅读，网页演示与 Mac／Windows 分支已展开为静态内容。

用浏览器打开 [index.html](index.html)。页面不连接资料库，不读取凭据，不操作其他应用；交互只使用公开教学值 `hello` 和页面内的示意对象。

先讲 Agent 怎样定位网页、选凭据并提交申请，再讲获批后的浏览器连接、复核和写入；随后扩展到原生控件的发现、固定对象、批准和后台设值，最后说明直接填写对恶意 Agent 的安全边界。宽屏使用左侧章节与小节目录，随滚动标记当前位置；窄屏通过顶部“目录”按钮打开抽屉。原生部分用同一个 macOS／Windows 选择器，联动目标列表、App 与辅助程序通信、系统控件树及后续设值。原返回区展开两个已通过支持检查的候选；窗口与控件树可双向点选查看属性，先模拟 helper 扫描筛选，再模拟 Agent 按任务选择第二项。切换系统或重置会恢复结构初态，查看组件不会选定填写目标。

本文按 [CLI 设计](../../design/cli-redesign-review.md)、[原生后台填写合同](../../design/native-background-fill-contract.md) 和对应实现维护。真实支持范围以平台兼容验证为准，教学图不表示任意 App 都能填写。

- `credential-filling.pdf`：静态阅读版。
- `print.css`：仅在 PDF 导出时使用的分页和排版样式。
- `index.html`：正文和示意结构。
- `tutorial.js`：网页元素演示、系统 API 对照和后台目标模拟。
- `reading-nav.css`、`reading-nav.js`：侧边目录、阅读位置高亮和窄屏目录抽屉。
- `style.css`：既定的页面样式。
- `native-background.css`：原生固定目标示意的补充样式。
- `vendor/alpine.min.js`：Alpine.js 3.17.4，MIT，来自已有设计技能提供的本地依赖；上游为 <https://github.com/alpinejs/alpine>。

持续维护的正文保存在此目录。截图、验证回执及一次性修改脚本放在 Git 忽略的 `build/`，任务进度写 GitHub Issue。

## 更新 PDF

安装并启动 ego-browser 后，在仓库根目录运行：

```sh
node scripts/export-filling-explainer.mjs
```

脚本读取同目录 HTML 和配套文件，展开演示与两个系统的内容，生成 `credential-filling.pdf`，完成后关闭导出用浏览器工作区。正文更新后需重新导出，并检查分页、图表和代码是否完整。PDF 使用 A3 纵向页面保留图文对照；屏幕阅读可按页面宽度缩放。
