# Issue tracker: GitHub

仓库：https://github.com/ShiJiJS/agent-info-manage

使用已登录的 GitHub CLI，显式指定
`--repo ShiJiJS/agent-info-manage`。

## 操作约定

- “发布到 tracker”表示创建 GitHub Issue。
- 发布前检查已有 Issue，已有同一规格时更新原 Issue。
- 多行正文先保存为文件，通过 `--body-file` 提交。
- 读取任务时读取 Issue 正文、标签及相关评论。
- to-spec 生成的规格使用 `ready-for-agent` 标签。
- 第一版规格对应 Issue #1；本地规格变更应同步该 Issue。
- 当前未安装 triage 技能，不建立额外标签映射文件。

## Pull requests as a triage surface

PRs as a request surface: no.
