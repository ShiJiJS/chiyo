# 凭据使用

先确定密码真正送到哪里，再申请。Ego／Chrome 网页使用专用表单方式；支持的原生应用使用 fill 的 native 方式固定控件、后台填写；业务程序用 exec；需要同一个远端 Shell、普通确认或 sudo 时读[SSH 持续交互](ssh-sessions.md)。软件内部管理驱动、材料与操作记录；Agent 不指定 Python 或内部 worker。批准和实际执行分开，凭据版本和真实接收位置参与检查。

## 先查本机条件

`chiyo credentials list --query TEXT --json` 查询公开名称、用途、形式、ID 和版本；账号不在公开目录。`chiyo doctor --json` 只检查当前连接和电脑，区分 supported、available、targetReady，不创建申请、不弹系统权限，也不保证任何目标都可填写。缺少权限时说明设置中需要开启的能力，不用另一个填写途径掩盖失败。

同一电脑的知予 App 提供实际填写，NAS 只核对批准与保存记录。App 不可用时先恢复原 App，不向用户提交一个实际到不了目的地的计划。能力存在也不证明目标正确；申请时和每次输入前仍检查原目标。

## Ego 和 Chrome 网页

先用当前浏览器工具打开真实登录页，读快照，确定登录区域及唯一可编辑密码框。form 可以是明确的登录区域，不要求 HTML form；selector 必须指到其中的密码控件。多个框时选择实际用途，不让软件猜。不要读取密码框的 value 做验收。

Ego 使用当前任务受控 TaskSpace 的数字 ID、Page 标签、完整 URL 及 CSS：

```sh
chiyo fill request --credential CREDENTIAL_ID --version 1 --via ego --space 7 --page p1 --url https://service.example/login --form '#login' --selector '#password' --title "登录指定服务" --summary "使用已保存凭据继续处理业务。" --json
```

Chrome 使用调用方已经明确取得的本机控制入口，不扫描端口或用户资料。先 `browsers list --via chrome --browser http://127.0.0.1:9222 --json` 查准确标签页 ID，再提交：

```sh
chiyo fill request --credential CREDENTIAL_ID --via chrome --browser http://127.0.0.1:9222 --tab TARGET_ID --url https://service.example/login --form '#login' --selector '#password' --title "登录指定服务" --summary "使用已保存凭据继续处理业务。" --json
```

以上值都是虚构例子。browser 是浏览器控制地址，url 是实际网页，不能混用。Chrome 没有可用控制入口时报告这个条件，不能把原生焦点方式记成 Chrome 表单方式已经验收。

CLI 检查并保存计划，返回 requestId 和提交 operationId；此时没有填写。等待同一申请，再执行：

```sh
chiyo requests wait REQUEST_ID --timeout 60 --json
chiyo requests show REQUEST_ID --json
chiyo fill run --request REQUEST_ID --json
chiyo operations show OPERATION_ID --json
```

申请状态可在每项当前仍可用时提供已保存的账号，用于同一服务；缺少账号就是未知，不从服务名猜。正常浏览器工具可以填账号。填写成功后仍需 Agent 按正常登录按钮提交，并从实际已登录页面确认任务完成。知予不代点提交，也不将输入送达称为登录成功。

批准范围固定凭据版本、浏览器／页面和指定表单字段；不是整个网站权限。关闭／重开标签页、换区域、网址变化或无法确认刷新后仍为同一目标时停止，不找另一个同网址页面代替，不自动降级为焦点填写或原文读取。

## 原生应用后台填写

先查 `doctor` 和 `fill methods --json` 的当前能力，再以运行中的实际应用查询控件。Mac 的 `--app` 使用 bundle ID，Windows 使用程序完整路径；它只是查询范围，不授予填写权限：

```sh
chiyo fill targets --via native --app APP_ID --json
```

结合返回的 appName、windowTitle、fieldLabel 和 controlKind 选择唯一的实际密码框，使用该项的 targetId。编号由本机辅助程序产生并绑定原进程、窗口和控件对象；不要自编编号或用 PID、句柄、坐标代替。候选无法区分时先澄清目标，不猜随机编号；没有目标时确认窗口是否已存在及兼容条件。

