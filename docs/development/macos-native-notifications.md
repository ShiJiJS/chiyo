# Mac 原生通知权限、系统抑制和真实点击（#47）

2026-10-22后续：[已有通知允许的复用及抑制兜底](macos-notification-reuse.md)确认同一
合成身份在新构建中仍为authorization2、权限动作0；仅发一次前台通知，系统抑制时
手动定位/批准/撤销通过，真实通知点击仍未完成，#47保持1/5。另发现并修正
[审批筛选计数](macos-inbox-status-counts.md)，不把这项修正当作通知点击已通过。

2026-10-21，独立 `codex/macos-adaptation`。QA 源码 `4e54b3a`，
Mac 设置文案修正 `0911e97`。
[原始记录、观察器源码、界面和逐文件摘要](evidence/macos-native-notifications/verification.json)。

## 本轮实际结果

宿主 macOS 27.0.1 / 26A434、arm64。固定 QA 身份
`org.shijijs.agent-info-manage.qa.notifications20261021`，显示名“Mac 通知合成验收”。
二进制 SHA256 `0f7c629eacc81c84d325c42abed88a0c6bd6ba6b258a85056980c5fa44186272`。
Release 使用生产 bootstrap、SQLCipher、原生通知桥和完整随包工具；仅合成资料及内存密钥。
副本原生修改只记录真正执行的通知 API / delegate，不注入点击或改变路由。

1. 启动时权限未决定，原生 authorization=0；权限操作和通知提交均为 0。
   通过实际设置页按钮触发系统提示，点击系统“允许”后 authorization=2、
   应用状态 enabled，权限动作计数恰为 1。
2. 准备 25 个普通字段申请，先用真实界面留下不匹配的旧搜索，并切到其他页面。
   只提交一次 foreground 通知；原生 submit / accepted / willPresent 均携带同一身份。
   没有为凑结果重复发送。
3. 系统日志明确记录 `muted by display state (displayMirrored)`，通知进入 history，
   `canDisplayWhileCenterIsClosed: false`。实际系统设置“当镜像或共享屏幕时”为
   “关闭通知”。没有修改该全局偏好，也没有把 API accepted 当作横幅已显示。
4. 用户随后报告在通知中心点击了该测试通知。原生 `didReceive` 确认 default action，
   notification UUID 与请求 ID 和提交时完全相同；Dart 真实 `openApprovals` 事件也收到同一 ID。
   UUID 为 `265CC46E-BBA7-4B64-B667-8EEACCCEA38B`，请求为
   `pVdyVDzgPBzvhtNtYh4kYnFVM892DsaCH_apnK0JE5s=`。
5. 这次点击发生在驱动的 15 分钟等待上限之后。原始 `complete: false` 和
   `Operator/OS deadline: genuine system click foreground` 原样保留。
   点击证明系统通知真实存在且原生和 Dart 事件正确传递；驱动没有在点击后自动断言
   搜索清空、翻页和详情显示，因此不能把整个两场景工作流记为通过。
6. 实际 CUA 手动清空搜索、翻到 4/4 后，同一申请仍在收件箱且可查看详情，25 条仍待处理、
   0 条已处理。此截图证明手动兜底，不替代通知自动定位证明；没有批准任何请求。

应用最后通过实际 ⌘Q 退出 0，资料库关闭一次、Flutter 异常 0。
9 个依赖/分析/构建/签名准备阶段均退出 0。严格分析及 12 项相关导航/runtime 测试通过，
这些自动测试与真实系统点击证据分列。

## 产品文案与验收边界

Mac 设置现明确提示专注模式、屏幕共享和通知设置可能抑制横幅，仍可到通知中心或
“访问审批”查看请求。该文案晚于本轮测试二进制；没有声称已包含于 `4690e79` ZIP。
非 Mac 文案保持原值。

#47 的固定身份、真实显示/点击及无回调注入条件已有本轮证据，记为 **1/5**；仍为 OPEN。
其他复合条件保留未勾选：拒绝/不可用及系统设置变化、关窗后台显示与点击、点击后的
实际搜索/筛选清除与非首页定位、凭据/文件/连续/旧请求，以及投递失败和免打扰的剩余组合。
用户对 Keychain 拒绝测试的免除不自动更改通知权限规格。
也未覆盖最终普通安装包身份、签名升级、干净用户或其他系统版本。

## 清理与复跑

这轮 QA 应用已退出并注销，生成 app、Flutter 编译缓存、合成库和私密 controller 已删除。
验收目录只保留一份最新生产解包应用，生成 dSYM 为 0；保留日志、固定源码及失败事实。
全量系统日志可能含其他 Focus 元数据，不上传；发布的系统日志仅为带原行号的目标摘录。
通知中心快捷键尝试未生效，已恢复原“无 / 未勾选”；屏幕共享通知偏好未改动。

后续复跑使用固定身份和全新输出目录，先协调操作时机；一次 gate 只发送该场景的一条通知。
后台场景本轮未发送。不要重新启动本轮已经清理的旧 app，也不要通过注入事件补成通过。

```sh
.tools/qa-python/bin/python scripts/qa/macos-notifications-ui.py \
  build/macos-adaptation/NEW_NOTIFICATION_UI
```
