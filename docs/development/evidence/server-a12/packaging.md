# #102：配套候选构建（进行中）

2026-11-09。运行页面已接通并同步 GitHub 后，进入统一候选构建阶段。本文不表示候选已验收完成或正式安装。

## 当前变更

- Dockerfile 保留 `verify` 源码测试阶段，增加 `build` 和默认 `runtime` 阶段：Dart AOT 服务与原 SQLCipher 动态库，运行镜像不需要 SDK或源码。Debian 运行基础保留现有私有目录驱动所需的 mkdir/chmod，不用缺少这些正常依赖的 scratch 镜像。
- 当前源码构建的 Linux ARM64 临时 AOT 镜像已通过真实初始化、拒绝重复初始化且密钥不变、TLS 保存、正常退出0、删除容器并重建、资料和原操作回执保持。日志 `local/server-first-stage/a12-aot-build-first.log`、`a12-aot-container-recreation-first.log`。镜像标签明确是验证用途，源码尚有改动，不把它当作最终同源候选。
- App 正常入口支持 `--connection-profile <名称>`，在自己的私有配置目录下选择独立配置，不改 HOME、不读取其他配置、不用演示入口或额外资料库。选址与路径拒绝测试1项通过，相关静态分析通过。实际候选的独立配置启动仍待构建后验证。
- 更新随包 Mac 使用和 Codex 接入说明，移除旧版“钥匙串本机库、退出结束服务和授权、固定本机端口”的错误指引；改为服务器地址/Token、受限设备配置、服务器动态模板及 App独立退出。
- `scripts/package-server-first-stage.py` 要求干净的固定提交，隔离构建 Mac 完整包、同源 Linux 镜像、编译服务容器检查、镜像导出及可复现源码归档；候选清单记录版本、源码、镜像ID与交付摘要。`buildComplete` 与完整流程 `acceptanceComplete` 分开，不把构建成功算作 #102 完成。

## 接续

首次同源打包在依赖解析阶段失败：旧隔离构建只取了 `apps/desktop`，漏了现在 App 测试依赖的 `apps/server`，没有进入编译或产生可用 App。已补完整路径；失败目录 `build/macos-adaptation/server-first-stage-d22b4150` 保留日志，脚本已确认移除临时检出且未改变原预览。不把这次失败计为候选通过。

随后 `a0d16a13` 同源候选实际构建成功：Mac包签名、解压字节/模式/链接、SQLCipher诊断、提取后的CLI/worker、DMG挂载核对，以及同源Linux AOT镜像的初始化/重建检查均通过。产物在 `build/macos-adaptation/server-first-stage-a0d16a13`，清单明确 `buildComplete:true`、`acceptanceComplete:false`。这只是构建证据。

继续核对正式CLI `app status/quit` 时发现旧控制宿主仅由旧本机启动器安装，联网启动器漏接。因此该候选不得作为最终通过版本。已让正常联网启动器复用原 `MacDesktopControlHost` 和原退出提交约定；命名连接配置有独立控制登记，随包CLI可指定同名配置，不操作日常实例。登记不可用不阻止连接及菜单退出，命令仍只选择同包准确进程，不强杀。

补强后 App相关19项通过（新控制2、配置1、联网生命周期8、联网运行5、旧App控制3），CLI参数/无关进程2项通过。原Mac控制实际进程组9项通过；“其他平台返回unsupported”的1项在Mac按原条件跳过，不能称这组无跳过。相关Flutter6文件分析无问题。日志 `a12-online-control-final.log`、`a12-cli-control.log`、`a12-core-control.log`、`a12-online-control-analyze.log`。新控制测试使用真实私有TCP宿主及原生测试边界；退出提交存在但测试VM仍活着时，查询必须超时，不能假报OS已退出。首次补强遇到import放置编译错误，已修正，失败未计通过。

先实际运行同源打包并修正构建问题；之后在同一候选上连续检查完整业务、空白客户端拉取及获准的无上下文 Agent 试用，完成清理和最终范围报告。日常安装、真实资料及个人钥匙串不变，#103–#105不推进。
