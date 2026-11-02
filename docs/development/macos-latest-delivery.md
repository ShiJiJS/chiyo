# Mac 最新版与本机清理（2026-11-02）

按主人要求，将最新修复打包成新版 App，清理可重新生成的开发文件和旧程序包，只保留一个最新版本的完整安装和压缩包。代码只同步 Mac 分支，不修改 main 或 Windows。

## 当前版本

- App/CLI：`0.4.1+13-mac-dev.642e36d74710`，Apple Silicon / ARM64。
- 产品源码：`642e36d7471007fc74b5967ec290f7c7254a0948`，分支 `codex/zhiyu-macos`。
- 固定入口：`local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app`。
- 唯一交付压缩包：`local/中文 Mac 预览/agent-info-manage-0.4.1+13-mac-dev.642e36d74710-macos-arm64.zip`。
- ZIP SHA256：`d0bec1b8b189979b42cd331c60690ec6731db67eeeebb41735f243fdb4741b9e`。

包括[试用报告](macos-app-trial-20261102.md)中 8 项修复；偶发花字依主人要求暂缓。打包前的 111 项针对性测试及桌面静态分析已通过。

本轮运行 `python3 scripts/package-macos.py build/macos-adaptation/release-642e36d7`，21 个阶段通过。包括 Release 构建、ARM64 与依赖检查、App/CLI 签名、归档解压后的逐文件核对、实际 SQLCipher 检查，以及随包 CLI/worker 检查。不是再次运行四包全部测试，也不是实际 AI 聊天或全部系统验收。

旧 App 通过配套 CLI 正常退出；新版完整目录换入后，7994 项文件/权限/内部链接与清单一致，严格签名和 ZIP 摘要再次通过。新版 `app status` 返回 `not_running`，本轮没有启动新版、打开原资料库或发起钥匙串授权。首次打开新版仍可能遇到 macOS 钥匙串提示；跨版本免提示问题没有解决。

## 清理结果

移除旧版 App、3 个旧版交付 ZIP、2 个旧程序回退归档、本次打包的解压验证副本、Flutter/Xcode 构建和 dSYM、已结束的项目专用临时测试、Dart 测试及编译缓存、旧的构建辅助脚本和界面截图输出。

删除文件逻辑大小约 9.94 GB；观察到磁盘可用空间增加约 10.05 GB。只清理本项目中确认可重建且未被运行进程使用的目录；未删除跟踪中的源码。清理后 Spotlight 仅找到固定目录中的一份 `info_desktop.app`，交付和构建目录中也没有额外 App/dSYM。压缩包只保留上述一个版本；程序内部的 AWS 依赖 ZIP 属于运行文件，不是旧交付包。

保留资料库、钥匙串、加密备份和恢复密钥、已授权的 Codex 合成项目及其原命令路径、现有接入材料、开发 SDK/工具、依赖下载和 Git 历史。用户 `.local/` 未访问或清理。

`build/macos-adaptation` 只余原已授权的 `issue49-codex-preparation-1`，防止破坏既有接入；其余构建过程目录已移除。开发环境仍在，下一次构建会重新生成已清理的编译缓存。固定目录中的 `开始使用.txt` 已更新。

打包与安装记录、清理路径和大小见[本轮记录](evidence/macos-latest-delivery-20261102/cleanup.json)；构建日志保留于固定目录的 `构建记录/`。本轮记录没有改写为完整功能验收通过，也没有据此关闭未验 tickets。
