# Mac 桌面工具与附件验收（#44）

2026-10-21，当前源码 `7a33585`（产品 Keychain 修复 `86e35f3`），#44 保持 OPEN。

重新运行签名 Debug Flutter 沙盒应用自动工作流：

```bash
.tools/qa-python/bin/python scripts/qa/macos-workflows.py --automatic
```

**1 项完整原生工作流通过**。覆盖当前界面组件编辑保存/另存、实际审批、真实
随包 AOT worker、系统 SSH 的 0/1 两种退出码、防重放、执行回执、普通附件原文
领取/释放和两类许可分别撤销。使用实际 SQLCipher、临时测试密钥和只监听
loopback 的合成 SSH 服务；未打开生产库。

本机未能将应用自动置前，原生测试仍完成。自动模式用测试路径替代系统文件面板；
这份结果不能证明当前版本的 NSOpenPanel/NSSavePanel、实际可见页面、
真实 Keychain 或最终发行包已通过。旧版本的真实面板证据仍见
[Mac 适配记录](macos-runtime-adaptation.md)，不自动扩大到新包。

[原始日志与范围清单](evidence/macos-tools-files/verification.json)保留构建警告、
前台失败提示、测试阶段和最终结果。

下一步为沙盒桌面里的真实 GH/AWS 外部工具路径与权限验证、普通副本实际消费、
当前包的原生文件面板复验及完整历史/重开/容量边界。独立 CLI 接收器通过不能
替代桌面沙盒路径验收。
