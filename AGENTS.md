## Agent skills

### Issue tracker

规格和任务使用 GitHub Issues。操作前读取 `docs/agents/issue-tracker.md`。

### Domain docs

采用单一领域布局：根目录 `GLOSSARY.md` 和 `docs/adr/`。
探索或修改项目前，按 `docs/agents/domain.md` 读取相关领域文档。

### Windows delivery

Windows交付与构建清理按 `docs/development/windows-delivery.md` 的“本机安装与清理”执行。

### Windows online adaptation

Windows 联网开发先读 `docs/development/windows-local-setup.md`；任务范围和进度从 GitHub Issues 读取，执行范围以当前用户指令为准。

### Development artifacts

截图、日志、录屏和本次任务的一次性脚本放在被 Git 忽略的 `build/` 下，用完清理。仓库只保留可复用工具、正式测试夹具及持续维护的规格和使用说明；任务进度写 GitHub Issues。
