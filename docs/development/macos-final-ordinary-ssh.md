# 当前普通包的 SSH 联合复验

2026-10-23，#44/#50。固定package23、产品`7b19d34b61cf`，普通进程5885→6826，
沿用生产Keychain、原资料库及沙盒，无QA应用、注入密钥、换签或新钥匙串动作。
此前AWS/目录与文件联合结果见[同包记录](macos-final-ordinary-tools.md)。

## 实际导入和托管执行

CUA经真实NSOpenPanel从中文空格目录导入新生成的合成私钥，并三次选择/核对SHA256/
确认known_hosts快照。仅新增本轮`MacFinalOrdinarySsh20261023`：正确私钥v1，随后
实际更换为错误私钥v2。此前六份凭据不改动。四份使用请求均在真实审批页和最终
确认框批准15分钟；确认框明确列出严格主机检查、独立配置/主机记录、只选定私钥、
禁用agent和密码交互，不沿用个人SSH认证。

公开AgentClient使用`hostedCredentialExecutions: true`，普通App启动随包worker及
系统`/usr/bin/ssh`（实际OpenSSH10.3p1/LibreSSL3.3.6）。驱动用开发SDK编译，
不能称作随包独立客户端；私有会话能力留在客户端内存。接收端只监听本机回环51692，
仅执行夹具允许的固定合成命令，没有远程账户或个人主机操作。

| 场景 | 实际结果 |
| --- | --- |
| 快照只有无关主机记录 | SSH实际退出255，提示No RSA host key is known/严格校验失败；未执行固定远端命令。 |
| 更换快照后沿用旧许可发新操作 | receiver_not_ready、operationClaimed=false。 |
| 正确主机地址但错误公钥 | SSH实际退出255，REMOTE HOST IDENTIFICATION HAS CHANGED；未执行固定命令。 |
| 正确主机/正确私钥，同一批准下true、false、sleep2 | 实际退出0、1、0。独立接收端恰好记录一次true和一次false；sleep单独由实际进程链与退出核对，不伪称接收端audit记录了sleep。 |
| 重交原true操作ID | 同一executionId、duplicate=true；接收端仍两条固定命令，决定/操作数/固定截止均未变化。 |
| 仅将cwd改为未授予的容器外夹具目录 | start_failed/process_start_failed，processStarted=false、exitCode为空、cleanup=complete。未捕获具体OS errno，不作更具体归因。 |
| 更换凭据v2后沿用v1许可 | credential_version_changed、operationClaimed=false。 |
| 正确主机/错误私钥v2 | 实际退出255，Permission denied(publickey)，未新增固定命令。 |
| 实际GUI撤销v2后新操作 | grant_revoked、operationClaimed=false。 |

七个登记操作均有终态和cleanup=complete；其中六次真正启动SSH，外部cwd失败不计
启动。公开日志与解码输出无两份合成私钥原文或私钥标记；九份原始夹具文件的字节、
inode及mtime均保持。没有再次自然等待15分钟或重跑执行中退出，旧证据保留原范围。

## 原生进程链与材料

两秒等待期间，独立只读观察捕获App5885→包内worker6654→系统SSH6656；
目标参数匹配本轮回环端口、合成账户和固定sleep2。实际四份材料均0600、目录0700，
临时私钥与原合成v1逐字节摘要匹配。操作结束后独立确认这四条材料路径及目录消失。
其余操作的清理以各自终态回执为证，不把只直接观察一组写成逐文件观察了所有组。

随包worker实际摘要为`ff4dd5675a0970bafb84b44874e499f28ee2cdaa69b82346a1bd11abde40ee1a`，
与package23清单一致；不是旧package10的worker证据直接改名复用。

## 正常重开、历史及清理

实际撤销后停用新凭据v2并关闭发现，清除本轮主机记录、恢复原空列表。5885实际
应用菜单退出0，47125关闭；同一普通载荷6826在最小环境下免新钥匙串动作重开。
旧客户端status被拒绝，旧执行查询session_required；没有重新执行命令。

GUI显示25条历史，其中本轮四条在最前，操作数分别1/4/1/1，错误/成功/启动失败、
固定v1/v2、截止和已清理状态保持。此前00:52取消的小窗口诊断记录也可见；不把
25减去旧文档20当成本轮新增五条，本轮没有在开始时重新测量历史总数。
重开后主机列表仍空、公开凭据目录空；原两条信息、` 777`及1024字节附件v1保持。

实际随包AOT CLI在仅系统PATH环境完成capabilities/catalog/credential-catalog，
均ok/退出0。安装7,971项文件字节、模式、链接全部匹配，deep/strict签名0。
desktop摘要仍`b778a781b736eb52bcb286fe1614cfbe129e6b004b2b8266a44d6a0da432678c`。
本机SDK驱动涉及的core/storage/CLI lib及desktop_runtime与安装来源无差异；分支上
另有尚未装入的小窗口UI修正，不声称整套桌面源码与安装包无差异。

公开驱动正常退出0，接收端按核对的自有PID发SIGTERM、退出143，单列为计划清理；
两条connection reset日志保留，不算产品退出失败或接收端正常0。明文私钥/主机文件、
私有观察控制及临时AOT驱动已清理；唯一普通App6826保留，build/local零生成dSYM，
SDK、ZIP、原加密资料及恢复材料保持。

[19份公开协议/源码/运行检查、明确CUA转录与摘要](evidence/macos-final-ordinary-ssh/verification.json)。
截图仅在会话观察，没有另存图片。本轮未重新运行四包套件或打包，未安装候选24。
#44仍有GH真实正向凭据、最终工具/容量复合范围，#50仍有最终包系统/客户端/干净环境；
不据本轮提前完成整票，不改Windows/main/CI。
