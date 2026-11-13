# Mac：使用 CLI 与 AI

App 和 CLI 使用设置中选定的本地服务或 NAS，审批由用户在 App 完成。AI 只取得受限设备配置，不取得用户管理 Token。运行随包工具不需要 SDK。

## 准备材料

1. 打开同版本 App，在「设置 → 存储与同步」使用本地模式，或填写 NAS 的 IP／域名和端口。App 自动配置证书；服务器未初始化时设置知予连接密码，已初始化时输入原连接密码，已有有效连接直接复用。这不是 NAS 的系统密码。
2. 当前服务准备成功后，App 自动准备 CLI 设备配置。新聊天发现当前模式，已有聊天保留原服务和许可；不需要额外的接入按钮。
3. 从完整包运行以下命令，输出目录必须是新的稳定位置：

```sh
./cli/info-prepare-codex \
  "<新的稳定运行目录>"
```

独立 App 的配套生成器位于 `chiyo.app/Contents/Resources/AgentIntegration/cli/info-prepare-codex`。可加 `--state-root <独立私有状态目录>`；从其他位置调用时，可加 `--source-bundle <同版本CLI目录>`。移动运行目录后重新生成和审查路径，不把长期配置留在准备清理的构建目录。

生成器只准备同版本程序、`hooks.json` 和完整的 `skills/agent-info-access`，不改个人 Codex 配置。把生成 Skill 交给对应 Agent，说明末尾带准确的 `chiyo` 位置。Agent 先读 `chiyo --help`，已有本聊天的私有配置时复用，没有时自动用 `chat start` 新建未授权聊天；无需用户单独确认接入。普通终端和其他 Agent 可用，不要求安装 Codex hooks。Codex hooks 是可选的宿主生命周期适配；如需安装，按客户端正式入口审查并信任准确命令，保留已有配置。

Mac 运行目录还保存一份公开的配套 App 工具引用，不复制整套大型工具。CLI 核对该 App 与自己的版本，`doctor` 检查当前设备能力。保留原 App 的稳定位置；移动或更换版本后重新准备运行目录。该引用没有连接 Token 或凭据内容。

## 使用与核对

- Agent 先查目录和动态模板、说明用途并发申请；用户在 App 核对批准。受限设备 Token 不能审批，也不自动授予正文读取。
- 录入和修改只产生提案，整份内容在 App 一次保存。文件、密码及凭据使用以服务实际 capabilities 和动态模板说明为准，不降级为普通文本或省略缺少材料。
- 私密聊天配置由当前聊天的 `CHIYO_CONTEXT` 环境值或独立 stdin 传给 CLI，不放普通命令参数、日志或报告，不按公开聊天 ID 查找私密能力。
- 模板插件在 App 设置中管理。`templates list/show/examples` 动态取得当前服务的定义和填写示例；新增／修改使用 `proposals check/submit`，普通字段使用 `access request/read`，附件使用 `files fetch/status/release`。复杂业务才用 `--input`；Skill 不保存固定模板清单。
- 填写使用 `fill request --via ego|chrome|focus` 和获批后的 `fill run`，具体参数见同版本帮助。普通业务程序使用 `exec request/run`；填写和提交登录是不同操作，不以已填写冒充已登录。
- 服务器模式下 App 退出后 CLI 仍可申请和使用仍有效的原许可，NAS 正常重启不延长原期限。本地模式完全退出 App 会关闭本机服务，重开不能复用旧本地会话。根聊天结束、撤销或到期后停止后续访问，恢复备份不恢复旧聊天许可。
- 失败先核对当前模式、服务状态、设备及原操作结果；连接 NAS 时核对地址和证书，不关闭 TLS 验证、不回退到其他服务、不换操作编号重复未知结果。

用 `doctor` 核对连接和本机能力，再检查具体目标；它不授予访问许可。`requests`、`proposals`、`operations` 查询本聊天的原记录。申请和授权历史展示 Agent 提交的名称、聊天说明和用途，身份名称不作为授权证明。

正式生成后使用以下参考：

- [凭据申请、逐次使用与清理](cli/template/references/credential-use.md)
- [普通附件申请、领取与释放](cli/template/references/information-files.md)

本机焦点填写需要在 App「设置 → 凭据填写」开启辅助功能权限。系统页面也可能叫「设备控制和数据访问」，允许知予／chiyo 后重新检查；部分应用的密码框不支持。Ego／Chrome 的指定表单方式按 `doctor` 与实际目标检查判断，不用系统焦点方式冒充。服务器模式下，本机 App 需运行并连接原服务器。真实客户端事件、系统权限和实际 App 链路分别验证，文件摘要一致不代表这些场景已经通过。
