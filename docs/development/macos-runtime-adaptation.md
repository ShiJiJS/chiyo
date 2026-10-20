# Mac 凭据执行与普通附件适配

开发分支：`codex/macos-adaptation`。2026-10-21 已保存原有适配并整合固定主分支 `b37f96a089d6d4a0a9f872bd667be0c6b037f975`，合并源码及四包/Release 验证见 [主分支整合记录](macos-main-integration.md)。下文 2026-10-20 的实机证据仍仅代表原 `0855120` 基线上的适配，不自动扩展到新包。环境准备记录见 [macOS 本机环境](macos-local-setup.md)。

## 当前实现

- Mac 使用 Darwin FFI 核对 PID/启动时间、POSIX 会话与进程组。worker 先等持久登记确认，目标暂停装载后再核对实际身份；kqueue 保留短进程及信号退出结果，避免与 Dart 的 SIGCHLD 回收竞争。
- worker 随 Runner 构建编译、单独签名，并继承应用沙盒。worker 仅为构建宿主架构，当前设备为 ARM64；Flutter 默认 Runner 含通用壳体，不代表随包 worker 可在 Intel 上运行。Intel、完整通用二进制发行、Developer ID、公证与其他设备安装不在本轮已验证范围。
- 文件材料的目录为0700，文件为0600。核对本用户、ACL、硬链接数、设备/inode/创建身份；不跟随链接，不递归清理，不删除未知子项。Windows 原生驱动保留。
- Mac 启用可复用凭据执行与普通附件交付；焦点填充仍只在 Windows 宣告。SSH 接收器固定到本机独立验证的 Apple `OpenSSH_10.3p1`，Windows 原版本限制保留。其他 SSH 版本拒绝，升级后须重新验收。
- Mac版本探测为独立子进程，隔离用户认证环境，最多等待30秒且输出上限64KiB，超时/超限回收探测进程。首次解包AWS工具时曾超过旧5秒限制；6秒延迟与无限输出回归已通过。Windows仍保持原5秒路径。
- 系统面板支持普通附件、known_hosts 和另存；另存通过 native 创建同卷 replacement 目录，再由Core完成完整性校验及不覆盖发布，避免要求对用户选择文件的任意同级路径写入。启用应用沙盒的本机网络客户端能力以访问 loopback 接收服务，未移除沙盒。

进程组与文件释放的含义见 [ADR0013](../adr/0013-macos-runtime-lifetime.md)。本轮不迁移生产信息库，不接入真实服务或凭据，不安装 Codex hook。

## 已完成的独立验证

原始日志保存在本机忽略目录 `build/macos-adaptation/`，不将测试密钥、数据库和私密会话材料提交。

- `core-final-02.log`：核心270项通过、6项跳过；`owner-export.log`、`tool-probe-02.log` 严格分析通过。另存原文、空文件、替换目录、完整性/IO/源事务失败、目标竞争不覆盖、慢版本探测及超量输出回收独立通过。
- `storage-full.log`：真实SQLCipher存储148项通过、12项跳过，包含文件占用后路径释放、已打开描述符仍可读取、加密重开与交付登记。
- `ssh-native-02.log`：系统 `/usr/bin/ssh` 经真实 worker，协议1与2均通过；正确私钥/确认主机成功，错误私钥/未知主机/错误主机密钥拒绝，字面远程参数、重复调用和清理通过。接收端为仅监听127.0.0.1的合成 Paramiko 服务，无真实账号。
- `gh-aws-native-final.log`：本目录内的真实GH 2.102.0和AWS CLI 2.38.1共4项通过。GH仅向GitHub提供假Token，收到401且无本机账号回退；AWS向loopback接收端完成SigV4签名核验、合成读写、错误秘密拒绝、独立操作及文件清理。
- `worker-lifetime-02.log`：登记前EOF不运行目标、第二道门保持目标暂停、任务等待同组后代、worker强制结束后仍观察到后代存活，3项通过。
- `final-check.log` 的CLI部分67项通过、38项跳过，严格分析通过。`cli-full.log` 首次与Release编译并行的3项时限失败，在单独重跑及本次完整回归中均未重现。
- `desktop-final.log`：严格分析通过，界面测试154项通过、4项跳过；Windows焦点填充原生成功路径仅在Windows执行，Mac明确验证其能力不宣告。
- 四包自动化合计639项通过、60项跳过；另有真实接收器6项及下述原生窗口自动验收1项通过。默认跳过项不视为通过，真实接收器通过的是明确给定可执行文件及合成接收服务的另一次运行。
- `build-release-final-04.log`：最终Release构建成功，75.4 MB，`codesign --verify --deep --strict`通过；签名仍为本机开发用途，不能当作发行包。
- `native-sandbox-final.log`、交互验收后的 `native-sandbox-after-ui.log`：真实签名Debug窗口、独立加密库、随包worker与系统SSH通过。覆盖编辑器保存/另存、实际审批组件、0与1两个退出码、防重放、独立进程组、清理、原文领取/释放、历史执行回执、凭据与字段分别撤销；此模式使用测试文件路径替代系统面板，不能算原生面板通过。

