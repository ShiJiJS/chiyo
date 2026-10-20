# Mac 备份恢复与兼容验收（#45）

2026-10-21，在 `codex/macos-adaptation` 执行；#45 仍 OPEN。
本轮验证固定主分支整合后的产品代码，新增 Mac 专用验收入口，
没有修改生产备份格式或 Windows 源码。源码及产物摘要见
[证据清单](evidence/macos-backup-recovery/verification.json)。

## 补充：真实 Keychain 源密钥丢失后的独立恢复

2026-10-21，QA 源码 `9da5eb1`，未修改生产备份、密钥存储或 Windows 代码。
最终第三轮 **8 个准备/构建/签名步骤、6 次实际 Release Flutter 应用进程通过**，
每次均记录 Cocoa 正常退出和 `flutterErrors: 0`。成功打开资料库的进程各关闭
库一次，端口退出后关闭。严格分析和 deep/strict 签名校验通过。
[原始证据与源码摘要](evidence/macos-keychain-backup/verification.json)独立保存。

沿用 #42 的隔离源码副本，只改 QA bundle identity、随机 QA Keychain service
与限定该项的故障入口；生产 Security.framework 实现、平台适配、SQLCipher、
备份、主人业务、启动与退出代码均保持字节一致。实际 SQLCipher 为 4.19.0 community。
普通产品构建目录未被测试入口替换；本轮只新增验收代码，#50 的 `541a671`
整包仍是当前产品包。

本轮格式 9 含三条信息、两级目录、标签、模板、文字版本和回收项、
字符串/文件两种托管凭据、2 个 1 MiB 附件、请求期限/主题设置，
以及真实读取/文件交付历史、待审批和未确认录入提案。
所有内容均为合成数据；源码和结果不含真实用户资料。

验证顺序与结果：

1. 生产逻辑随机生成源数据库密钥，由真实 Keychain 保存并重读；
   另行生成恢复密钥，实际比较它与本机密钥不同，保存恢复密钥文件后导出。
   再次导出到同名文件返回 `output_exists`，原备份字节不变。
2. 源应用完全退出后，只删除本轮专属 Keychain 项并确认不存在。
   另一进程尝试打开仍存在的源库，两次均 `key_unavailable`，不创建替代密钥、
   不发布端口、不改变数据库字节，错误页正常构建且可退出。
3. 独立空目标在另一子目录，由生产逻辑生成新的真实 Keychain 密钥。
   新密钥不能打开原源库，返回 `library_unavailable`，原源库字节不变。
   两把本机密钥是同一专属 QA service/account 中先后创建的不同密钥，
   并非两个真实设备或两个生产资料身份。
4. 错误恢复密钥及故意损坏的备份均被 `invalid_backup` 拒绝，目标库字节、
   空资料和原 17 分钟设置不变；同一目标使用正确备份/恢复密钥后成功。
5. 逐项比较信息/字段 ID、版本、值、目录/标签归属、模板字段、回收快照、
   凭据元数据及原字节、主题与期限；2 MiB 附件逐字节核对。
   旧申请/授权/访问记录的内容与关联完全保留，新增的 `restoredAt` 标记单独处理。
   导入历史不代表活跃授权；待审批和未确认提案为空，原交付无运行态 lease/会话绑定。
6. 原临时授权凭证、原文件关联均拒绝；新会话重新申请、批准后可读。
   向恢复后非空目标再次恢复返回 `recipient_not_empty`，数据库字节不变。
   恢复过程不改变目标 Keychain 密钥，不恢复源备份配置；原备份保持字节不变。
7. 目标完全退出后，独立应用进程重开，不创建替代密钥；以上内容与历史关系
   再次核对，旧授权仍拒绝，新申请仍可读。最终删除专属目标 Keychain 项并重读
   确认不存在，移除本轮私密库、备份、恢复密钥及关联文件。

首轮导出准备遇到 QA `UnsupportedError`，没有计为成功导出；改为先复制
Keychain 返回字节再清零后通过。该失败的专属项已清理，合成失败库保留供排查。
第二轮基础恢复通过，第三轮补充完整历史关系比较后通过；各轮不累加计数。
最初两条静态检查问题和所有运行输出保留，不上传数据库、备份或恢复密钥。

```bash
python3 scripts/qa/macos-flutter-keychain.py build/macos-adaptation/NEW_KEYCHAIN_BACKUP_RUN --backups
```

这证明真实 Keychain 下的独立空库恢复路径，不是现有安装的自动升级/重置方案。
源和目标在同一机器、同一测试签名中运行；没有 Windows DPAPI 数据源，
不替代 #17 的双向实机迁移，也没有再次执行此前 80 MiB 中断场景。
录入、审批、路径、导出/恢复操作和退出事件由自动化驱动，未点击系统文件面板；
Mac 当时仍锁屏。实际 NSOpenPanel/NSSavePanel、同卷暂存许可、最终整包 GUI
和签名升级仍待，#45 继续 OPEN。