```sh
chiyo fill request --via native --target TARGET_ID --credential CREDENTIAL_ID --version 1 --title "登录指定应用" --summary "为目标应用中的密码框填写已保存密码。" --json
chiyo requests wait REQUEST_ID --timeout 60 --json
chiyo fill run --request REQUEST_ID --json
chiyo operations show OPERATION_ID --json
```

先核对申请返回的 App、窗口、字段与凭据版本，用户批准后才 run。发现和批准都不写值。每次 run 使用原目标并重新核对许可，用户当前焦点不是目标条件；不要为此点击密码框或激活目标窗口。控件重建、窗口关闭或 helper 重启使旧目标失效，重新发现和申请，不能按相同标签恢复旧许可。sent 只表示 setter 接受，仍需独立检查业务结果；unknown 沿原操作查询，不换编号重新填写。

通用控件路径要求当前服务与执行端支持 `credential-native-fill.v2`。Mac 按实际 AX 密码控件的可写能力判断，Windows 按实际 UIA 密码控件及 ValuePattern 判断；软件不必预先登记，不能因不在测试软件列表中就放弃发现。新目标类型为 `macos_ax_password` 或 `windows_uia_password`。历史旧目标不能转换为新目标来沿用批准。

内嵌网页不走原生路径，浏览器继续使用上面的专用接口。`unsupported_target` 表示该控件暂不支持；权限不足、会话不可用和原目标失效分别报告实际原因，不把它们都说成软件不兼容。不要自行添加应用允许名单、提升权限或改用 focus、键盘、剪贴板、原文读取。多控件批次的 destination 使用 `{"via":"native","targetId":"TARGET_ID"}`，每项引用真实发现目标。

## 已有的前台焦点方式

只在用户明确选择前台焦点方式或继续原有此类任务时使用。让真正目的应用的密码控件处于前台；按 `fill request --help` 使用 `--via focus --credential ID --purpose TEXT`。软件捕获实际应用身份供审批，不接受 Agent 自报一个应用名代替检查。首次及后续执行都用 `fill run --request ID`，发送前重新检查当前前台应用、密码控件与焦点；焦点变化时停止，不排队到别的窗口输入。

系统接口只能证明控件与应用，不能证明网页来源。权限、控件类型或受保护窗口不支持时明确报告。普通文本框、无法确认身份的目标以及焦点不符不会用键盘盲输绕过。

## 一份申请包含多项凭据

用 `fill request --input FILE`，文件写 title、summary 和 items。每项直接引用 credentialId、可选 version 与 destination，不另起密码别名。例如：

```json
{
  "title": "登录业务入口",
  "summary": "继续处理两个入口中的业务。",
  "items": [
    {"credentialId": "credential-a", "destination": {"via": "ego", "space": 7, "page": "p1", "url": "https://a.example/login", "form": "#login", "selector": "#password"}},
    {"credentialId": "credential-b", "version": 2, "destination": {"via": "chrome", "browser": "http://127.0.0.1:9222", "tab": "TARGET_ID", "url": "https://b.example/login", "form": "#login", "selector": "#password"}}
  ]
}
```

用户可部分批准。省略 fill run 的 --item 表示完整计划，必须全部有效；只执行独立获准部分时，使用申请返回的 b1 等 item ID：`fill run --request ID --item b1`。item ID 是软件分配的批准条目，不是要求 Agent 自己给密码起别名。批准 A 不批准 B，不代表同时需要 A、B 的业务可运行。

最多20个位置，同一凭据可以用于不同真实目标。每次操作固定其所需项，全部核对并准备成功后才开始；外部系统已发生的动作不能回滚。密码更新／停用／撤销后，不把原批准自动换成新版密码。

## 业务程序使用凭据

先核对程序真实接口和本机安装位置。单份凭据用参数，复杂组合用 --input。凭据原文不放 argv；业务程序的环境变量名和文件参数位置是真实接收要求，不能省略成软件猜测。

```sh
chiyo exec request --credential CREDENTIAL_ID --via env --variable SERVICE_TOKEN --executable /absolute/project-tool --cwd /absolute/work --arg status --title "查询项目状态" --summary "核对项目最近一次任务的运行情况。" --json
```

stdin 交准确 UTF-8 字节与 EOF，不加换行、不拼接多份密码；只有程序确实从标准输入读凭据才选它，OpenSSH 密码登录不直接读取 stdin。file 交软件管理的私有临时文件，可用 --variable NAME 给其路径，或用 --file-argument INDEX 插入普通参数列表；位置从0开始。路径由软件分配，不是 Agent 指定密码临时文件名。

