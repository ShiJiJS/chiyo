# 复用已有通知允许与系统抑制时的手动兜底（#47）

2026-10-22，基于6e6088a，仅Mac分支。用此前已允许的固定合成通知身份重新构建，
真实系统仍返回authorization2、运行状态enabled，权限接口调用0。没有访问Keychain、
发起新授权或改变用户专注/屏幕共享通知偏好。
[25份运行、源快照、系统摘录及清理记录](evidence/macos-notification-reuse/verification.json)。

普通固定4690e79应用的通知页显示“尚未开启系统提醒”，未点击其授权按钮；改用
已有真实通知允许的 `org.shijijs.agent-info-manage.qa.notifications20261021`，显示名
“Mac 通知合成验收”。新增 `--reuse-permission` 只检查现有允许；不存在时明确失败，
不调用requestAuthorization，也不伪造允许。内存合成密钥/独立SQLCipher库，不读普通库。

## 一次真实提交，完整点击流程没有通过

9个准备、严格分析、Release及签名阶段全部退出0。637项原始构建输入与6e6088a比较，
仅QA入口/协调脚本两项不同；原生副本只改固定QA身份并添加通知API/delegate被动日志。
原始二进制SHA256、全部输入摘要和实际QA源快照保留，不以提交后的QA补强源码代替。

CUA实际选已处理筛选、输入不匹配ASCII搜索，再切设置页。协调gate只触发一次原生
通知：UUID `4F24792E-A33E-4465-A5A8-48F60B138CA9`，目标请求
`71V0lClwI9G_y3ReU8fPTc7gZgYO3wBF8ejt3ttV5ZA=`，非首页offset24。
submit时appActive/windowVisible均true，API accepted=true。

系统目标日志确认送入history，并记录displayMirrored抑制横幅及专注模式延迟投递。
公开摘录只选本QA目标的行，保留原私有日志SHA256/行号；不上传完整Focus元数据。
没有把accepted或系统“presenting”日志当作用户看到了横幅/实际点击。

CUA能读取NotificationCenter的通知窗口，但没有展开包含本条history的入口；
ControlCenter观察超时后确认其PID437仍活着，没有重启服务。对照
[Apple键盘快捷键](https://support.apple.com/zh-cn/102650)尝试Fn-N，CUA返回
keyNotFound("fn")，未产生该快捷键；未更改系统快捷键或通知偏好，未重复发送。
真实didReceive/openApprovals回调0，已验证通知点击场景0，后台场景未发送。

随后实际⌘Q退出0，库关闭一次、Flutter异常0；协调驱动因complete=false而退出1，
保留terminatedBeforeComplete=true。没有等待新主人操作、强杀应用或把未完成改成通过。
后续QA补强只增加失败前快照/终止计数和非空activeTab检查，严格分析通过；没有补发通知。

## 手动兜底的实际界面结果

系统抑制后，CUA清掉筛选和搜索，手动翻到4/4，详情显示“合成通知聊天0”及同一请求
前缀71V0lClw。实际批准合成字段后，全部25/待处理24/已处理1；再撤销，详情和队列
都显示“已撤销”。此结果证明手动兜底可处理，不代替通知自动清搜索/筛选、自动翻页或
点击后定位的通过证据。界面观察以会话中原始CUA输出为源，JSON是明确标注的转录，
本轮没有另外保存原生截图文件，不冒充可独立复核的完整截图集。

中文typeText只留下0，paste没有形成预期查询，改用实际清空/分页；不将粘贴或输入源
名称当作中文IME通过。期间发现25条全待处理时“已处理”筛选显示负数，另按
[计数问题](macos-inbox-status-counts.md)修正，两个平台模式的新增回归先失败再通过。

## 清理和未完成范围

原测试App注销、生成App/dSYM/编译缓存、私有库和controller清理。随后以同一固定QA
身份的临时沙盒原生helper查询该准确UUID/请求组合，before0/after0；只证明查询时已
无该已投递项，不声称helper实际删掉一条。helper不申请权限、不发通知、不注入回调，
结束后注销并删除，没有保留额外App。源码/编译/签名/查询及移除记录保留。

普通固定App未替换，通知授权未申请，其页面恢复为原备份设置。系统允许复用成功
不使整张通知票完成：#47保持OPEN、1/5，前台/关窗后台真实点击、全类型/旧请求、
拒绝/系统变化和完整失败组合仍开放。Windows/main/CI未操作。

```sh
python3 scripts/qa/macos-notifications-ui.py build/macos-adaptation/NEW-notifications --reuse-permission
```

此模式仍需真实系统点击；没有可操作入口时保留未完成，不能靠文件gate注入回调。
