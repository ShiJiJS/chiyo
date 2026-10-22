# 当前 Mac 工具历史独立重开与容量复验（#44）

2026-10-22，冻结 QA 源码 `7ed2de0d70fc3d7cbad5b1521bddea7053b97ae5`。
生产 Dart、macOS 原生实现及打包入口与候选 package21 的 `dd050f3` 无差异；
本轮仅增加工具 QA 的独立重开模式，没有修改产品或替换固定预览。
旧证据继续保留来源，本轮结果独立计数。

## 真实工具执行后，另一个 Release 进程读取历史

复跑：`python3 scripts/qa/macos-tools-ui.py <新输出目录> --bundled --history-reopen`。
输出目录必须在 `build/macos-adaptation/` 内。

完整 Release 先经生产工具装配，再移动到中文空格路径；strict 签名与沙盒
entitlements 通过。普通 Flutter 入口、生产 `DesktopBootstrap`、真实 SQLCipher、
托管 host 和随包 worker；仅合成库、内存密钥、随机 QA 身份。
启动只保留 HOME/USER/LOGNAME/LANG、系统 PATH 及本轮 QA 参数，不继承开发终端
的认证环境变量。工具材料隔离仍由生产路径执行，不读取个人登录。
本轮使用合成 owner API 批准，**不是再次实际 GUI 审批**。

第一进程 PID74650：

- 随包 AWS2.38.1 执行身份查询、写入、读回，退出均为 0；错误合成秘密退出 254。
  独立回环接收器完整验证 SigV4，3 次认证成功、1 次认证失败。
- 随包 GH2.102.0 使用无效合成 Token，实际 HTTP401、退出 1，明确不算成功登录。
- 5 个 operationId 重交均返回原 executionId，截止时间保持。
  四份 AWS 材料清理 complete，GH 为 not_needed，输出未包含合成秘密前缀。

第二进程 PID74686 独立打开同一合成 SQLCipher 库：

- 3 份授权的 ID、凭据版本、批准时间、固定截止和计划摘要保持；5 条执行的公开
  历史 JSON 完全一致，包括 ID、操作 ID、退出码、时间、清理状态，无新增执行。
- 三份旧授权均为 revoked；旧会话重复原操作返回 unauthorized/session_required，
  新聊天重用旧请求返回 unauthorized/session_mismatch；旧输出访问也被拒绝。
- 拒绝后再次核对执行历史一致，独立接收器计数及动作序列不变，没有重放 AWS 操作。

两个应用均通过生产 runtime.quit 退出 0，库各关闭一次、Flutter 异常 0，端口关闭。
这是自动触发的正常原生退出，不能算两次人工 ⌘Q 或真实 Dock 操作。
8 项准备、严格分析、Release、签名与 entitlements 检查均退出 0；669 份构建输入
与 Git 逐项核对，副本只改 QA identifier。
[22 份原始日志、结果、源码与摘要](evidence/macos-tools-history-current/verification.json)。
私密会话检查点仅在受限合成根内使用，未归档；测试根、接收器配置和源码副本已删除。
接收器按监督脚本 terminate，退出 -15 单列，不计为应用正常退出。

## 当前源码与准确 package21 CLI 的容量边界

从 package21 ZIP 只提取 `cli/info` 和 manifest，先核对完整 ZIP SHA256
`2030d3d50a35d181341ef761b45a6045f52814695a85847417e409738be3058e`，
再核对 CLI 字节 `bcbd7d56bdc54a66bfe86d6611cc0242dd7710e020c259b1f82efc680e27b1b2`。
当前源码复制到隔离目录，唯一修改是 QA identifier；锁定依赖与严格分析通过。
运行既有 `macos-file-capacity.py` 与 `macos_file_capacity_native_test.dart`，
采用真实 Debug 沙盒 Flutter、SQLCipher4.19.0、原生受管文件及四个独立 AOT CLI。
这不是最终 ZIP 的普通 Release 安装，也不是 Release 内存性能指标。

- 10 MiB 单文件接受，增加 1 字节拒绝且无预留；并发最后槽只成功一份。
  原件／草稿合计 100 MiB，提升正式原件不重复计数；删除后保留原件仍占额度，
  恢复不复制原文，满字节时空附件仍可保存。
- 200 份空暂存、32 个空草稿各达到上限，下一份拒绝；释放后可以重试。
- 活副本另有 100 MiB／32 份的资料库共享额度，两个会话共同消耗；超限返回
  delivery_capacity/operationClaimed=false，释放后另一会话用原失败 ID 成功领取。
  重查旧操作不多占额度。
- 44 份交付全部显式释放且原路径消失。同一应用进程关闭并重开库后，44 条历史保留、
  活副本额度为零、原件仍占 100 MiB；新连接不能复用旧批准。
- 最大文件与空文件实际 curl 上传回环接收器，逐字节一致；释放后再次上传退出 26，
  接收器不新增成功文件。输入原文件字节不变。

本轮独立完成 8 阶段、146 次 CLI 状态断言、44 份交付；Flutter／四个 CLI 全部退出 0。
三张生产容量组件渲染图已目测，分别显示 10 份／100 MiB、释放后 0 份、32 份空副本，
与登记数据一致；不当作完整设置页导航、系统面板或物理交互的证明。
Debug 沙盒为 true、deep/strict 验签通过，临时资料根和接收器关闭／移除。
[34 份当前容量结果、图像、输入与摘要](evidence/macos-capacity-current/verification.json)。
669 份复制输入、10 份 QA 直接源文件均与 Git 核对；临时编译入口仅存在于已删除副本，
没有留下冒充普通入口的 Debug App。

## 清理和剩余条件

两轮应用／dSYM／编译缓存、测试库、私密会话、接收器配置、提取出的 CLI 和源码副本
均已清理；删除范围分项记录，不清除 SDK。最终逐项复核固定预览 7971 项、strict 签名
和原 PID53592，保留运行资料、恢复备份与候选 ZIP。
项目 `build/`、`local/` 范围仅固定预览一份 App、生成 dSYM 为 0。

#44 保持 OPEN、3/6：本轮补齐当前实现的真实工具历史独立进程证据和容量影响复验，
没有提前完成最终普通换包后的同包联合条件。真实 GH 正向账号、最终普通入口／
Keychain 升级、其他系统及干净环境条件仍按原票据保留；不修改 main、Windows 或 CI。