多凭据业务文件为 title、summary 和 launch，例如：

```json
{
  "title": "同步指定项目",
  "summary": "更新本地项目的服务数据。",
  "launch": {
    "executable": "/absolute/project-tool",
    "cwd": "/absolute/work",
    "argv": ["sync", "--key", {"file": {"credentialId": "private-key"}}],
    "env": {"DB_PASSWORD": {"credentialId": "database-password", "version": 2}, "SERVICE_TOKEN": {"credentialId": "service-token"}, "MODE": "incremental"},
    "stdin": {"credentialId": "input-secret"}
  }
}
```

申请时由当前执行设备核对程序身份，不让 NAS 探测 Mac／Windows 文件。获批后 `exec run --request ID` 执行保存的计划；返回 accepted 仅说明登记，随后用 operations show 查询准备、运行、退出、失败或未知。批准固定程序身份、凭据版本和接收位置，普通业务参数与工作目录可按新的业务命令调整；用 exec run 的 --input 提交仅含 launch 的新计划，仍在原批准内核对。不能换程序或接收位置，也不把初始参数说成整个授权期的唯一命令。

全部所需凭据有效并准备成功后只启动一个进程。部分批准时可提供只依赖获准位置的新业务计划；同时需要未批位置的计划不启动。这个功能不是任意程序行为沙箱，不承诺获批程序不会主动披露已收到的材料。

`exec output --operation ID --cursor 0 --limit 16 --json` 读取有限输出，不重启。按结果中的 stream、dataBase64、nextCursor、hasMore 处理；输出缓存最多16项、每项4 MiB，结束后最多保留30分钟，宿主退出可能丢失。软件按已知原文字节过滤本次各项凭据，不承诺识别任意变换后内容。缺输出不是重新执行理由。确认整个进程树结束后才清理受管文件，未知进程情况保留登记，不凭超时删除仍在用的材料。

## 丢失回复、未知和期限

每次创建与执行都有原 operationId。未收到回复先 operations show／retry；软件恢复原记录，不重新填写或启动。相同编号改变内容报冲突。结果未知或部分填写时先核对原目标／任务，不换编号掩盖未知；App 的“已核对”只解除后续限制，不改写原结果也不自动重跑。

等待审批期限、用户批准期限、一次输入交接期限、程序运行时间是不同时间。短暂交接期限不缩短用户已批准的两小时等许可。当前项 available、版本和明确的 validity／expiresAt 都要符合，不把 null 到期时间当永久许可。旧 SSH 用户批准的本聊天不限时仍只适用原 SSH 范围，不能扩展到普通程序或其他聊天。

## 直接读取密码原文

确实没有可用直接方式或已确认失败后，单独申请读取原文，说明原因和原文将进入当前聊天；结果未知不能用原文重做来掩盖。使用许可不包含这项许可。

```sh
chiyo credentials reveal request --credential CREDENTIAL_ID --purpose "完成指定登录" --reason "实际目标无法通过已支持的填写方式操作" --json
chiyo requests wait REQUEST_ID --json
chiyo credentials reveal read --request REQUEST_ID --json
```

单独批准有效才返回原文；账户名称不等于密码。读取回复丢失时，同编号 read 和 operations retry 只核对原记录，不再次返回材料。已记录 completed 不能证明 AI 收到了原文，不能自动换新编号重读。普通状态、日志和本地操作文件均不保留密码。

## 继续旧授权

旧 info-codex 协议保留其原授权语义，不能自动升级到新多项范围。仅继续已有旧聊天与批准时，用原 association、同版本 legacyCliPath 及其 --help；stdin 不进 shell／argv。原 request-use／run-use／operation-status／execution-status／execution-output 使用原准确计划和编号，旧记录的 alias 只沿用记录，不要求新多凭据流程起别名。

旧 SSH ssh_identity 仍检查 App 信任的主机快照、非交互 OpenSSH、固定密钥版本及限时或明确 session 有效条件；不把整个 SSH 任务改成通用文件交付绕开主机信任或不限时规则。更换远端命令可在原获准范围内用新操作编号，改变主机、程序身份或接收位置需重新批准。撤销、结束或主机信任变化阻止新使用，不终止已经打开的连接。旧单次协议不因更换入口变成可复用许可。
