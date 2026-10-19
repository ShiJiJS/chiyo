# Windows 0.4.0+10 开发预览

2026-10-20，干净源码 **527b4ccf63e53c8aaae5c492d9fb34b239ff0d29**，标识 **0.4.0+10-dev.527b4ccf63e5**。未签名Windows x64便携开发包，用于后续验收；#18/#23/#30继续OPEN，未上传二进制或发布GitHub Release。

## 本机交付物

- ZIP：`build/windows-preview-0.4.0-10-527b4cc/agent-info-manage-0.4.0+10-dev.527b4ccf63e5-windows-x64.zip`
- 同名`.sha256`文件与ZIP放在一起；展开目录：`build/windows-preview-0.4.0-10-527b4cc/AgentInfoManage`。
- 应用入口：展开目录的`app/info_desktop.exe`，保留全部相邻DLL和`data/`，不能只复制EXE。
- 大小 **53,291,773字节**；SHA-256：`ea867dfa6d6b3700675f80c79b833debc084c9cd8a29d9a83065e70c42255338`。
- manifest format2，**113项载荷**，各项字节/摘要和归档已独立复核；manifest不记录自己的摘要。

应用、CLI、worker、焦点辅助程序与Skill来自同一提交，协议v2/schema21及备份7/8/9不变。沿用Round05全部界面与四主题，支持凭据期限内复用、本机焦点填充和加密普通附件。此版修复0.4.0+9存在的结束审计写入失败后永久显示运行中及材料不回收，详见[复现/恢复记录](issue30-terminal-audit-recovery.md)。通知身份修复已包含，但真实显示/点击仍未验成。

## 实际检查与边界

完整`scripts/package-windows.ps1`退出0：**685通过/19既有opt-in跳过**，分别CLI92/13、Core272/0、Storage161/6、Desktop160/0；四包严格分析、Windows Release及原四份锁通过，没有升级依赖。Drift调试警告原样保留。首轮桌面测试155/160停顿经核对后有界中止，修复内部写入队列首次初始化后，相关10项/4秒通过，再从干净527b4cc完整重跑；不跳过或抹去失败。

实际ZIP在中文/空格路径解包，限制子进程PATH为系统目录后：SDK-free生成器、实际AOT CLI/hook与worker **16通过/0跳过**，加密联合生命周期 **7通过/0跳过**；SQLCipher4.19.0与当前用户DPAPI探针通过。核对撤销/到期/轮换/结束/宿主终止重开、交付前与结束后审计故障，普通副本与活动凭据材料独立清理，退出事实和固定期限保留，无新授权或命令重放。

解包组使用源码端所有者/服务、实际AOT适配器/worker、实际Windows文件和Job，焦点输入与程序分类受控；它们与全量重叠不累加，不能代表实际包GUI、真实Codex或系统密码输入。限制PATH也不能代表干净Windows用户或机器。

程序需要Windows x64及兼容的Microsoft Visual C++ v14 x64运行库，不随包自动下载或安装。受支持流程见随包[交付说明](windows-delivery.md)。原用户0.4.0+8仍在原路径运行；自动检查没有打开新包GUI、迁移真实库或改Codex配置。试用前在旧版备份并单独保管恢复密钥，完全退出旧托盘进程，再完整解压启动；不要让两版同时打开同一库，也不要用旧程序直接打开升级后的库。

仍待：最终包GUI各功能及真实升级/备份、通知新入口真实显示/点击与凭据/文件请求定位、用户安排的Codex安装/信任与共享/隔离/结束/恢复、干净Windows用户或独立机器。服务器同步、Mac延期，无子Agent。Computer Use只读确认桌面后已立即reset，通知探针仍待操作员就绪。

完整日志、失败与定向回归、manifest、归档摘要、重跑脚本、88份原始资料及25份最终Git源码/锁摘要见[证据清单](evidence/issue30-terminal-audit-recovery/verification.json)。程序和ZIP保留在本机忽略目录。
