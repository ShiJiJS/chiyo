# Windows 运行工具接收预检

2026-10-17。此记录为 #28/#29 准备真实工具，不是产品申请、审批、run-use、一次消耗或清理已经通过。所有材料均为新生成的虚构内容，没有使用个人 infos、已有登录或真实密钥；测试服务只发布临时回环端口。原型还原与各票验收继续独立推进，服务器同步尚未开始。

## Windows AWS CLI v2

固定官方包 `https://awscli.amazonaws.com/AWSCLIV2-2.38.1.msi`，50,122,752字节，SHA256 `ad07f9acd855f48ad016e63b2f0b4f87783c1b6524b86e966f4a6d21d01f524a`，Authenticode Valid、Amazon Web Services, Inc.。使用 Windows Installer 只读数据库/流 API 读取文件表与嵌入 CAB，系统 expand 解压后按表重建任务目录布局；未执行 MSI 动作、安装脚本、注册表写入或修改全局 PATH。此方法只在当前固定包实测，不声称官方提供便携发行版。

任务目录 `C:/Project/network_config/info-manage/.scratch/aws-cli-2.38.1-static/runtime/aws.exe` 实测版本 `aws-cli/2.38.1 Python/3.14.6 Windows/11 exe/AMD64`；exe SHA256 `82c7fef1eb1a5894793ef9f0a56b2b8509dfab98460106db45ac409c1b31bc60`，官方签名 Valid。提取脚本、元数据和工具证明保留其上级忽略目录，工具二进制不进仓库。

`local_fixture.py` 使用新临时 default 凭据文件、空 config 和隔离 HOME/USERPROFILE/APPDATA/LOCALAPPDATA，禁用 metadata、pager、自动提示。真实 CLI 对临时 localhost 服务完成 STS GetCallerIdentity、SSM PutParameter 非秘密值写入及 GetParameter 读回，三次退出0。服务端独立核验完整 SigV4 canonical request、签名头、请求体和日期/region/service 派生 HMAC。保持相同 access key、改用错误合成 secret 后返回403，CLI退出254。没有仅凭 access key 或返回200推定 secret 正确。

结果 `local-fixture-result.json` 只含用例、退出码、签名是否正确和工具 hash，无凭据/Authorization。临时凭据目录已移除、服务已关闭。后续仍须通过产品公开 JSON-lines 和真实执行器重做生命周期验收。

## Windows OpenSSH

真实 `C:/Windows/System32/OpenSSH/ssh.exe` 版本9.5p2、LibreSSL3.8.2，exe SHA256 `98d447730047f5df91373e852d057928a921c3d1e89938700ab656ba84b19dc8`。新增 Docker fixture 基于现有固定 `python@sha256:a1165e272e578941b84abc79e4ab38a0305cd12803a5c4247979ac7655f4d641`，容器内安装 openssh-server，当前镜像ID `sha256:4c33580cdd4166ddf8faeb4f6bba9fb7e208720978f0a92751681b3f22d9406c`。每次运行生成新的 host/client/wrong-client key，只有 fixture 用户允许公钥登录，密码/转发/交互关闭；测试容器结束后已停止并移除，不触及既有容器。

服务端新生成的 host 公钥直接形成本次已确认快照；没有扫描或借用用户 known_hosts。真实 Windows 客户端使用空 `-F`、独立 UserKnownHostsFile、空 GlobalKnownHostsFile、无 ssh-agent、BatchMode/IdentitiesOnly/StrictHostKeyChecking；带中文和空格的独立材料路径保持单个 `-i` 参数。正确合成 key 与确认 host 的 `/usr/bin/true` 退出0；错误 client key、未知 host、变更 host 快照均退出255且不提示交互。

脚本及非秘密结果在 `.scratch/ssh-receiver-fixture/{probe.py,probe-result.json,Dockerfile,sshd_config,start.py}`。本轮是直接客户端接收预检，未经过产品凭据库、申请/审批、run-use，也未验证产品受管文件清理或进程树监护。合成测试目录保留以供问题复现，不进备份或发行包。

## 暴露并明确修订的工程约定

- 原协议的 Windows 最小环境未设置 `ProgramData`。实测只给 SystemRoot/WINDIR/COMSPEC 时，`ssh -V` 退出255、stdout/stderr均空；分别补 USERNAME 或 USERDOMAIN 无效，仅补 ProgramData 后正常。设为任务的私有空目录也正常，随后完成上述真实 SSH 四用例。上游 [Win32 初始化源码](https://github.com/PowerShell/openssh-portable/blob/latestw_all/contrib/win32/win32compat/w32fd.c#L218)读取此变量并在缺失时 fatal，与本机观察相符；不声称当前上游分支等同本机二进制源码。因此协议明确执行器生成私有 ProgramData，禁止申请覆盖，不回退系统共享配置或整个父环境。
- SSH 有用户和全局两类 host 数据库。仅空 `-F` 与指定 UserKnownHostsFile 不作为全局数据库隔离证明；协议现已明确两类文件均进入已展示的 effective argv/planHash。
- 测试目录初次仅去除继承/授权当前用户时仍留有显式 OWNER RIGHTS ACE，真实 Windows SSH 拒绝私钥。仅对新建测试目录重建为当前用户与 SYSTEM 后通过。产品 #29 仍须核验实际文件 DACL，不能把 chmod/read-only 或“已调用权限函数”当成验收成功；本次没有改变用户源文件或系统安全设置。

上述修订是让既定“真实工具可运行、隔离其他认证来源”要求成立的工程细化，没有扩大工具业务权限或改变三类许可语义。协议修订与 #28/#29 同步，文件运行/清理与正式端到端结果仍由其实现票负责。
