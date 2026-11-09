# Windows：补齐文件管理、系统打开和 PDF 预览

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：5。直接前置：[#109](https://github.com/ShiJiJS/chiyo/issues/109)。

## 做完后能做什么

Windows App 能管理 NAS 上的附件和历史版本，另存到本机、交给系统应用打开、预览 PDF 并选择模板包。

## 做哪些改动

- 补普通附件另存、模板包选择和系统文件打开的 Windows 原生接口，复用已有选择器及操作协调器。
- 接入 Windows PDF 渲染和本机文件操作记录，保持上传、版本、回执及临时副本规则。

## 完成条件

- [x] 附件上传、替换、历史版本和原文字节/哈希一致；未发布成功不提前显示已另存或已打开。
- [x] 另存和打开结果可重开核对，同一操作编号不重复写入/打开；受管临时副本与用户另存文件分开处理。
- [x] PDF 页面与边界检查、损坏/加密文件错误准确，文字图片预览保持；模板包选择接入原预览和安装流程。
- [x] 相关接口、渲染与发布自动检查通过；computer-use 必要时可用，真实文件面板/系统应用点击的结果单独记录，未测范围不计通过。

## 从哪里接续

- `apps/desktop/windows/runner/backup_files.cpp`
- `apps/desktop/lib/workspace/owner_file_open_dispatcher.dart`
- `apps/desktop/lib/workspace/owner_pdf_preview.dart`
- `apps/desktop/lib/workspace/remote_workspace_file_actions.dart`
- `apps/desktop/lib/workspace/owner_plugin_picker.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。用户同意实际资料核对；保留原记录，只对本轮新建且可追踪的开发材料写入。旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 必要时可用，正式安装和用户认证仍最后集中；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W05 -->

## 当前实现

PDF 原生实现 `871a83f`，Windows 文件发布/系统打开与完整本票验证 `620bcbe`，见 [w111.md](https://github.com/ShiJiJS/chiyo/blob/620bcbe/docs/development/evidence/windows-online/w111.md)。真实 NAS 附件/版本/丢失回执/重开，原生另存/模板面板与记事本内容观察、6 项 core/20 项 storage/43 项桌面检查、分析和 Release 构建通过。真实面板发现的 NTFS 创建时间变化已复现并修正，未用编译代替功能结果。完整同版本包与主入口连续流程仍归 #116，未计作正式安装或全部原生主入口验收完成。

