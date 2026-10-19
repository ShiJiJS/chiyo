# Windows 0.4.0+9 开发预览

2026-10-20，由干净提交 `50e2c091824bc97436bd93607b3e22ed63f7aafb` 构建，版本标识 `0.4.0+9-dev.50e2c091824b`。这是供继续验收的未签名 Windows x64 便携包，#18/#23/#30 仍 OPEN，没有发布 GitHub Release、替换用户旧程序或迁移真实资料库。

## 本机交付物

- ZIP：`build/windows-preview-0.4.0-9-50e2c09/agent-info-manage-0.4.0+9-dev.50e2c091824b-windows-x64.zip`
- 同名 `.sha256` 文件与 ZIP 放在一起；完整展开目录为 `build/windows-preview-0.4.0-9-50e2c09/AgentInfoManage`。
- 应用入口：展开目录的 `app/info_desktop.exe`；保留全部 DLL 和 `data/`，不能只复制这个 EXE。
- 归档 **53,288,619 字节**；SHA-256：`83b19060c2454dd6eb15cf81ec55cdeeaabdff883d2b8e2ee748a163818bb164`。
- 清单 format2，登记 **113 项载荷文件**，逐项字节/摘要已再次独立核对。清单本身不列入自己的文件摘要。

包内应用、CLI、worker、焦点辅助程序和模板来自同一提交；采用协议v2/schema21、备份7/8/9。包括凭据期限内复用、有限范围本机焦点填充、普通文件字段/加密原文/交付与两份随包说明；通知回调身份修复也在此源码，但其新入口尚未完成真实显示/点击验收。界面沿用已确认的Round05，不因打包改变样式。

## 本包实际验证

`scripts/package-windows.ps1`完整成功退出0：四包严格分析、Windows Release编译，**668通过/19既有opt-in跳过**（CLI92/13、Core262/0、Storage154/6、Desktop160/0）。跳过项不算通过。全量日志保留包括Drift测试的调试提示，没有声称零警告。

随后将实际ZIP解压到中文/空格临时路径，核对全部清单、SQLCipher资产及应用/CLI的相同worker，限制子进程PATH为系统目录。实际AOT CLI/hook、SDK-free生成器及包内worker的**16项通过/0跳过**，包括部分批准/复用、会话/hook、焦点调用分支和普通文件领取/版本/共享/结束清理。SQLCipher4.19.0及当前用户DPAPI的独立合成探针通过。这16项与前述源码组重叠，不累加；受控服务/关联和假输入驱动不等于实际Codex或系统密码输入。

四份锁文件保持原字节，未升级依赖。测试解包目录在明确边界内清理，没有打开包内GUI、安装hook或修改用户配置。用户原0.4.0+8进程仍在原路径运行。首次本地包装器使用了不存在的PowerShell路径，未启动构建；改用实际发现的PowerShell7路径后成功，不修改系统执行策略。

## 继续验收

运行条件为Windows x64及兼容的Microsoft Visual C++ v14 x64运行库，不随包下载或安装。当前构建机已有开发工具；限制PATH的SDK-free验证不能冒充干净Windows机器。支持范围和使用方式见随包[交付说明](windows-delivery.md)。

试用新版前，由用户在旧版导出备份并单独保存恢复密钥、完全退出旧托盘进程，再完整解压新版并按支持流程启动。不要让两版同时打开同一资料库，不直接用旧程序回退打开已升级库。自动检查只用独立虚构资料，未迁移用户当前库。

剩余门槛：最终包真实GUI的各功能闭环与旧库/备份升级，通知新入口真实显示/点击及凭据/文件请求定位，用户安排的真实Codex安装/信任、隔离/共享、结束/恢复，以及干净Windows用户/独立机器。原生功能已完成范围见[#38](issue38-completion.md)、[#35](issue35-completion.md)；当前通知限制见[诊断记录](windows-notification-identity.md)。不提前关闭#18/#23/#30，不把源码原生测试或构建成功当作以上全部通过。Mac及服务器同步延期，无子Agent。

完整日志、manifest、归档摘要、重跑脚本和10份Git源码/依赖锁摘要见[证据清单](evidence/windows-preview-0.4.0-9/verification.json)。ZIP和展开程序保留在本机忽略目录，未上传二进制到GitHub。
