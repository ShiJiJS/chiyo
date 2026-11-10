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

正常客户端连接独立服务器，接入与维护见 [服务说明](../../apps/server/README.md) 和 [维护说明](../../apps/server/OPERATIONS.md)。界面隔离预览使用 `./scripts/dev-macos.sh preview`，不替代正常客户端的运行验证。

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
