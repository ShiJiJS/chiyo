# Mac 最新版与本机清理（2026-11-03）

当前固定安装和唯一交付ZIP包含 #78/#79/#80 的实现，以及试用发现的“修订提案重新审阅”修复。改动仅在 `codex/zhiyu-macos`，Windows和main未改动。正常Release开库和原infos真实资料重新录入尚未完成，三个ticket继续开放。

## 当前版本

- App/CLI：`0.4.1+13-mac-dev.11ad2816f7ea`，Apple Silicon / ARM64。
- 产品源码：`11ad2816f7ea49b1b71ee99b1d04589f8fee8243`。
- 固定入口：`local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app`。
- 唯一交付ZIP：`local/中文 Mac 预览/agent-info-manage-0.4.1+13-mac-dev.11ad2816f7ea-macos-arm64.zip`。
- ZIP SHA256：`048f9afcb8b5cd2723bb3f2b7f388455c07b168abf9269ba5ea9b5adc22b1200`。

`package-macos.py --check`的22个阶段通过：四包完整检查、Release构建、ARM64/依赖、App与CLI签名、ZIP解压逐文件核对、实际SQLCipher及随包CLI/worker。完整测试为核心393项、CLI96项、存储364项、App1139项通过；另有71项按各自条件跳过，不能计作通过。

固定安装7996项文件/权限/内部链接与清单一致，strict签名和ZIP摘要再次通过。个人Skill已同步的定位器指向此固定安装的CLI及完整运行包说明，大小和SHA-256核对通过；未修改全局hooks或信任。

## 独立试用

首轮f88c78fe的同模型独立新聊天只收到虚构文件目录，自行选择动态模板、分类、关联与文件版本。主人审批后9项资料、5项凭据入库，10份普通原文与来源逐一相符。两个不同Mac原生进程读取同一加密库，实际PDF/图片预览和Markdown显示正常；800天受控时间后，历史原文和以另一数据库密钥恢复的完整备份保持一致。见[证据](evidence/ai-intake-synthetic-20261103/summary.json)。

试用发现的修订提案问题已进入当前包：原审阅保留，主人可以明确放弃旧编辑和勾选，重新核对原申请的当前版本，再决定是否批准。真实加密库的修订、取消/确认重新审阅和批准检查通过，没有自动套用旧编辑或产生另一份提案。

当前11ad2816又用同模型新聊天补查密码管理器生成但未提供的登录密码，以及已进入聊天的来源不明密码。前者走主人补填，后者由AI修订原申请并显示已接触；实际Mac原生工作区完成重新审阅、补填保存和批准，2项服务及2项凭据入库。见[补充记录](evidence/ai-intake-synthetic-20261103/credential-extra-and-review.json)。

合成密码的主人侧输入使用测试框架或现有Owner API，不计作系统安全编辑器的物理输入。原生试用使用隔离Debug应用和合成密钥，不代替正式Release与原Keychain联合验收。

## 原资料与尚未完成的工作

原应用正常退出后，已逐字节核对并保护关闭状态的加密资料库，原Keychain项保留；原受信任程序另有逐成员核对的压缩保护。未清空原库，未导出数据库密钥，未改ACL。该关闭状态副本依赖原Keychain密钥，不冒充另有恢复密钥的便携备份。

上一候选f88c78fe的正常Release启动返回`startup_failed`，随后通过本包CLI正常关闭，没有开放Agent端口，也没有替换原库。当前11ad2816正常启动同样返回`startup_failed`，已通过本包CLI正常退出；再次核对关闭保护，原加密库字节保持。后续只读系统日志确认，同一进程启动时执行`SecItemCopyMatching`后出现`CSSMERR_CSP_OPERATION_AUTH_DENIED`，与原密钥访问被拒的代码路径一致，见[日志证据](evidence/ai-intake-synthetic-20261103/startup-keychain-log.json)。未使用computer use，也未再次启动或修改签名、Keychain设置。

正常开库仍需本人处理系统决定：打开固定新版，若显示“无法打开信息库”，点击“请求钥匙串访问”，在系统提示中输入本机密码并选择允许。完成后再继续同模型新聊天的原infos重录和独立核对。原infos文件保持。

## 清理

已清理本轮结束的测试App/dSYM、Xcode与Flutter输出、解压核对副本、诊断构建、废弃ZIP、已结束的合成资料库及失败测试遗留的80MiB恢复夹具。两轮清理合计逻辑大小约3.77GiB。唯一最新安装与ZIP、源码、SDK和依赖保留。

小型测试脚本、运行记录与回执集中保留在本机忽略的私有验证记录目录；公开合成证据在本页链接目录。原库和受信任程序的恢复保护在正常开库及真实重录确认前保留。未清理用户`.local/`、原infos、Keychain或已批准接入的issue49项目。
