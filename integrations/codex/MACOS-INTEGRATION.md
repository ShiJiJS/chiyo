# Mac：接入 Codex

App 和 CLI 使用设置中选定的本地服务或 NAS，审批由用户在 App 完成。AI 只取得受限设备配置，不取得用户管理 Token。运行随包工具不需要 SDK。

## 准备材料

1. 打开同版本 App，在「设置 → 存储与同步」使用本地模式，或填写 NAS 的 HTTPS 地址、用户 Token 和 CA 证书；连接服务器时不关闭证书校验。
2. 当前服务准备成功后，App 自动准备 CLI 设备配置。新聊天发现当前模式，已有聊天保留原服务和许可；不需要额外的接入按钮。
3. 从完整包运行以下命令，输出目录必须是新的稳定位置：

```sh
./cli/info-prepare-codex \
  "<新的稳定运行目录>"
```

独立 App 的配套生成器位于 `chiyo.app/Contents/Resources/AgentIntegration/cli/info-prepare-codex`。可加 `--state-root <独立私有状态目录>`；从其他位置调用时，可加 `--source-bundle <同版本CLI目录>`。移动运行目录后重新生成和审查路径，不把长期配置留在准备清理的构建目录。

生成器只准备同版本程序、`hooks.json` 和 `skills/agent-info-access`，不改个人 Codex 配置、不安装或信任 hooks。把生成 Skill 交给对应 Agent，说明末尾带准确程序位置，可以按说明手动关联。要启用 hooks 时，保留已有项目配置，按当前 Codex 的正式入口审查并信任准确的 SessionStart、SubagentStart、SessionEnd 定义；材料存在、项目受信任或当前能连接都不能替代具体 hook 的安装和信任。

Mac 运行目录还保存一份公开的配套 App 工具引用，不复制整套大型工具。CLI 的 capabilities 会核对该 App 与自己的版本，再返回当前设备可用的工具位置。保留原 App 的稳定位置；移动或更换版本后重新准备运行目录。该引用没有连接 Token 或凭据内容。

## 使用与核对

- Agent 先查目录和动态模板、说明用途并发申请；用户在 App 核对批准。受限设备 Token 不能审批，也不自动授予正文读取。
- 录入和修改只产生提案，整份内容在 App 一次保存。文件、密码及凭据使用以服务实际 capabilities 和动态模板说明为准，不降级为普通文本或省略缺少材料。
- 私密聊天关联通过 stdin 传给适配器，不放命令参数、普通日志或报告，不按公开聊天 ID 查找私密能力。
- 模板插件在 App 设置中管理。CLI 的 plugin-list、template-list、template-read 直接取得当前服务的定义和填写示例；Skill 是说明书，不保存固定模板清单。
- 服务器模式下 App 退出后 CLI 仍可申请和使用仍有效的原许可，NAS 正常重启不延长原期限。本地模式完全退出 App 会关闭本机服务，重开不能复用旧本地会话。根聊天结束、撤销或到期后停止后续访问，恢复备份不恢复旧聊天许可。
- 失败先核对当前模式、服务状态、设备及原操作结果；连接 NAS 时核对地址和证书，不关闭 TLS 验证、不回退到其他服务、不换操作编号重复未知结果。

使用随包 CLI 的 capabilities 核对服务和实际工具；这不代表个人宿主已安装 Skill 或信任 hooks。申请和授权历史展示 Agent 提交的名称、聊天说明和用途，身份名称不作为授权证明。

正式生成后使用以下参考：

- [凭据申请、逐次使用与清理](cli/template/references/credential-use.md)
- [普通附件申请、领取与释放](cli/template/references/information-files.md)

本机焦点填充保持关闭。真实客户端 hook 生命周期、系统通知、原生面板和第二台电脑需分别记录验证，不把工具能启动或文件摘要一致说成这些场景已经通过。
