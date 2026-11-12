# Mac 本机开发

需要 Apple Silicon Mac、完整 Xcode 和 Git。项目使用 Flutter 3.47.7 / Dart 3.13.5，固定 Flutter 提交为 `abaf9c523780a608bd46686fd5e53740a07077f8`。

SDK 位于 `.tools/flutter`，包缓存位于 `.cache/pub`，临时输出位于 `.cache/tmp`。这些目录由本机 `.git/info/exclude` 排除。启动脚本仅为当前进程配置 PATH 和 Apple 工具链。

## 准备与运行

在仓库根目录执行：

```sh
./scripts/dev-macos.sh setup
./scripts/dev-macos.sh doctor
./scripts/dev-macos.sh check
./scripts/dev-macos.sh run
```

`setup` 下载固定 SDK，并按锁文件解析依赖。独立服务端和新增共享包可在各自目录通过 `dart pub get --enforce-lockfile` 准备依赖。

`check` 检查 `info_core`、`info_cli`、`info_storage` 和桌面端。涉及远程服务时，还需在 `packages/info_remote`、`packages/info_workspace`、`apps/server` 分别执行 `dart analyze --fatal-infos`，并运行存在的 `test/` 测试。

直接调用本项目 SDK：

```sh
./scripts/dev-macos.sh flutter --version
./scripts/dev-macos.sh dart --version
cd packages/info_core
../../scripts/dev-macos.sh dart test
```

正常客户端支持加密本地库及可选服务器同步，已有服务器连接也可继续使用。接入与维护见 [服务说明](../../apps/server/README.md) 和 [维护说明](../../apps/server/OPERATIONS.md)。界面隔离预览使用 `./scripts/dev-macos.sh preview`，不替代正常客户端的运行验证。

首次空安装显示本地使用或服务器同步引导。服务器只填写 IP/域名和端口；App 自动记住证书，未初始化时设置知予连接密码，已初始化时登录，已记住的有效连接直接复用。引导不在日常设置中重复出现。

设置 → 存储与同步使用「本地模式 / 服务器同步」二选一。选择本地模式立即停止同步并保留两端资料；选择服务器同步后填写连接并确认，连接成功才启用。顶部用一个同步状态显示进度和刷新入口，不再同时显示“本地”。重新打开应用沿用已保存的模式。

访问审批、录入提案和授权历史来自当前模式对应的服务：本地模式为本机，服务器同步为已连接的 NAS。旧申请仍在原服务，切回该模式可继续处理；不会随资料复制或自动批准。新聊天的 CLI 默认目标与当前模式一致，既有聊天仍绑定原服务。服务器待办读取失败不切换成本机的空列表。

本地同步的自动验证使用临时 SQLCipher 库、独立 HTTPS 服务及合成密钥，不连接 NAS，也不使用系统钥匙串。可在 `apps/desktop` 运行：

```sh
../../scripts/dev-macos.sh flutter test test/server_setup_flow_test.dart test/setup_configuration_preview_test.dart test/local_library_sync_test.dart test/local_sync_settings_test.dart test/workspace_app_test.dart test/remote_library_cache_test.dart
```

其中定时同步通过可控计时器触发，不必等待一分钟；中断测试保留原操作、加密传输文件和独立上传/拉取进度。仅有这些测试通过不代表统一原生界面验收或正式安装已经完成。

## 构建与接入

从干净、已提交的源码构建到新的输出目录：

```sh
python3 scripts/qa/package-macos-isolated.py build/macos-adaptation/my-release
```

构建器验证签名、载荷、配套 CLI 和加密存储。源码检查、打包检查和实际系统交互分别验收；任务状态以 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues) 为准。

生成独立 Codex 运行材料：

```sh
./scripts/dev-macos.sh bundle /absolute/new/codex-bundle
```

这只准备材料。接入说明见 [Mac 接入](../../integrations/codex/MACOS-INTEGRATION.md) 和 [服务端版接入](../../integrations/codex/REMOTE-INTEGRATION.md)。

截图、日志和一次性检查产物放在 `build/`，任务结束后清理；个人资料、备份和已安装的运行材料单独管理。
