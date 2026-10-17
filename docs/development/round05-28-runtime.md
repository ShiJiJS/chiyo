# D6 一次启动实施进度

主集成 `2062cbb` 已完成最终301项及各analyze、真实Windows AOT流程复验。现由主会话接续 #29 文件凭据；#28 Mac执行适配和 #30/#31 未完成项保持明确，见下方固定记录。

2026-10-17。Windows 字符串纵向里程碑已验证，详见[固定版本验收](round05-28-windows-verification.md)；全软件、Mac 执行适配与后续 #29–#31 尚未交付，本票仍保持 OPEN。用户要求当前会话继续，不再使用子 Agent；所有后续复核由当前会话自行执行，不能称为独立评审。尽量采用 CLI、自动化测试和离屏截图，仅必要时使用 Computer Use，使用后立即退出隔离应用及测试进程。

## 当前完成的增量

- 既有 WIP 先保存于 `bdcc09b`，再合入标题栏基础 `d2f4b0e`，不丢失暂停点。
- 实际受控子进程 + AgentClient 私有 loopback 接口复现运行中审计失败导致提前结束监护。红测试观察到子进程尚未释放而 drain 已完成；修正为 OS 启动后立即排空两条流、异常时继续等待实际退出。允许重试元数据报告，不重试命令。与原纵向流程共2项通过。
- 公开核心接口复现已提交但响应丢失后的重复报告被拒绝。相同状态和全部事实相同时幂等返回；任何进程身份/时间/结果变动仍拒绝。核心8项通过。
- 实际 JSON-lines CLI 子进程复现超长行没有协议错误码。改成解码前限制262144字节（含换行），超限整行丢弃；无效UTF-8和重复key逐行拒绝，之后正常目录和会话查询仍可继续。1项实际传输测试通过。
- 上述 CLI/Core 定向11项及两个 analyze 通过；桌面 analyze 发现的既有 WIP 格式提示已修正，后续复查。

红/绿原始输出暂存工作区 `.d6-*-red.log`、`.d6-*-green.log`。仅使用合成材料，没有读取真实账号或 Token。

## 当前主会话里程碑

- Windows 执行器先启动内部 worker；worker 加入独立 Job 后才创建获批程序。未启用 breakaway 或 kill-on-close；监护按活跃进程数等待完整进程树，不能把父命令退出当作结束。CLI 再持有经过成员校验的观察句柄，worker 异常时仍等待剩余树结束、记录 unknown。实现依据 [Microsoft Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) 与 [IsProcessInJob](https://learn.microsoft.com/en-us/windows/win32/api/jobapi/nf-jobapi-isprocessinjob)。没有新增强隔离承诺。
- 本机 SDK 的 dart.exe 中间启动层在 VM 退出时也结束其子进程；开发 worker 改为直接使用同一 SDK 的 dartvm.exe。正式包使用独立 AOT `info-runtime-worker.exe`，并已加入 ZIP、源版与 SDK-free Codex bundle 准备入口。
- 无秘密 journal 只记录 executionId、进程/Job 身份及状态，不写 Token、capability、完整输出或申请 env 值。Token 不创建凭据副本，清理状态为 not_needed。异常后从加密库重开只保留 unknown 等事实，不复活会话、额度或秘密领取能力；文件残留核查仍在 #29/#30。
- 实际 Windows 原生窗口 → 独立 JSON-lines CLI → 私有领取 → 真正 gh 2.102.0，携非空合成 Token 得到 HTTP401/exit1；字段许可仍可读取、SQLCipher/DPAPI 记录重开通过。再用 AOT CLI/worker 重跑通过。没有提取真实账号、真实 Token，未再次运行缺 Token 的账号查询对照。
- `gh --version` 的空环境在本机返回 OS87，且工具会写 device-id。版本探测已补最小系统加载位置、私有 HOME/配置/状态/工作目录；原生红/绿断言验证不再写 caller cwd。早期测试生成的三份 device-id 已逐文件移到忽略的 scratch，没有读取内容或纳入证据。
- 真实受控进程覆盖：父命令退出但 detached 后代继续、worker 崩溃、AOT CLI 强杀后仍排空输出、4MiB截断后持续排空、16个活跃槽位占用前拒绝、第17个许可保留、保留大小/mtime但修改程序字节仍拒绝且不启动。传输覆盖逐字节行上限、坏UTF-8/重复key后继续、私有响应丢失、占用后审计失败不冒称未用、字段显式null、输出游标显式null、幂等报告、UTC毫秒、跨会话/拒绝/撤销/到期。
- 审批 UI 保持 round05 的收件箱/纸张/244决定栏、650弹窗、四主题。完整程序、逐项参数、cwd、ID/version、planHash 和可复制申请结构可查；普通字符串不作为占位符替换。独立字段许可可在凭据失效时单独批准，也能去掉已经删除的字段。保存失败草稿保留、重试成功清除旧错误；已处理请求提供实际执行与清理四维事实、只读且自动刷新的执行记录，不展示原文或完整输出。完整筛选历史页与 Codex 生命周期仍由 #30 整合。
- r2 四主题/双视口共36张先行截图已自看，发现并修正重试成功后遗留红色错误；r3补执行记录，r4将事实行按原CSS字号/间距/分隔线复核。最终定向复核和整套检查还在进行，尚不据局部结果关闭本票。

## 未完成与范围边界

运行源码固定于 `bc02e5f`，整套299项/analyze通过，AOT CLI/worker 的真实 Windows 流程连续3次通过。补充测试及最后注入列间距对照为 `bb0bbab`，10项运行 CLI 与5项界面定向检查通过，46张最终截图已自行查看。原始证据和哈希见[verification.json](evidence/28-runtime/verification.json)。没有使用子 Agent；自检不写成独立评审。Computer Use 在用户追加要求后没有再使用，原生测试由脚本自动启动并退出，所有测试仅操作隔离库。

当前默认受管执行器只在 Windows 启用；其他平台在占用前明确拒绝，不消耗许可。Mac 进程树适配及实机验收仍是延期项，不能声称 Mac 凭据运行已经完成。文件交付和完整凭据备份分别属于后续 #29/#31。
