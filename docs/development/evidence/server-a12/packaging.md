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

`12bc8785` 配套候选也已实际构建通过。用 `/usr/bin/open -n` 启动其中真实签名 App，明确指定新的 `a12-native-12bc8785` 空配置；同包CLI使用同名配置观察准确PID进入running，正常quit返回exited并确认该进程已结束，exitCode按Darwin事实保持null。没有配置服务器、连接日常资料或请求钥匙串。日志 `a12-native-package.log` 与 `a12-native-package-result.json`。启动早期控制登记尚未建立时先返回unsupported_version，最终明确running后才退出，未把早期结果算就绪。此检查仅证明真实AOT入口和退出通道，不是界面内容、真实通知或联网业务整体验收。

## 接入说明与配套工具核对发现的遗漏

正式凭据/附件参考仍带旧“App重启结束许可”和“Agent不能上传文件”说明，已按服务器实际能力修正，并让读取期限以真实审批返回为准。仅修改仓库随包Skill模板，未改个人安装、信任或全局Skill。

继续核对发现服务端不会提供客户端可执行路径，远程CLI却未添加本机工具观察；Mac材料核对又只允许最初两篇参考，会将现在合法声明的新增参考拒为不一致。已补：

- Mac远程CLI capabilities用原工具核对代码添加current_device工具位置；服务端响应仍不包含设备路径。
- 外部CLI与准备后的运行目录只引用经原清单核对的同源App，不复制整套大工具、不搜索个人安装或PATH；复制的CLI摘要必须与该App对应程序相同。App移动、版本不符、原程序被修改均明确不可用。
- 准备命令自动保存公开工具引用，注册摘要包含该引用；不含Token、材料或聊天证明。
- Mac材料核对保留必需文件，并核对清单声明的每一篇合法参考；未声明、篡改、重定向的文件仍拒绝。

最终CLI相关21项通过，包含材料核对、App工具、准备运行包、注册、同源/错版/移动/篡改检查；Mac及Linux服务相关各3项通过，服务只提供能力、CLI才提供当前设备观察。相关8个CLI文件及服务测试分析无问题，早期5条brace提示已修正。日志 `a12-local-tool-discovery-final.log`、`a12-device-tool-capabilities.log`、`a12-device-tools-linux.log`、`a12-local-tool-discovery-analyze-final.log`、`a12-device-tools-server-analyze.log`。

另用新核对逻辑实际读取12bc8785包的完整清单与工具字节：配套材料verified、3个工具均可用、源引用提交匹配，`a12-real-package-tools.log`。它证明修正后的读取逻辑能核对真实包，不能冒称旧包内的旧CLI已更新。最终需再次打包，并在提取候选上验证真实准备程序生成引用及完整流程。

先实际运行同源打包并修正构建问题；之后在同一候选上连续检查完整业务、空白客户端拉取及获准的无上下文 Agent 试用，完成清理和最终范围报告。日常安装、真实资料及个人钥匙串不变，#103–#105不推进。

最新连续业务与无上下文试用、发现问题及后续修复见 [candidate-workflow.md](candidate-workflow.md)；7a056395构建通过不代表这些新修复已包含在旧包中。