## 原生界面验收（2026-10-20 完成）

使用 `macos_workflows_manual.dart` 的普通 `WidgetsFlutterBinding` 启动真实应用，通过 Computer Use 操作；仍使用隔离加密库、合成密钥和仅监听 loopback 的测试服务。`native-live-01.log` 的检查结果为 `PASS`，runner 正常退出0。验收记录及文件摘要保存在忽略目录 `build/macos-adaptation/manual-ui-01/acceptance.json`。

- 实际点击批准及二次确认，界面正确列出凭据15分钟与普通附件8小时两项独立许可。
- 两次真实SSH操作分别返回0与1，清理完成；逐次记录、冻结计划及完整执行回执均在实际窗口中核对。重复操作不重新启动。
- 原文领取内容一致，重复领取保持同一交付编号；显式释放后路径消失，历史显示“已释放”。
- 在界面中撤销凭据使用许可，新执行返回 `grant_revoked`，附件许可仍有效且可再次领取；再独立撤销附件许可，新领取返回 `not_authorized`，受管副本回收，界面显示“已失效”。
- 同一普通应用窗口中实测 `NSOpenPanel` 取消及重新选择。取消保留原附件版本；选择项目内、应用容器外的 `synthetic-简历.pdf`，编辑器显示待保存，保存后产生版本2。
- 实测 `NSSavePanel` 取消及容器外另存。取消保留版本2；另存到 `manual-ui-01/owner-live-01.pdf`，界面显示成功。导出与外部原件逐字节相同，均为7字节，SHA256为 `d9612a8c5bde658ae302a69fb29555c064c1a3af326725fca2eaba4bb7290038`。保留了沙盒及同卷原生暂存方案。
- 新验收入口和集成测试严格分析通过；界面验收后再次运行原生自动工作流，1项通过。

此前 `native-interactive-02.log` 在widget测试预先开启框架语义、原生观察器随后连接的路径触发Flutter引擎辅助功能桥崩溃；测试改为由原生请求语义。`native-interactive-03.log` 中真实选择和另存已成功，但集成测试宿主无法完成后续Computer Use点击，最终超时，保留为失败记录。后续交互验收改用上述普通应用入口，完整操作期间未再出现崩溃；这不表示修改或修复了Flutter引擎本身。

真实通知权限及投递、备份系统面板、Codex生命周期仍需各自验收。GH/AWS的接收器测试来自独立CLI，不把它当成这两种工具的全部Mac桌面路径访问已经验收。

## 重跑原生工作流

```bash
# 独立加密库、真实原生窗口与worker；文件选择器使用测试路径
.tools/qa-python/bin/python scripts/qa/macos-workflows.py --automatic
# 普通应用：实际审批/历史与系统面板，需要桌面已解锁
.tools/qa-python/bin/python scripts/qa/macos-workflows.py
```

runner自动生成一次性SSH密钥、loopback服务和私有测试参数，结束时只停止自己创建的接收服务。默认交互模式预置合成附件，按 `MAC_QA_PHASE` 批准请求、查看执行回执、分别撤销凭据与字段许可。`MAC_QA_RESULT=PASS` 只表示这些程序化断言通过；系统面板和目测结果需另行记录。随后可在信息库实际更换合成附件、取消和完成另存到本项目 `build/macos-adaptation/` 的新文件，并核对导出字节。检查完毕后，在 `MAC_QA_ROOT` 目录创建空的 `finish-qa`，关闭本次隔离库并退出。材料都留在项目忽略目录或本应用隔离的测试临时目录，未读写生产资料库。

## 本地接收器工具

- GH位于`.tools/gh-2.102.0/gh_2.102.0_macOS_arm64/bin/gh`，来源为[官方2.102.0发布](https://github.com/cli/cli/releases/tag/v2.102.0)，下载SHA256与官方Release API中的digest一致。
- AWS位于`.tools/aws-cli-2.38.1-package/aws-cli.pkg/Payload/aws-cli/aws`，从[官方固定版本包](https://awscli.amazonaws.com/AWSCLIV2-2.38.1.pkg)解包，`pkgutil --check-signature`核对AMZN Mobile LLC及Apple公证；未运行系统安装器或修改全局PATH。官方版本选择方式见[AWS说明](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-version.html)。

## 重跑接收服务

项目局部Python虚拟环境可安装 `paramiko==5.1.0`，不修改系统Python。启动时使用不存在的目录：

```bash
.tools/qa-python/bin/python scripts/qa/macos-ssh-fixture.py build/macos-adaptation/ssh-next
```

服务输出本次端口；将目录、端口、`/usr/bin/ssh` 分别传给 `D7_SSH_FIXTURE`、`D7_SSH_PORT`、`D7_SSH_EXE`，再用 `scripts/dev-macos.sh dart test test/ssh_receiver_native_test.dart` 在 `packages/info_cli` 重跑。停止服务只结束该测试服务；测试目录保留为本机诊断资料。
