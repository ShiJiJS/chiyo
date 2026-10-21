# Mac 签名变更后主人允许 Keychain 访问

后续 QA 已按用户要求移除“先失败一次”的前置条件，并准备真实旧 schema 与签名
Keychain 的联合入口，见 [准备记录及尚未运行的边界](macos-signed-schema-preparation.md)。
本页保留原版本结果，不将新的准备工作补写为运行通过。

2026-10-21，用户亲自处理系统提示并报告选择“始终允许”后，真实 Keychain 恢复与两版应用重开通过。只在独立 `codex/macos-adaptation`，生产业务源码保持 `01c1f14`；本轮不再补做人工拒绝按钮验收。

用例为 `issue42-actual-upgrade-unlocked-2`，QA/来源提交 `a8a14da22daa0a76c5d1b8fe3dcdd833b0a85242`。11 个准备/构建/验签步骤与 7 个实际签名 Release 应用进程全部退出 0，Flutter 错误为 0。

| 场景 | 实际结果 |
| --- | --- |
| 原签名创建合成库 | Security.framework 生成并保存真实随机密钥，SQLCipher 4.19.0 建库、录入并完成获准读取 |
| 更改 CFBundleVersion 后重新 ad-hoc 签名 | 两次普通非交互读取被拒绝；原数据库字节不变、没有替代密钥或 Agent endpoint |
| Computer Use 点击生产“请求钥匙串访问” | 实际系统交互，无模拟系统决定；用户手动处理密码及允许 |
| 系统允许后恢复 | 原信息/字段身份和值、已结束授权和访问历史保持；旧授权仍拒绝，没有新建或替换密钥 |
| 新签名独立进程重开 | 0.462 秒完成，原库和关系保持，正常退出且端口关闭 |
| 原签名独立进程重开 | 0.391 秒完成，原库和关系保持，正常退出且端口关闭 |
| 两次专属项清理确认 | 原签名删除测试项并确认不存在；拥有的合成目录已删除 |

交互过程约 106 秒。应用先记录一次读取失败及原库保持，随后第二次访问成功。用户明确表示第一次也是点击了“允许”，最后选择“始终允许”，因此 `actualDeniedAttempts: 1` 只表示应用观察到一次失败返回，**不是用户点击“拒绝”的证据**。没有据此判断第一次失败的系统原因；按用户要求，以允许恢复成功为本次结果，不再要求补点拒绝。

这两份应用使用同一 QA bundle identifier、同一专属 service/account、同一原 SQLCipher 目录；改变版本和代码签名，没有通过换成新容器或新密钥绕过。生产 `NativeDatabaseKeyStore`、Dart 启动和库实现保持，测试副本只改 QA 身份和加入拥有者限定的探针方法。159 份生产输入摘要与 `01c1f14` 一致。系统密码不经 Agent、CLI 或测试日志；工具不操作 SecurityAgent，系统决定由用户完成。

[33 份证据索引](evidence/macos-owner-keychain-allow/verification.json)保存结果、签名/构建/应用日志、准确 QA 及关键生产源码。公开结果/日志去除曾用于测试控制的 owner 和私密根路径，派生转换、原始文件摘要和公开文件摘要逐项记录，不能称它们是未改写的原始文件。私有原始记录留在本地忽略目录；密钥、数据库及系统密码未发布。两版程序均使用 ad-hoc 签名，不冒充 Developer ID/公证后的升级。

本轮补齐 #42 中“更换签名后主人允许、原库恢复及后续重开”的直接证据。两版 Dart/storage 业务源码与 schema 相同；[实际旧 schema20→21 迁移](macos-schema-upgrade.md)仍是另一组独立 AOT 证据，不能将两者拼成“两版签名 Flutter + 真实 Keychain + 旧 schema 迁移”已联合通过。因此 #42 第 1/4 条的正式身份/签名策略与完整升级联合条件继续开放，原有第 2/3/5 条状态保持。最终安装与系统操作仍由 #50 继续验收。

复现使用全新输出目录，需要用户手动完成系统访问决定；`--interactive-upgrade` 是该 QA 的完整交互观察模式，结果必须分别看允许恢复、重开和清理事实，不只看退出码。用户当前不要求继续重复拒绝场景。

```sh
.tools/qa-python/bin/python scripts/qa/macos-flutter-keychain.py \
  build/macos-adaptation/<全新的测试目录> --interactive-upgrade
```
