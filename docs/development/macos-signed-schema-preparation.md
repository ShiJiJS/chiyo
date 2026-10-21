# Mac 真实旧 schema 与签名 Keychain 联合验收准备（#42）

## 2026-10-21 主人允许后的真实升级与重开基线修正

本节取代下方“等待允许”的当前状态；早先快照与原始失败保持不变。
[本次 72 份原始结果、执行源码、修正源码及摘要](evidence/macos-signed-schema-runtime/owner-allowed-20261021.json)。

主人在专属测试的系统提示选择“始终允许”后，新签名进程使用原 Keychain 密钥，
由生产 DesktopBootstrap 首次开库完成 schema/marker20→21；28 张持久旧表摘要、
两份附件原字节及版本关系保持，旧授权拒绝，临时草稿按合同清理，新增交付表为空。
当前升级进程正常退出 0、Flutter 异常 0、libraryCloses=1、替代密钥创建 0、
实际交互尝试 1。随后旧签名进程拒绝新 schema，退出 0（入口核对预期
`unsupported_schema`），runner 核对数据库字节保持后才继续下一阶段。

新签名独立进程重开已无需再次主人操作，实际读到原密钥、bootstrap ready 并取得
SQLCipher 快照；但随后 QA 将该快照和**验证操作前的旧表基线**比较，
`access_records` 不同而退出 1。前一步主动尝试旧授权，生产服务按合同新增一条
unauthorized 访问记录。因此这是错误的 QA 比较边界，不能据此声称迁移损坏，
也不把此次完整联合运行改写成成功：`complete=false`；重开后的正常退出未验收。

修正仅涉及 QA：首次迁移仍严格比较旧持久表；验证结束、正常关闭库后记录新的
逐表摘要，独立重开改为与该完整摘要逐表比较，不排除访问记录表。失败时也先保存
快照，便于诊断。`productionStartupPerformedMigration` 仅在首次升级时为 true。
生产 core/storage、原生 KeyStore、固定预览 App 均没有改动。

非交互 AOT 回归已实际完成 **19 命令阶段、10 业务场景**：真实固定旧源创建、
错误密钥/迁移冲突拒绝、schema20→21、原文关系保持、旧程序拒绝及当前独立重开。
另直接运行签名宿主共用的校验函数：实际迁移/重开快照通过；30 张表逐一修改摘要
均拒绝，错误旧基线和缺表也拒绝。核对每次拒绝旧授权仅新增一条访问记录，
其他表保持，重开前快照等于前次结束快照。严格 Flutter 分析通过。
这是内存合成密钥的自动回归，**修正后没有再启动签名联合测试或触发系统允许**。

#42 第 4 条要求的两版实际签名、升级后 Keychain 访问、旧库迁移及数据关系已有
直接证据；完整联合脚本失败和未重验的收尾明确保留。第 1 条的最终签名身份策略
仍未完成，不据此关闭 #42 或认定 #50 最终包升级验收完成。

原签名清理进程退出 0，专属测试 Keychain 项删除并确认不存在，合成根及私密
controller 删除，两份生成应用、dSYM、Flutter 构建缓存清理。清理盘点为项目内
一份固定预览 App、零 dSYM（不含保留的工具链）；正式容器和原始交付 ZIP 保留。

### 后续避免重复人工授权

主人要求减少人工等待。后续普通功能验收复用固定目录下已允许的同一安装 App，
其余迁移/错误场景优先采用内存合成密钥夹具，不为每轮测试新建真实 Keychain 项。
联合 runner 默认只准备，须明确 `--run-interactive` 或 `--resume` 才会启动真实
Keychain 测试；本轮不会再触发一个新请求。

“始终允许”用于让该应用以后访问该项时无需再问，见
[Apple 说明](https://support.apple.com/en-gb/guide/mac-help/kychn002/26/mac/26)。
固定普通包此前已两次退出/重开无需再次主人操作；本次新签名进程也确实重开到开库
阶段。更换签名/应用身份的实验不承诺复用原允许；不修改全局钥匙串访问控制。

## 历史运行快照：旧库已种入，等待新一次系统允许

下文是较早的准备快照，其“没有启动”只指当时。随后普通安装包的主人允许已完成，
实际流程见 [普通包追加验收](macos-local-installation.md)。本节是另一套专属合成测试，
不能把普通包的允许当成这里的系统决定。

恢复原归档后，第一次真实旧版种库退出 1：QA 在共享夹具已清零可变副本后，
又对原生桥返回的只读 key view 调用 `fillRange`，产生 `UnsupportedError`。
原签名清理进程退出 0，确认专属 Keychain 项已删除，合成根及生成 app/dSYM 均清理。
失败结果和日志保留，没有改写成迁移通过，也未触及正式密钥或容器。

修正 `26da28f` 只清理夹具拥有的可变副本，沿用 helper 的 finally；生产 Keychain
实现不改动。新一轮重新固定来源、严格分析、构建两份 Release 及签名，16 个准备
阶段和两份运行前签名核对均通过。真实旧源码已在真实专属 Keychain 下创建并写入
schema/marker20，SQLCipher 4.19.0，旧版进程退出 0、Flutter 异常 0。

新版进程 `38490` 已核对首次签名访问失败保留原库字节、没有创建替代密钥或开放
服务；CUA 点击生产“请求钥匙串访问”后进入真实系统等待，尝试次数为 1。
本快照尚未得到这次主人的系统允许；生产首次迁移、旧程序拒绝新库、新程序重开及
本轮清理尚未到达，不提前勾选 #42 的剩余复合条件（保持 OPEN、3/5）。

[两轮实际状态、失败及原始资料摘要](evidence/macos-signed-schema-runtime/verification.json)。
第一轮失败已清理；第二轮的两份临时测试应用在运行结束后由 runner 清理，
不删除唯一稳定预览 App。不导出密钥、数据库或私密 controller。

## 历史准备快照

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
