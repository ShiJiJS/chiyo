# Mac 真实备份文件面板验收（#45）

2026-10-21，独立 `codex/macos-adaptation` 分支，QA 源码
`f2b927d7de5b1a694dae5221f256ea77ab832d4b`。普通 Flutter binding 的
Release 应用通过 CUA 操作真实 NSSavePanel / NSOpenPanel；未替换面板返回值，
也没有使用 widget tester 或直接调用确认恢复来代替点击。
生产业务源码保持 `01c1f141d876a9d3c49c61c7fc3d1e572c432c5a` 的字节。
[原始记录、截图、源码与摘要](evidence/macos-backup-native-panels/verification.json)。

本轮依次完成：

- 恢复密钥另存取消，再通过系统面板保存到中文空格文件名；界面显示已另存。
- 备份导出取消，再导出格式 9 的 16,384 字节备份。
- 再次选择同名备份并在 macOS 确认替换；应用仍返回 `output_exists`，原备份
  SHA-256 保持 `ec5b4a56155b0221dd6f66c0c4964925b9e0f7e165c67f7b00787272aaaba`。
- 两次实际原生暂存目录的 `stat.st_dev` 均与所选输出父目录相同
  （16777230）；两次释放后目录均不存在。
- 独立空目标先取消选择，再通过系统面板选择实际备份和恢复密钥，检查预览，
  经 CUA 点击“确认恢复到空库”。界面显示恢复成功，信息库能看到两条资料和
  `synthetic after` 正文。
- 断言源合成密钥清零、目标密钥不同；版本与托管凭据、6 字节附件准确恢复；
  旧授权拒绝、待审批为空、交付历史无活 lease/会话绑定，新申请批准后可读。

8 个依赖/分析/构建/签名步骤均退出 0；应用通过断言后退出 0。
应用日志有 macOS 键盘布局警告，没有 Flutter exception 文本；该入口没有安装
Flutter 异常计数器，不能将文本检查称为 `flutterErrors: 0` 的计数证明。
QA 根目录、控制文件、生成的应用与构建缓存已清理并注销应用登记。
合成备份和恢复密钥只用于上述流程，完成摘要核对后删除，不提交原文。

源与目标切换由私有测试标记协调，使用内存合成密钥，不是两台设备或真实
Keychain，也不是最终产品整包。真实 Keychain 的独立恢复另见
[既有验收](macos-backup-recovery.md)。本轮只补齐实际文件面板这一项。

窗口放大后可见同名保护错误。CUA 滚轮及 PageDown 没有得到可确认的滚动结果；
恢复确认使用可访问性按钮点击成功，不声称按钮在初始窗口中完整可见。
物理滚轮、Tab/IME、各窗口尺寸的易用性仍归 #48 验收。
Windows 双向实机恢复、跨平台工具路径重新核验及 #50 最终整包联合验收未完成；
#45 保持 OPEN。

复跑时在仓库根目录执行，输出目录必须全新，并需要解锁桌面完成 CUA 操作：

```bash
.tools/qa-python/bin/python scripts/qa/macos-backup-panels.py \
  build/macos-adaptation/NEW_ACTUAL_BACKUP_PANELS_RUN
```

驱动不会替用户点击面板。`controller.json` 为私有协调文件，不上传；
其中根目录必须通过 `.qa-owner` 核验后才能写入 `switch-to-target` / `finish`。
