# Mac 本机预览安装与升级约定（#42 / #50）

当前支持本用户的 Apple Silicon Mac 开发预览，采用本机 ad-hoc 签名。
不宣称公证、其他机器 Gatekeeper、Intel 或自动更新已通过，不以本机验收代替
干净用户验收，也不要求为本机使用购买签名服务。

## 固定身份及资料

保留既有 `com.example.infoDesktop` bundle identifier。它虽然来自最初工程，
已经关联本机资料，不能只为名称美化而换成新容器。Keychain service 固定为
`org.shijijs.agent-info-manage.database`，account 为 `local-database-v1`，
沿用生产 `NativeDatabaseKeyStore` 的 legacy Keychain 查询，不随安装路径和版本变化。

普通入口在沙盒 HOME 的 `Library/Application Support/AgentInfoManage` 开库；
本机对应 `~/Library/Containers/com.example.infoDesktop/Data/Library/Application Support/AgentInfoManage`。
移动/清理应用不删除该容器或密钥。改变身份前，必须另有实测的原资料迁移或完整备份恢复路径。

相同 bundle identifier 不保证不同 ad-hoc 签名自动获得旧密钥访问权。
升级可能需要主人在系统提示中重新允许；普通启动不主动弹密码框。
遇到“无法访问系统钥匙串”，先保留原库和可用旧版，再从应用的“请求钥匙串访问”
入口发起系统请求。密码只由主人输入；不放宽 ACL、不导出数据库密钥，
不以新密钥或空库替代失败。

## 稳定安装位置

用户要求所需文件留在当前项目，本机完整预览包固定放在：

`/Users/jiangxinyi/Documents/Project/agent-info/local/中文 Mac 预览/AgentInfoManage`

打开 `app/info_desktop.app`。`cli/`、`diagnostics/`、`notices/`、`provenance/`、
`manifest.json` 和接入说明与 App 一起保留，不单独搬走 App。本机 `.git/info/exclude`
排除 `/local/`，不提交程序或用户资料；后续构建清理须保留这个安装目录。

2026-10-21 已将 `issue50-package-10` 唯一完整解包目录整体移动到这里，未复制第二份应用，
未覆盖原资料。版本为 `0.4.0+12-mac-dev.4690e79357bb`，来源
`4690e79357bb728da22193d8dadd6dc8a8ce2ce6`。旧验收目录路径不再是当前入口。
原 ZIP 保留，SHA256 为
`0bebec70ba5860b25592024f8f6f00760b587ea91ef4c0d77c0fb0940bce360a`。

App 与随包 CLI 运行不要求 Xcode、Flutter 或 Dart。开发者的测试驱动可能使用 SDK，
与随包程序自身依赖分开记录；限制 PATH 不能替代干净用户验收。

## 升级和回退顺序

1. 在可正常使用的旧版中导出完整备份，另存恢复密钥，确认都成功保存。
   不把它们提交到 Git 或证据；保留旧 ZIP 和摘要。
2. 使用“完全退出”、应用菜单退出或 ⌘Q，确认原进程和本机监听均结束。
   红色关窗是后台隐藏，不能据此替换正在运行的应用。
3. 新 ZIP 先解包到新目录，核对版本/来源、完整载荷、权限/内部链接和签名。
   不逐个混合覆盖，不关闭 Gatekeeper 或 Sandbox 绕过问题。
4. 应用停止后整体替换稳定目录中的完整 `AgentInfoManage` 目录。
   验证期间保留完整旧目录，结束后清理重复 app；不删除唯一备份。
   安装过程不移动、删除或重建资料库及 Keychain 项。
5. 新版从生产入口读取原资料，必要时由主人处理系统授权。失败保留原文件，
   用旧版或备份恢复处理，不自动重置。旧版未必支持新版 schema，换回旧 App
   不等于数据库可降级；禁止手改 schema 或强行覆盖原库。
6. 如 CLI/hook 绝对路径改变，在新的独立输出目录运行 `cli/info-prepare-codex`，
   复查最终路径，再按接入流程更新。生成材料不等于安装/信任，不静默改写既有配置。

这套本机预览约定不等于升级已验收。旧 schema、签名变更、真实系统允许及最终包
仍按 #42/#50 联合实测。

## 当前准备快照

[原始准备证据](evidence/macos-installed-main/verification.json)记录载荷移动与签名、
系统 PATH 下的 SQLCipher 诊断和 GH/AWS 版本，以及移动后六项 AOT CLI/hook/worker 检查。
普通 `main.dart` 从稳定位置以系统 PATH 启动；钥匙串不可访问时显示真实恢复入口，
原数据库字节保持，服务未开放。

本快照尚在等待主人处理这次系统钥匙串提示，不声称正常主界面、完整安装/升级或
最终日常闭环通过；#50 第二条保持未勾选。后续允许、界面、退出和重开应追加独立记录，
不改写准备时刻的事实。
