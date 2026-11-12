---
status: accepted
---
# 模板插件描述资料，安全能力继续由宿主负责

2026-10-25提出，后由 [ADR0019](0019-discover-plugin-templates-from-running-app.md) 确认采用。模板插件使用声明式 JSON，宿主提供有限布局与受支持的设置项，不加载任意可执行第三方代码。这样 Agent 能为新资料类型生成模板，同时不把授权、凭据和文件执行规则移进插件。每项资料持有不可变模板快照，升级或移除插件不改写旧资料；重复条目按现有稳定叶字段身份授权，避免新增经历自动进入旧授权。

现由 `info_core` 校验模板包和快照，App 与服务共用插件管理及展示，CLI 查询实际启用的模板。格式以 [JSON Schema](../design/zhiyu-template-package.schema.json) 为准，展示和交互见 [UI 指南](../development/ui.md)。本决定扩展旧表单模板语义，不替代 ADR0001/0002/0003/0010/0011 的稳定身份、授权、Flutter/Dart 及加密存储规则。