## 补充：签名 Release 应用恢复中断

源码 `398f3a3`，格式 8、9 的两项实际应用中断/恢复均通过。
使用同一签名沙盒 Flutter 验收入口、生产 DesktopBootstrap、Owner
恢复边界及 SQLCipher；分别建立合成源与目标，源关闭并清除源测试密钥，
目标使用另一把固定合成密钥。原应用库和 Keychain 未参与。

每份备份包含 10 个 8 MiB 附件、文字版本、回收项、托管凭据、设置、
访问历史和待审批；格式 9 另含真实文件交付事实。父驱动在目标进程报告
预检完成后放行，观察非零 rollback journal 头与数据库增长才向自己启动的
Flutter 进程发送 SIGKILL。格式 8/9 分别观察到增长 4,509,696 /
4,411,392 字节；退出均为 -9，journal 保留。

新签名应用在 DesktopBootstrap 打开 Repository **之前**，直接用 SQLCipher
核对 schema 21、`integrity_check=ok` 和四张信息/附件/暂存表零行。
正常启动后进一步核对目标仍是空库、原 17 分钟设置和历史均无部分恢复。
在同一目标重试后，80 MiB 附件逐块一致，版本/回收/凭据/历史及 23 分钟
设置恢复；旧授权拒绝，格式 9 交付无 lease/会话绑定，旧会话查询也被拒绝。
备份 SHA-256 在全过程保持不变，目标始终用原合成密钥打开，不调用创建替代密钥。

6 次实际应用运行中，4 次通过 Cocoa 正常退出且各关闭数据库一次，2 次
是明确的崩溃注入；没有失败兜底强制结束。两个自有合成临时目录已清除。
12 份源码摘要与提交逐字节一致，严格 Flutter 分析通过，QA 包严格签名通过；
执行后恢复正常产品入口并复核签名。记录与原始输出见
[应用恢复证据](evidence/macos-app-backup-recovery/verification.json)。

本项补齐此前独立 AOT 测试未覆盖的应用本体中断；未操作物理界面、
NSOpenPanel/NSSavePanel、真实 Keychain 或 Windows，不能据此关闭整张 #45。

### 已准备但尚未执行的原生面板入口

`80d7d9c` 新增 `macos_backup_manual.dart`，使用普通 Flutter binding 和
实际 NativeBackupFilePicker，没有替换文件面板路径或注入点击。
它准备独立格式 9 合成资料，记录原生面板返回及同卷暂存释放结果；
用户完成源导出后，通过测试根目录内 `switch-to-target` 标记关闭源库、
清除源测试密钥并换到独立空库。界面确认恢复后核对附件/历史/旧授权拒绝
和重新申请读取，最后等待 `finish` 标记。标记只协调验收阶段，不代替界面操作。

Release 构建、严格分析、严格签名及普通应用启动准备均通过。
CUA 获取应用时仍返回 “The Mac is locked and automatic unlock could not
unlock it”，因此**实际面板操作数为 0，不计为面板验收通过**。
受控启动检查到达等待面板操作阶段后，仅向自有 QA 进程发送 SIGTERM
（退出 -15），删除该次自有合成临时目录；没有将其计为正常产品退出。
最初后台启动没有留下应用输出，未据此声称应用启动成功；
后续以前台驱动保留明确的准备输出与退出结果。
正常产品构建入口已恢复，准备记录见
[面板准备证据](evidence/macos-app-backup-recovery/native-panel-preparation.json)。

## 签名 Flutter 沙盒中的备份界面

`macos_backup_native_test.dart` 的格式 7、8、9 共 **3 项通过**。
实际加载桌面应用及 SQLCipher，使用当前设置页、备份弹窗及恢复预览：

- 创建独立恢复密钥；取消保存不产生文件、不标记为已保存；再次保存后导出。
- 中文空格路径写入加密备份。格式 7 含文字与托管凭据，8 加普通附件，
  9 加实际文件交付事实。
- 关闭源库并清除内存中的源库测试密钥，目标生成不同的本机测试密钥。
- 错误恢复密钥被拒绝且目标保持空库；重新选择正确密钥、预览、确认后恢复成功。
- 核对版本、托管凭据原字节、普通附件原字节和历史。旧会话/授权、待审批和
  受管活副本不复活；恢复后的新会话经重新申请和批准才能读取。

该模式使用隔离的内存数据库密钥、文件面板路径夹具，未打开生产库。
因此没有证明 Keychain、容器外 NSOpenPanel/NSSavePanel、原生同卷暂存许可
或肉眼可见界面已通过。本机未能自动置前，日志保留 `open returned 1`，
不把自动化点击等同于已解锁后的人工界面验收。测试 Debug 包的 deep/strict
codesign 已通过，载荷清单单独记录。

## 真实中断与同目标重试

