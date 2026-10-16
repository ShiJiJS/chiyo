# 独立恢复密钥与当前资料备份（Issue #12）

此票提供桌面所有者的手动备份入口，以及 `EncryptedInformationRepository.backups` 公开管理能力。Agent HTTP/CLI 没有启用备份、显示密钥、导出或恢复入口。日常打开应用仍使用系统自动保管的本机数据库密钥。

## 当前覆盖范围

- 当前信息项、字段值、字段类型、稳定身份及当前版本。
- 目录及父子关系、标签、信息的目录与标签关联。
- 字段模板、字段定义身份及模板版本。
- 整数设置，包括待审批有效期。

格式 1 明确排除本机数据库密钥、备份配置内的恢复密钥、运行实例与聊天凭据、有效授权、待审批请求、录入与修改提案、旧版本、回收站、授权历史及访问记录。提案已经确认产生的当前信息会随普通信息保存；不会把提案本身重新恢复。完整历史范围及两平台换机恢复由 #17 扩展，格式 1 不宣称已经覆盖这些内容。

恢复仅接受空资料库：除设置及本机备份配置以外，任何已有资料、提案或历史记录都会使恢复被拒绝。不会覆盖、合并或删除原资料；接收端首次打开已独立生成并保管自己的本机数据库密钥。恢复后 Agent 需要重新申请。更换电脑不需要原电脑的 DPAPI 文件、钥匙串或数据库密钥。

## 密钥和格式

启用时通过 `Random.secure()` 生成独立的 32 字节随机恢复密钥，显示格式为 `aim-recovery-v1:` 加规范的 Base64URL 编码。恢复密钥保存在本机 SQLCipher 加密的 `backup_configuration` 单例中，用户可以在客户端重新查看并另存为明文文件。密钥只经所有者界面或私有调用交付，不进入命令参数、日志或备份。用户需要把另存的密钥与备份分开保管；同时持有两者即可解密备份。

备份是 SQLCipher 4 默认兼容配置加密的独立数据库（建议扩展名 `.aimbackup`），以恢复密钥作为随机原始 256 位密钥；SQLCipher 自行生成每个备份的随机盐和页面认证材料，不自行编写密码算法。只有一个 `backup_snapshot(singleton,payload)` 表，单例 payload 为 UTF-8 JSON：`format=agent-info-manage-current-data`、整数 `version=1`、UTC `createdAt` 和显式列清单的七个资料表。格式标识、版本和元数据也在加密封装内。

本机结构版本 5 是备份配置，保留 `<5` 的加法迁移，与目录 3、模板 4、提案 6、修改提案 8 的结构合并。部分独立分支的开发结构曾仅预留版本 5，因此打开已知结构后会幂等补齐这个配置表，不替换既有密钥或资料。

## 一致性、失败和边界

导出在单个 Drift 读事务中取得显式当前资料快照，避免简单复制正在写入的数据库。所有临时 SQLCipher 连接都先要求实际 SQLCipher 4 能力，先设密钥，使用 `temp_store=MEMORY`。在独立加密暂存文件完成写入、关闭和完整验证后，才原子发布新文件：Windows `MoveFileExW` 不设置覆盖或跨卷复制标志；macOS 使用 `renamex_np(RENAME_EXCL)`。现有输出总是拒绝覆盖。中断可能留下未发布的加密暂存文件，不会把部分文件报告为成功备份。

导入先以只读方式打开选中文件，执行全页面 `cipher_integrity_check`，再检查数据库完整性、唯一合法表、格式和完整 JSON 模型，最后才向接收端执行单个恢复事务。错误密钥、篡改、截断、未知版本、不合法字段类型、孤立关系或目录环都在写入前拒绝。恢复中断依赖 SQLite/SQLCipher 事务回滚；不把失败转为重建原库。

文件最多 128 MiB，JSON 最多 64 MiB；目录、标签和信息各最多 10,000，字段及标签关联各最多 200,000，模板和设置各最多 1,000。还检查每项最多 200 个字段、100 个标签、字段值长度、版本、身份唯一性、关系存在和目录无环。超限拒绝操作，不静默截断。目录验证与字段计数避免重复扫描整个资料集合。

桌面文件面板是独立的所有者进程 MethodChannel。Windows 使用附属于应用窗口的 Open/Save 公共对话框，不要求新增 Flutter 插件或启用系统 Developer Mode。macOS 保留 App Sandbox 和用户选中文件读写 entitlement；暂存通过 Foundation `.itemReplacementDirectory` 和选中目标获得同卷位置，native 仅持有并清理本次生成的 URL/token，不接受任意路径删除。无法完成同卷安全发布时失败，不回退为覆盖复制。

## 已做验证及待验收

仅使用独立临时目录和虚构资料，未操作桌面窗口、原用户资料或 Codex 配置。

- 存储公开接口往返：当前值和版本、文本说明类型、移动后父目录晚于子目录的层级、标签、模板、设置全部保留；源请求、提案、旧 token 和恢复密钥配置均不恢复。
- 实际 Windows SQLCipher + DPAPI：删除原设备测试 envelope 后，用独立新 DPAPI 密钥恢复，扫描磁盘文件不含测试正文；同样验证保存密钥文件不覆盖已有文件。
- 错误密钥、认证破坏、截断、未知版本、不合法模型、非空接收端及有待确认提案的接收端都保留原资料与设置；已有备份不覆盖。
- 真实独立 console 子进程恢复 50 项、每项 200 字段时被终止；重新打开接收端为空且原 15 分钟设置保留，随后同一备份完整恢复并变为备份的 45 分钟设置。仅终止该测试启动并报告自身 PID 的 probe；密钥经私有 stdin 传递。
- 两个 Flutter widget 用真实加密仓库和注入的系统文件选择边界，验证启用/另存密钥/导出，以及导入预览/确认/切回“我的信息”可见恢复资料。
- Windows 发布构建验证原生文件面板代码可以编译；未启动应用或打开系统面板。

本票使用 `./scripts/check.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin -Offline -WindowsRelease` 进行公开接口、CLI、widget 和发布编译检查；具体合并后测试总数由整合分支记录，不能把构建成功当作用户桌面验收。

真实桌面文件面板往返、macOS 构建/签名/钥匙串/沙箱暂存及跨平台恢复尚未验收。不要把 headless/widget 或 Windows console 的通过写成真实桌面、macOS 或 #17 完整验收通过。

## 依据

- [SQLCipher key、页面认证及完整性检查](https://www.zetetic.net/sqlcipher/sqlcipher-api/)。
- [Windows MoveFileExW：覆盖、跨卷复制和同步标志](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)。
- [Windows Open 公共对话框](https://learn.microsoft.com/en-us/windows/win32/api/commdlg/nf-commdlg-getopenfilenamew)。
- [Apple 用户选中文件沙箱边界](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、[替换暂存目录](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/itemreplacementdirectory)、[Darwin renamex_np 声明和 RENAME_EXCL](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stdio.h)。
