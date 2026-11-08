# #96：远程新增与修改提案

2026-11-08，隔离合成资料、独立 HTTPS、真实 SQLCipher；未替换日常 App，未访问真实资料、个人钥匙串或全局 hooks。

## 已实现

正式 CLI 经原设备和聊天身份提交文字新增、修改、修订及原操作查询。App 仍使用原录入提案界面：显示类型、完整目录、字段、关联及新增预览，修改显示前后内容，逐条切换阅读、整份保存。信息库和提案复用原插件展示，待入库关联在提案内查看，不创建虚假的正式记录。

用户接口调用已经抽取的 OwnerWorkspaceProposals、WorkspaceInformationCodec 和原事务；没有另写一套入库规则。关联候选的类型、来源和字段规则也抽成共用模块，本机仍可使用原系统排序。完整传输保留字段身份、模板快照、目录、关联、改动、修正内容和回执；不兼容的数据明确失败。凭据材料不进入普通工作区数据。此阶段尚未开放文件和凭据录入能力，带这些材料的提交整体拒绝，#97/#98 接续。

## 自动验收证据

- Mac 和 Linux ARM64 服务包各17项通过。新增 remote_proposals_test.dart 使用真实独立 Dart CLI/Codex 子进程，通过正式接口查询目录与模板、提交相互引用的资料、重复提交及查询。用户 HTTPS 接口预览和修正，保存后由另一个 OwnerClient 独立核对类型、值、关联和版本。
- 实际在合成加密库的回执写入处注入 SQL 事务失败，正式保存接口失败后资料和新目录均未部分保存，也无成功回执；解除故障后同一操作一次完成。少核对一条、无效格式同样不能入库；无效格式返回填写错误。故障注入不向库写入资料，不代替真实接口保存。
- 完整关闭并重开服务和加密库，原 CLI 关联仍能查到确认结果和原回执。用户在 App 手动修改导致旧 AI 提案过时，旧决定被拒绝；CLI 修订后重新核对才能产生新版本。用户手动编辑仍直接保存。凭据捷径和结束聊天后的新提交被拒绝。
- 正常 OnlineDesktopLauncher 的 Widget + HTTPS/SQLCipher 场景通过：三种模板（服务器、应用、文档）及关联分标签页预览，待入库关联切换到同份提案、Markdown 复用原展示、用户修改正文后整份保存；App 关闭时 CLI 提交修改，重开后看到前后对比并保存。独立客户端核对三条资料、目录、引用和最终版本。
- 真实 HTTPS 代理仅丢弃已提交的保存回复：原控制器进入结果待确认，不能再次提交。回执查询暂时失败仍保持待确认；连接恢复后查询原回执成功，只有一次保存、两条资料各一个版本。
- 原资料、关联、提案、模板录入和共用预览回归33项通过；正常 App 的联网编辑/重连/换服务器、访问审批、插件流程回归3项通过。共享包、服务端、远程包与 App 静态分析通过。首次 Widget 等待了不含“待入库”标识的名称，改为点击界面实际的待入库关联后通过，未删掉关联点击检查。

本机日志位于 local/server-first-stage：remote-proposals-process-tests.log、server-proposals-suite.log、linux-remote-proposals-suite.log、online-proposals-ui-tests.log、remote-proposal-recovery-tests.log、remote-proposal-rule-regression.log、online-proposal-composition-regression.log、desktop-remote-proposals-analysis.log、server-remote-proposals-analysis.log。Linux 使用 a05 验证基础镜像，只读挂载当前服务、测试和共享模块；并非最终发布镜像。

系统窗口、另一台电脑、个人钥匙串未实测；本票以自动流程为验收范围。#102 仍需生成同一版本的统一候选并让无开发上下文 Agent 连续试用。未进行正式安装、真实资料迁移或 #103–#105。
