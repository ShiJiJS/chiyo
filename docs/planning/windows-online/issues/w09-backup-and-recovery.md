# Windows：接通现有备份和恢复流程

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：9。直接前置：[#111](https://github.com/ShiJiJS/chiyo/issues/111)、[#112](https://github.com/ShiJiJS/chiyo/issues/112)、[#113](https://github.com/ShiJiJS/chiyo/issues/113)。

## 做完后能做什么

Windows 能使用现有完整备份功能导出 NAS 资料、另存恢复材料，并在独立空目标验证恢复。

## 做哪些改动

- 接通 Windows 备份输出、恢复密钥保存及本机操作记录，沿用已有备份格式和发布/恢复状态机。
- 覆盖资料、凭据、附件版本、目录顺序、关联、回收和历史；恢复验证复用已有合成备份及独立空库测试能力。

## 完成条件

- [ ] 导出当前支持范围的完整加密备份和独立恢复材料，Windows 输出路径、原文字节和摘要正确。
- [ ] 合成备份在独立空目标恢复后，内容、身份、版本、关联和历史保持；错误密钥或非空目标被正确拒绝。
- [ ] 断线、文件占用、输出失败或 App 重开后核对原操作，不重复恢复，不覆盖已有文件。
- [ ] 恢复不复活旧许可、材料路径或副本；NAS 现有资料库不作为恢复测试目标，旧 Windows 测试库不自动合入。相关检查与明确未测项分别记录。

## 从哪里接续

- `apps/desktop/lib/workspace/remote_workspace_backups.dart`
- `apps/desktop/lib/workspace/remote_workspace_backup_outputs.dart`
- `packages/info_storage/lib/device_backup_operations.dart`
- `apps/desktop/windows/runner/backup_files.cpp`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W09 -->

