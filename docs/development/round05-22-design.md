# #22 · 流程原型与运行协议收口

2026-10-17。本票只设计与契约，无生产业务代码变更。[覆盖表](../design/round05-flow-coverage.md)逐项映射F01–F14及既有能力/后续票；[协议v1](../design/runtime-protocol-v1.md)和[JSON schema](../design/runtime-request-v1.schema.json)冻结新增CLI输入、输出、限额、错误与重试。普通GH内建写操作仍可按完整固定计划批准，不把凭据使用暗中限制为只读。

可复现检查（仓库根）：

```powershell
node docs/design/prototypes/round-05/assemble-lifecycle.cjs
node docs/design/prototypes/round-05/check-flows.cjs
node --check docs/design/prototypes/round-05/lifecycle.js
git diff --check
```

15项设计状态检查通过：自选字段/期限、失败草稿保留、回收稳定身份、指定版本恢复、字段单批/双许可、轮换失效/停用恢复、整理完成一致、完整提案和结果ID、输入/空库校验后备份预览、失败启动仍耗次、Token无需清理/未知结果、大数据50行、空库清空详情、typed reference/receiver。内存视图检查不替代公开服务、CLI、加密库或Flutter验证；原型刷新重置。

浏览器取证使用oil-ui-pro shoot.mjs独立临时Chrome，1440×900，不操作用户浏览器：

```powershell
node C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs http://127.0.0.1:8798/index.html --states scope,proposal-edit,backup-enable,restore-preview,credential-discovery,execution-start_failed,execution-token,no-results,large-data,organization-noop --size desktop --out docs/development/evidence/22-design/final
```

10状态[报告](evidence/22-design/final/report.json)无脚本/溢出/加载错误；截图已查看。8798仅本轮预览，可换任意静态端口。不要把文件直接传shoot：其本地服务器会按敏感文件名误拦credentials.js/css，使用静态URL取证即可，无须改Skill保护规则。

从新建入口实际填名称/字段→保存→重新读取详情的[动作报告](evidence/22-design/create-flow/report.json)和截图显示“联调资料”，证明原型内存变化；真实持久化/后端失败留给后续票。程序输出不写库、CLI私有领取、EOF不结束共享session、崩溃后owner验证资源只清理不恢复许可均已写协议。

父Agent组织一次独立不打分评审和定点复核。已修编辑器重复分类/说明映射、底栏遮挡、选择文件前备份预览、制作验收控件、列表与首屏启动失败可见性；最终复核由父Agent记录。新增动效是面板淡入和位移、按钮按下，沿用reduced-motion。说明限48ch；命令行长提示保留完整可核对命令并自然换行；原型沿用字体/许可，没有新图像。没有重开风格探索。

本票不证明CLI注入、真实备份、Flutter、Windows安装或macOS通过；不读取真实infos/凭据、不改现有应用数据/Codex配置。用户已延期macOS实际验收。后续业务门槛仍按#23–#31及原平台票验证。
