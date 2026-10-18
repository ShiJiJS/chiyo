# Round05 Windows 0.4.0+7 预览交付

此为历史交付记录；最新0.4.0+8及超时修复/进程死亡验收见[新交付记录](round05-windows-timeout-delivery.md)。以下来源与哈希保持原口径。

2026-10-18。主会话独立开发，无子Agent；服务器同步暂停，Mac与双向恢复延期。

主集成源码为`3ca74651175deb34edfc9258e91cf3d6ae120014`，包含D8持续执行/生命周期和D9完整备份/所选字段转换；关联PR32仍为草稿。构建时源码干净，本记录随后补入，不改变所交付程序。

## 本地交付物

- ZIP：`build/windows-preview-round05-3ca7465/agent-info-manage-0.4.0+7-dev.3ca74651175d-windows-x64.zip`
- 大小：52,802,631字节，约50.4MiB；Windows x64，未签名开发预览，111个清单内文件。
- SHA-256：`eb2e7ca33ccecb0a6ae7e922a3a10b5ab21a41be73e3bbccee767c97e0af7fc5`
- 解压应用：`build/windows-preview-round05-3ca7465/AgentInfoManage/app/info_desktop.exe`，保留全部相邻文件；CLI/worker、SDK-free配置生成器、诊断、许可和说明随包。

未发布GitHub Release、未启动用户实际应用/资料库、未安装或信任Codex配置。先用于虚构资料验收，切换前按README保存独立备份并退出旧版。

## 本次确认

主集成重新完成349项（CLI54/Core130/Storage61/Desktop104）、严格分析及Windows Release编译，零跳过。应用旁与CLI旁worker哈希一致，随包Skill参考存在。ZIP解压到中文/空格临时路径，在子进程PATH不含SDK/Git的条件下，11项实际CLI/hook及配置生成验证通过；真实SQLCipher4.19.0/当前用户DPAPI诊断通过。111个文件校验值与ZIP/sidecar核对一致，QA localhost容器已移除，测试进程退出。

此前固定实现源码f4a2f41的原生备份迁移三轮、CLI宿主/独立AOT适配器/实际OpenSSH三轮、实际旧0.3.1代码创建库/备份的schema12→16及格式3恢复通过。schema13原生UI升级场景与旧代码实际创建库场景分开记录。原生测试文件选择器注入路径、通知/托盘为inert，未冒充OS对话框或系统点击。40张备份/迁移离屏图及D8/D9原始失败/通过证据已合入，主会话自检，没有独立Agent评审。

原字节打包日志、原包manifest与核验摘要见`evidence/windows-round05-delivery`；D8/D9固定来源详情见各自实施记录与verification.json。

## 仍开放

- #30：曾有一次原生短SSH完成状态超时，缺阶段证据；增强诊断后的多轮及60次额外短任务未重现，不能据此声称已定位原因。另有真实Codex安装/信任联合验收，未调用模型或改用户配置。
- #23：实际Windows系统通知点击仍未验成，原失败保留，没有伪造回调或修改系统设置。
- #18：干净机器、系统集成及用户联合验收仍待，SDK-free子进程PATH检查不等于全新系统或实际安装器；本包没有安装器/签名/自动升级。
- #17/#19及相关Mac适配：实际Mac/双向恢复后续安排。本轮不继续服务器同步。

这些缺口不隐藏在测试总数中；Windows主要实现和可复查预览已交付，整体发行验收尚未全部完成。
