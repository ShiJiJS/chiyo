# D7 Windows 主集成复验

2026-10-18。文件凭据候选`bdf663a`合入`codex/round05-windows-sync`，合并提交`613493a`。本轮主会话单独实施，未使用子Agent；服务器同步暂停，Mac实际运行与适配延期。

- 主目录执行`scripts/qa/ssh-fixture/run.py --checks`：三个Dart包和Flutter完整分析无问题，CLI43、Core125、Storage56、Desktop101共325项通过，零跳过；真实AWS、SSH及编译CLI条件全部启用。
- 同一主目录执行`--native`：实际Windows窗口审批→编译CLI/worker→真实Windows OpenSSH，匹配/错误密钥/未知主机/变更主机退出[0,255,255,255]，四项清理均complete；独立普通字段读取及SQLCipher/DPAPI重开通过。此主目录复跑补充工作区三次同生产源码通过记录。
- 执行器二进制取自冻结生产源码`2dab838`，主集成相关生产源文件与该提交相同；相邻worker的SHA已在证据中登记。`--checks`只扩展开发验收驱动，不改变产品逻辑。SSH本地接收fixture使用WSL/Docker，不是运行软件所需服务，也不涉及服务器同步。
- 60张离屏界面与4组同视口比较继续对应`83579ed`的相同UI实现。主会话已看关键原图、200%及比较图，修复文件注入提示和捕获器主题选择问题；未独立评审。Windows测试窗口、私有测试进程和临时容器均结束，没有控制用户浏览器或读取真实infos/密钥。

[核验元数据](evidence/29-files/verification.json)包含主目录日志SHA及原始字节归档。失败原始日志保留，不将WSL存活、中文TEMP编译或测试心跳竞争失败过滤成通过。

Windows文件交付阶段可由#30接续。#29仍保留Mac执行适配/实测的延期项，不因Windows通过而宣称跨平台完成；#30负责Codex逐次调用的持续执行、历史与生命周期，#31负责完整格式5、迁移与备份，#18仍需干净Windows安装验收。当前不是可导入真实凭据的正式完整发行版本。

复现条件：安装Flutter/Dart及对应Windows工具链；显式准备已验证版本的AWS CLI与系统OpenSSH。开发SSH fixture先在`Ubuntu-24.04`的Docker中构建相邻Dockerfile；编译`info.exe`及`info-runtime-worker.exe`至`.scratch/d7-aot`，设置`PUB_CACHE`、`PUB_HOSTED_URL`和`D7_AWS_EXE`后运行上述命令。工具和密钥fixture都只用于本地验收，所有认证材料均为本轮生成/虚构内容。
