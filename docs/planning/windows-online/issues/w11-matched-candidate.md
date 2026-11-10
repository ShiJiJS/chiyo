# Windows：完整打包并连续核对主要使用流程

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：11。直接前置：[#114](https://github.com/ShiJiJS/chiyo/issues/114)、[#115](https://github.com/ShiJiJS/chiyo/issues/115)。

## 做完后能做什么

得到可以整包运行的同版本 Windows App、CLI、worker 和说明，主要业务连续检查有实际结果，剩余人工事项清楚列出。

## 做哪些改动

- 更新 Windows 打包与包识别，带齐全部 Skill 引用和同版本工具，保存 ZIP、SHA256、清单与必要日志。
- 把前八票在同一候选上连起来使用，集中修遗漏，最后列出待用户恢复 computer-use 后核对的真实桌面事项。

## 完成条件

- [x] 同一提交生成完整 App、CLI、worker、helper、引用及说明，哈希和来源一致，实际解包 CLI 可运行。
- [x] 正常入口连续核对资料/提案、申请审批、附件、凭据、目录回收、备份、重连、App 退出及新配置拉取；结果来自实际候选，未完成项不假报通过。
- [x] 发现本轮功能缺陷继续修复；按相关改动复验，最终做适当整体检查，不反复重跑无关全量测试或沿用旧包结论。
- [x] 中文鼠标输入、保存与取消已在实际候选验证。用户于2026-11-10将Ctrl+K原生快捷键确认移至后续#117，不作为本轮完成阻点；未声明真实快捷键或IME逐键输入通过。
- [x] 开发打包明确使用 -PackageOnly，保留一个最新候选和必要证据；当前不使用computer-use或启动界面，用户正在使用电脑，正式安装、全局 hooks/Skill 信任及用户认证仍集中处理，不另建额外票。
- [x] 记录 NAS 服务兼容情况、已通过与未测范围、候选路径及复现命令；#104 真实交付条件未全部满足时保持打开，#105 跨电脑审批不计完成。

## 从哪里接续

- `scripts/package-windows.ps1`
- `scripts/test-windows-package.ps1`
- `scripts/check.ps1`
- `integrations/codex/`
- `docs/development/windows-delivery.md`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W11 -->


2026-11-10本票开发交付完成。完整包源5845d3c，2071项全套、实际解包CLI/hooks16项、加密生命周期7项及实际NAS记录/正式页面只读验证通过；具体归档SHA/复现/未测范围见docs/development/evidence/windows-online/w116.md末尾与同目录w116-package-5845d3c.json。正式安装和真实系统交互留#104，#105/#117后置。清理旧包/临时storage-build的命令被自动审批拒绝，未执行、不重试；旧产物保留，不影响当前新包来源与验证。
