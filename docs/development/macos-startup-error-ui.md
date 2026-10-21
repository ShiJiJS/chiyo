# Mac 可见启动错误与初始化中退出（#46）

2026-10-21，在独立 Mac 分支补充实际 CUA 操作。生产代码与 `01c1f14` 的
152 个文件原字节一致；密钥及库均为合成测试资料，不访问真实 Keychain。
[逐轮原始记录及摘要](evidence/macos-startup-error-ui/verification.json)。

## 已完成的实际操作

| 场景 | 证据和结果 |
| --- | --- |
| 已有库但测试密钥缺失 | 显示“无法打开信息库”和钥匙串处理说明；实际点击红色关窗，Cocoa 退出 0，无替代密钥创建，未打开库，`cleanupPending=false`。 |
| 本次测试占用 47125 | 显示无法启动信息库/本机服务的说明；实际点击红色关窗，Cocoa 退出 0，已打开的库关闭一次，`cleanupPending=false`。 |
| 初始化仍在等待 | 实际按 ⌘Q 后观察到原生 `quit`，进程仍存活、库尚未关闭；只在核对本轮 `.qa-owner` 后放行打开等待点，随后库关闭一次、原生正常退出 0。等待点为合成控制，不代表真实钥匙串弹窗。 |
| 两个应用进程争用同一库 | 第二实例显示错误并由实际红色关窗退出 0；key-store read/create 均为 0，原持有者的数据库字节不变、服务仍可达。持有者实际 ⌘Q 正常退出；第三进程重开验证正文/历史保留，旧授权拒绝，然后正常原生退出。 |

前三个场景来自 `b961e7f` 的 `issue46-startup-ui-2`：**这轮整体失败**，因为
随后同路径、同应用身份的两个进程无法由 CUA 分别定位。前三个独立场景各自有
正常退出及原生事件记录，不把整轮称为通过。无法定位的第二实例被明确强杀，
驱动将原持有者作为失败清理；这两个进程不计为正常退出或成功恢复。

重复启动的最终独立轮为 `0cdf82d` / `issue46-duplicate-ui-2`，三进程全部正常
退出 0，无强杀收尾。第二实例复制为另一 bundle URL，仅修改显示名称，仍保持
相同随机 QA bundle identifier、沙盒 entitlements、同一容器与同一目标库，
没有绕开独占锁或扩大文件访问。复制保留 framework 符号链接，并对外层重新
临时签名；deep/strict 签名核对通过。测试名称 `Mac Duplicate QA` 不是新产品。

最终重复轮 10 个依赖/分析/构建/签名步骤全部退出 0；此前三个启动 UI 场景所在轮
7 个准备步骤均通过。另保留最初 nullable 分析失败（尚未启动应用）、第一次
复制 framework 展开符号链接导致签名失败（也尚未启动应用）的原始日志和源码。
这些失败不归咎于产品，也不计作产品通过。

所有轮次的自有合成根目录、控制文件、生成 app/dSYM/Flutter 编译缓存均已清理，
原始失败记录仍保留。没有提交测试密钥、私密关联或数据库。恢复后的资料和授权
行为由自动断言核对；真实错误窗口和按钮由 CUA 操作并保存 AX/截图。

真实 Keychain 的错误后主人允许及重开属于 [既有真实系统验收](macos-keychain-owner-allow.md)，
本轮不声称重测了系统提示，也未再次要求主人选择拒绝。以上补齐 #46 第二项的
可见错误窗口和真实初始化中退出；不代替状态栏/Dock 交互、睡眠唤醒或最终包联合验收。

```bash
# 所有启动错误 UI 场景；需要实际 CUA 关窗/按键
.tools/qa-python/bin/python scripts/qa/macos-lifecycle-ui.py \
  build/macos-adaptation/NEW_STARTUP_UI --startup
# 只重跑最终重复实例场景
.tools/qa-python/bin/python scripts/qa/macos-lifecycle-ui.py \
  build/macos-adaptation/NEW_DUPLICATE_UI --duplicate-only
```
