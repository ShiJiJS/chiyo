# Mac 工具目录读取与实际执行边界（#44）

2026-10-21，独立 `codex/macos-adaptation`。本轮验证改变了 #44 的下一步：
**工具目录书签可以恢复文件读取能力，但不能使任意外部 GH/AWS 成为沙盒内可执行程序。**
不应继续把“目录可访问”作为外部程序能运行的证明。
[分轮原始记录和摘要](evidence/macos-tool-execution-boundary/verification.json)。

## 实际系统面板与失败定位

QA `074ecec` / `ddd3e3b` 两轮均为普通 binding、签名 Release、生产系统面板和
真实 security-scoped bookmarks，不是选择器路径夹具。独立 QA 身份，合成库与
合成内存密钥，不读取生产资料或 Keychain。

1. 初始两个外部程序均无法打开，返回 EPERM（errno 1），没有目录书签。
2. 第一轮实际取消 NSOpenPanel，原空列表保持，书签文件仍不存在。
3. 实际选择项目内 GH ARM64 的安装目录及 AWS CLI 的完整安装目录。设置显示
   已保存、目录可访问。第二轮明确核对两个入口文件此时都可读取。
4. 生产 `inspectCredentialExecutable` 尝试启动 GH `--version`，仍返回
   `invalid_plan / launch.executable`；直接使用同一受限版本探针也返回
   ProcessException errno 1。
5. 两份准确 QA 身份的系统 sandboxd 原始日志明确记录 `deny(1) process-exec*`
   和实际 GH 路径。不是版本不匹配、目录不存在，也未到凭据注入阶段。

两轮完整工作流均失败，不能计为 GH/AWS 外部执行通过。第一轮诊断仅保留错误类型，
第二轮补齐读取/启动边界和安全的版本诊断。两轮的自有库、书签及生成应用已清理，
没有把失败期间的退出 1 当成正常产品退出。重开/升级/移除阶段未到达，不能声称通过。

Apple DTS 说明：动态文件扩展不提供可执行权限，沙盒子进程继承父进程的静态
沙盒限制。因此单独补文件书签无法解决此路径。
[Apple 技术说明](https://developer.apple.com/forums/thread/807142)。
`user-selected.executable` 用于在用户选择的位置写入程序，不是给此执行路径
添加动态启动许可的开关；本轮没有添加该 entitlement。
[Apple 文件访问文档](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

## 固定工具放入测试应用包后的实际联合验证

QA `c84a28a`，`issue44-tools-bundled-ui-1` 完整通过。驱动仅在隔离的测试应用中
放入已有官方 GH 2.102.0 ARM64 和 AWS CLI 2.38.1 完整载荷，位于
`Contents/Resources/ThirdParty/`，属于应用静态沙盒。复制保持符号链接，两个
工具入口原字节与项目 `.tools` 一致，重新签名外层应用，deep/strict 核对通过。
entitlements 与生产 Release 完全一致，App Sandbox 保持启用，没有新增临时例外。
这一步没有修改生产构建、发行脚本或保留的 #50 包。

两个实际程序的生产身份/版本检查均通过；未选择任何工具目录，也未使用书签。
三个凭据使用申请由 CUA 在实际生产审批页面确认，测试不直接调用主人批准 API。
初始资料及请求由合成夹具准备；应用 bootstrap、执行宿主、随包 AOT worker、
程序启动、材料回收和输出处理均为产品实现。

| 实际操作 | 结果 |
| --- | --- |
| AWS STS 身份查询 | 退出 0，得到 LOCALFIXTURE；独立 Python 回环接收端验证完整 SigV4。 |
| 同一 AWS 授权写参数再读取 | 两次退出 0，读取值与写入值一致；接收端分别验证完整签名。 |
| 另一份错误合成秘密 | 独立批准后实际启动；签名被接收端拒绝，AWS 退出 254。 |
| GH 无效合成 Token | 实际 `gh api user --method GET` 返回 HTTP 401、退出 1；网络失败不算通过。 |
| 五个 operationId 分别重复查询 | 均返回原执行 ID，不新增启动；每次核对授权截止时间未变。 |
| 临时材料及输出 | 四次 AWS 材料均 cleanup=complete；GH 无文件材料。输出不含三份合成秘密原文。 |

接收端只监听 127.0.0.1，记录 3 次正确签名、1 次错误签名，重复操作没有新增请求；
不保存 Authorization、凭据或请求原文。GH 只使用非空无效合成 Token 请求 GitHub，
不读取用户已有登录，子进程环境和配置目录由产品隔离。GH 成功账号访问未验证。

真实界面查看了 GH 逐次记录“已退出·退出码 1”。主审批页部分内容未暴露到
AX tree，使用已观察截图的坐标打开确认，确认弹窗及操作记录可通过 AX 读取；
不把这轮称为全部可访问性或键盘流程通过。

最终应用实际 ⌘Q，经原生终止退出 0，资料库关闭一次、Flutter 异常计数 0；
Python 回环服务按测试清理终止，不将其 -15 计为应用正常退出。
9 个依赖/分析/构建/签名步骤退出 0。152 个生产源码文件与 `01c1f14` 字节一致。
三轮临时库、私密关联、控制文件、书签和全部生成 app/dSYM/编译缓存已清理，
不保留重复测试应用或额外工具载荷副本。

## #44 后续必须落到产品的工作

- 将已验证工具的固定来源、摘要、完整依赖与许可证纳入生产打包；不能把本轮 QA
  临时复制误称为当前发行包已有工具。
- 提供随包工具的准确路径发现及版本状态；对无法执行的外部目录给出明确说明。
  凭据仍逐申请批准，启动计划及每次操作继续冻结身份与截止时间。
- 生产包重新验签、安装/换位置/更新后复验真实审批、工具身份、材料回收及历史。
- 继续原 #44 的 SSH、附件和最终同包闭环，保留未知/不符主机、版本变化拒绝、
  撤销/真实到期等独立条件；不以这五次调用替代整张票。

#44 保持 OPEN，原第 5 项状态保持，其他复合条件本轮不勾选。原验收范围未缩减；
这里证明的是符合当前沙盒条件的可行实现路径，尚需完成上述生产集成。

```bash
# 实际目录读取与执行限制；当前产品路径预期在外部 GH 启动时失败
.tools/qa-python/bin/python scripts/qa/macos-tools-ui.py \
  build/macos-adaptation/NEW_EXTERNAL_TOOL_UI
# QA 静态沙盒路径证明；需要实际 CUA 批准三次合成申请，结束后正常退出
.tools/qa-python/bin/python scripts/qa/macos-tools-ui.py \
  build/macos-adaptation/NEW_BUNDLED_TOOL_UI --bundled
```