`macos_backup_recovery_test.dart` 的格式 8、9 共 **2 项通过**。
每项准备 10 个 8 MiB 附件，以及文字版本、回收对象、托管凭据、历史与待审批。
源库关闭并清除测试密钥；独立 AOT 接收进程仅经 stdin 接收隔离目标密钥和
独立恢复密钥，不使用 Keychain、不在参数/日志中输出秘密。

接收进程完成预检后等待显式开始。父测试观察到非零 rollback journal 头，
且目标数据库已增长至少 4 MiB，才向自己启动的进程发送 SIGKILL。两次实际
观察均为增长 4 MiB；进程异常结束且 journal 仍在，没有把正常退出算作中断。

在重新打开 Repository 之前，直接用 SQLCipher 检查 schema 21、
`integrity_check=ok` 和未恢复任何信息/附件/暂存行。随后核对原设置仍为
17 分钟、无部分版本/回收/授权/访问/交付记录。在同一目标正常重试后，
80 MiB 原字节逐块一致，源设置恢复为 23 分钟；本机目标密钥和备份文件摘要
未改变，旧授权无效，格式 9 交付记录仅为无 lease/会话绑定的历史事实。

首次试验使用 `dart compile exe` 的测试产物在打开库时返回
`cipher_unavailable`，尚未进入恢复。改用 `dart build cli` 形成包含
`libsqlcipher.dylib` 的 AOT bundle 后通过；保留最初失败日志和最终载荷摘要。
这次失败证明加密能力缺失时拒绝继续，不是一次成功回滚，也不是产品备份
缺陷被修改后的验证。上述中断发生在独立 AOT 接收进程，
当时未覆盖签名 Flutter 应用本体；现已由上方独立补充验收覆盖，
最终交付包与真实系统交互仍归 #50。

## 格式与来源矩阵

| 范围 | 本轮证据 | 限制 |
| --- | --- | --- |
| 当前 schema 21 | 真实 SQLCipher 目标与恢复中断后原始检查 | 不代表所有旧 schema 升级已覆盖 |
| schema 16 / backup 5 | 固定 `291801046f7d1e6e4217a4bc001ea714689855c5` 的真实源码在 Mac 构建、创建/恢复/拒绝探针 | 合成密钥与受控程序身份，不是 DPAPI 迁移 |
| schema 17 / backup 6 | 固定 `299a8b1f9615de218c1fba42d9f383dad377890f` 的真实源码在 Mac 构建、创建/恢复/拒绝探针 | 同上 |
| backup 1/2、3/4 | 既有加密兼容夹具与独立恢复用例 | 经构造/改写的格式夹具，不宣称旧发行包生产 |
| backup 7/8/9 | 当前源实际导出与签名 Flutter 恢复；8/9 另有 80 MiB 中断重试 | 文件面板及 OS 密钥仍为夹具 |
| 旧读者读取新格式 8/9 | 上述两个固定旧源实际拒绝，原文件保持不变 | 仅 Mac 本机运行 |

常规备份/附件矩阵 **70 项通过、1 项跳过**；跳过的是 Windows DPAPI
恢复用例。启用两个旧源读取器后的矩阵 **55 项通过、0 项跳过**；
两组包含重叠测试，不能相加成独立覆盖总数。覆盖完整资料结构、
损坏/错误密钥/非空目标拒绝、保留期限、附件完整性和容量边界等既有断言。
部分历史测试名称仍含早期 schema 编号，以上表格以固定源码、断言和实际
schema 21 检查为依据，不根据测试标题推定版本。

旧源码从 Git archive 提取到项目忽略目录，原生产库文件、pubspec 和 lock
逐字节对照固定提交；离线解析与测试后再次核对，无改动。
没有切换主工作区分支、修改原锁或运行 Windows 系统 API。
Mac storage 与 desktop 严格分析均通过。

## 复跑与剩余条件

```bash
# 在 packages/info_storage 下
../../scripts/dev-macos.sh dart test test/macos_backup_recovery_test.dart
# 在 apps/desktop 下
../../scripts/dev-macos.sh flutter test --no-pub \
  integration_test/macos_backup_native_test.dart -d macos
# 在仓库根目录下；输出目录必须是全新的
python3 scripts/qa/macos-backup-compatibility.py \
  build/macos-adaptation/new-backup-compatibility-run
# 签名 Release Flutter 本体中断、原始回滚和同目标重试
python3 scripts/qa/macos-lifecycle.py \
  build/macos-adaptation/new-app-backup-run --backups
# QA 运行后恢复正常产品入口
./scripts/dev-macos.sh build
```

仍需真实系统面板与同卷暂存、真实 Keychain 目标、最终交付包的联合验收，
以及 Windows 实机导出→Mac 和反向恢复。旧源在 Mac 运行不等于跨平台往返，
本轮未将 #17 或 #45 的这些条件标记完成。跨平台程序路径/工具绑定也仍需
按目标设备重新验收；本软件没有因此获得自动同步能力。
