# 服务端首轮开发接续

## 当前范围与任务

持续目标 #91–#102，#103–#105 后置。分支 codex/server-first-stage。当前 #91 已完成并已在 GitHub 写回测试结果、关闭；下一任务为 #92 App 连接服务器。真实资料、正式 App 与个人钥匙串未操作。

浏览器沿用 TaskSpace **443 / p1**，该空间仍属于整个持续目标，未 finish。不要新开空间恢复。工单当前文本与活动读取材料在忽略目录 local/server-first-stage/tracker。

## #91 已有实现

- apps/server/bin/server.dart：独立启动、正常关闭、一次性密钥/身份初始化；配置路径相对配置文件，秘密不写镜像/日志。
- HTTPS 管理接口复用现有 Owner 保存、版本检查及持久回执；新增/修改、操作查询、响应丢失后去重、服务器身份均实际验证。尚未提供 Agent 协议；#93 接续受限接入，不能给 CLI 管理 Token。
- Linux 与 Mac 只读挂载密钥，缺失/错误时拒绝并保持原库。TLS 由独立合成 CA 签发证书，正常校验及未信任时拒绝均通过；未改全局信任。
- 为 Linux 补 renameat2 的 no-replace 文件发布；不覆盖已有文件、符号链接和空目录，不支持时拒绝。原 Windows/Mac 分支不变。
- 最小备份通过现有单机 App 同一加密备份接口产生，在另一密钥的新库恢复；新服务接入 Token/身份独立。完整备份界面及全部类型仍属 #101。

## 证据与实际范围

- Mac 服务包 7 项通过，新增进程修改场景单项复验通过；服务 bin/lib/test 静态分析无问题。
- Linux ARM64 容器服务包最终 7 项通过；核心文件发布专项另 1 项通过。Mac 同项专项 1 项与其静态分析通过。
- scripts/qa/check-server-container.py 实际删除首个容器，用原持久目录创建另一个容器：资料、服务器身份、回执保持，同一写入重试仍只有一条，TLS 验证开启。脚本正常结束，所属容器与临时目录已回收。
- 独立服务进程实际经历启动、保存、退出、重新启动、查询及修改；不是仅在同进程重新建对象。
- 初次 Linux 备份失败真实发现平台缺口，已修复 no-replace 发布并复验通过，不把首次结果写作全绿。
- 初次 TLS 合成证书在 Mac 上失败，改为独立 CA 与服务证书后通过，未放宽证书校验。

日志在 local/server-first-stage 下的 macos-tests.log、process-tests.log、linux-tests.log、linux-publication.log、container-recreation.log、docker-build.log、analyze.log。仅用合成资料；没有真实资料或生产密钥。Dockerfile 目前是验收镜像，不是 #102 最终发布。

## 下一步

1. 从 #92 正常 App 的 WorkspaceSource 接口接远程数据、连接配置及空白客户端拉取。当前 OwnerWorkspaceSource 直接持有 OwnerAccess；WorkspaceSource 已有稳定界面边界，应新增远程实现并保持现有展示/编辑器。main.dart 当前仍创建本地 DesktopBootstrap，需要在测试隔离的新入口接入，最终 #102 统一为服务器模式。
2. 接入方式与核心规则见 apps/server/README.md；App 必须保持正常界面和模板逻辑，不先做新的演示界面。新版最终只走服务器，开发期间不替换日常安装。
3. 按真实依赖推进 #93 与 #94；新 Agent 无上下文试用按 #93/#102 安排。后置事项不得变成首轮阻塞，也不能将首轮功能缺陷任意后移。

## 整体状态

仅 #91 达到当前阶段条件。#92–#102 未完成，没有正式预览包、正式安装或真实迁移。完整目标保持 active。
