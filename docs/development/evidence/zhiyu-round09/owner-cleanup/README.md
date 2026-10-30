# 移除主人侧演示入口的检查

产品源码`447e9801`。范围与限制见[交付记录](../../../zhiyu-macos-owner-cleanup.md)。

- `tests.log`：38份相关文件，340通过、4项既有条件跳过。
- `analyze.log`：严格分析通过。
- `build.log`：固定目录ARM64普通预览构建。
- `app.json`：签名、沙盒、源码、内核摘要与启动观察；不证明完整S5或真实服务完成。
- `source-fingerprint.json`：210份lib/Runner文件与产品提交相符。
- `signing.log`：封装后deep/strict签名核验。
- `tracker-readback.json`：#1/#62/#64/#68正文精确回读，原勾选保持。
- `cleanup.json`：临时文件清理及唯一App/既有Release符号检查。

构建后的App.framework旧资源签名已重新封装，外层App保留原entitlements并通过deep/strict检查。本目录不保存App、dSYM、测试资料库或用户文件副本。
