# Mac 真实旧 schema 与签名 Keychain 联合验收准备（#42）

2026-10-21，独立 `codex/macos-adaptation`。QA 实现 `9caeedf`，
实际构建及最终 AOT 来源 `721c91f`，归档恢复检查实现 `8e57add`。
[72 份原始源码、日志、准备结果与逐文件摘要](evidence/macos-signed-schema-preparation/verification.json)。

本轮推进此前尚未连起来验证的“真实旧源码建库 → 签名变化 → 主人允许原 Keychain →
生产启动迁移 → 旧程序拒绝 → 新程序重开”。**两份签名应用已经构建并归档，
还没有启动；真实系统允许及联合运行没有通过，#42 保持 OPEN、3/5。**

## 已实际完成：共享数据夹具与 AOT 回归

旧 core/storage 固定为 `dbb94ac1427b95c5a7bfee5011e414876c22c63e`，
由真实旧源码生成 schema20，不改当前库版本号模拟旧库。当前源为 `721c91f`。
QA helper 的原有建库/迁移核对提取成可被签名 Flutter 入口直接调用的函数，
返回表行数/摘要，不返回原始行、密钥或访问凭证。

最终 `issue42-shared-schema-fixture-2` 的 **18 步、10 场景**按预期完成：

- 实际 schema20 建库、旧库原始只读快照；快照不改数据库字节。
- 错误密钥拒绝、受控迁移冲突拒绝，均保留数据库字节。
- 去掉测试自己引入的冲突后，同一目标实际迁移到 schema/marker21。
- 28 张持久表的逐行摘要、两份附件原字节/版本关系及已结束授权/历史保持；
  临时草稿回执按生产合同清除，新交付登记表为空，旧授权拒绝。
- 迁移后原始只读快照不改字节；旧读者拒绝新库且保留字节，当前读者独立重开成功。

三个负向用例的退出 1 是预期拒绝，不写成所有命令退出 0。
此前共享函数第一轮 8 场景回归也通过，但不与最终 10 场景累加。
最终合成根已清理；随机合成密钥只经父子内存和匿名 stdin，不上传。

## 已实际完成：两份 Flutter Release 和签名归档

同一固定 QA 身份 `org.shijijs.agent-info-manage.qa.schemakeychain20261021`，
同一专属随机 service、同一 account、同一合成根设计。两份程序均使用当前生产
Security.framework 实现；`DatabaseKeyStore.swift` 原字节保持，SHA256 为
`d157f50972cac3da88df60846cc7a634afeaf02e787d1f486effd1fb56634ef4`。
源码副本只注入专属 service 与仅删除该专属项的 QA 方法，不读取/删除生产项。

旧版是当前 Mac 原生宿主加上固定的旧 core/storage，以普通 Flutter binding 建库；
没有声称历史上存在已发行的 schema20 Mac 版。它不做凭据执行，因此仅在 QA 副本
移除当前 worker 构建阶段，避免用当前 CLI 编译旧 core；没有插入伪 worker。
新版使用当前生产 `DesktopLauncher` / `DesktopBootstrap`、系统 Keychain 和 SQLCipher，
保留实际随包 worker。两份都不是 #50 最终交付包。

依赖锁、各自入口严格分析、Release 构建、deep/strict 签名与签名详情共 **16 个准备阶段**退出 0。
两份代码签名字节摘要不同。程序没有运行，没有新建测试库、Keychain 项或系统授权请求。

归档后从 ZIP 恢复，核对实际二进制摘要、全部记录源码字节和签名，再删除解包应用；
只保留两份待验归档：

| 归档 | 字节 | SHA256 |
| --- | ---: | --- |
| `prepared-legacy.zip` | 32,521,115 | `98d48d4b20f1bb4dc37e4dbbf5bb14ad7da55e6a4e95e6f7345cf1531554e70f` |
| `prepared-current.zip` | 38,779,993 | `ebd56936e80fe35c232b8d4f4e5bb151929659b424270b0d8dedd2decd2e151f` |

生成的 app、dSYM、Flutter 编译缓存已清理；验收目录中 app 为 0、dSYM 为 0，
项目内只保留 `local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app` 这一份安装应用。
不向 Git 提交待验归档、二进制、私密 controller、数据库或密钥。

## 保留的工具问题与修正

首次归档恢复检查在源码清单核对时失败：替换为旧 core/storage 后，清单仍保留了
41 个只存在于当前源码的文件名。实际旧源和签名二进制没有改动，失败发生在启动前。
原失败结果保留为 `archive-verification-1-result.json`。

已将旧包的输入清单改为真实固定旧 Git tree 的文件集合；对现有准备记录只移除
不在该不可变旧 tree 且实际不存在的 41 个名字，重新逐一核对所有真实旧文件，
记录修正原因、移除列表及原结果摘要。随后归档恢复/完整源码/二进制/签名检查通过。
28 个累计命令阶段包含归档和多轮恢复检查，不能当作 28 个独立业务用例。

另按用户“只验收允许，不再补人工拒绝”要求，已有交互升级入口已去掉“先失败一次”
前置条件；失败返回记录为 `actualFailedAttempts`，不推断主人点过“拒绝”。
历史原始证据中的旧字段保持不变。

## 后续实际运行边界

普通安装应用当前仍在等待先前那次主人钥匙串确认，保持原进程、原库和端口关闭。
本轮没有叠加第二个系统请求。新联合入口编译了以下核对，尚不能当作已运行的结果：

1. 原签名应用用真实 Keychain 创建合成旧库，保存旧源表/附件/历史基线。
2. 新签名普通启动失败时原库字节保持、零替代密钥、没有端点；真实生产按钮由 CUA
   操作，系统密码及允许决定由主人处理，不注入回调，不要求人工先拒绝。
3. 允许后，**生产 bootstrap 的首次开库**执行迁移；在库仍打开时做只读原始快照，
   不通过第二次开库或隐藏修复补成成功。
4. 核对全部持久表、两个附件原文及旧许可失效；正常退出后，实际旧程序拒绝新 schema
   且不改字节，再用新签名独立进程重开；原签名删除自己的测试项并确认不存在。

输出目录必须是本机拥有的准备目录；恢复只使用记录摘要一致的原归档。
失败时保留失败事实；若专属项清理失败，保留能清理它的原签名程序和私密根。
需要主人处理新的系统请求时再协调，不从当前等待自动推断授权。

```sh
# 新一轮准备；结束后自动归档并删除生成 app/cache，不启动应用
.tools/qa-python/bin/python scripts/qa/macos-schema-keychain.py \
  build/macos-adaptation/NEW_SCHEMA_KEYCHAIN --prepare-only

# 检查已准备归档的恢复、源字节和签名；仍不启动或访问钥匙串
.tools/qa-python/bin/python scripts/qa/macos-schema-keychain.py \
  build/macos-adaptation/issue42-signed-schema-preparation-1 --verify-prepared

# 实际系统允许和联合升级；当前尚未执行
.tools/qa-python/bin/python scripts/qa/macos-schema-keychain.py \
  build/macos-adaptation/issue42-signed-schema-preparation-1 --resume
```

本轮没有改变普通安装包、生产密钥/容器、Windows/main 或 CI。
