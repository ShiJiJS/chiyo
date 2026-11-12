# 服务器模式：CLI 接入

先按[部署手册](../../docs/deployment.md)启动独立服务器，在 App「设置 → 存储与同步」选择服务器模式，填入 HTTPS 地址、用户 Token 和证书。连接和首次资料加载成功后，App 自动准备受限设备配置。CLI 和新聊天自动使用当前连接；重启会复用仍有效的设备，更换服务器会切换到匹配的配置。保存失败时保留原有效连接。本地独立使用不需要部署 NAS，见[接入导航](README.md)。

用同版本 CLI 文件夹中的程序准备一个新的稳定运行目录：

```sh
info-prepare-codex <新的稳定运行目录>
```

准备命令只生成运行包、Skill 和待审查的 hooks.json，不改个人 Codex 配置，也不自动启用或信任 hooks。需要独立状态目录时加 `--state-root <私有状态目录>`。在另一文件夹执行准备程序时，可通过 `--source-bundle <同版本CLI文件夹>` 指定来源。

把准备后运行包中 `skills/agent-info-access/SKILL.md` 交给当前 Agent。说明末尾带准确程序位置，Agent 首次使用可按说明手动关联；后续正式部署再按既有流程核对和启用 hooks。配置只给 AI 连接、查询允许公开的目录和提交申请，审批仍在 App。用户 Token 不交给 AI。

模板插件仍在正常 App「设置 → 插件」选择 JSON、核对预览后安装。安装、更新、启停或移除后的下一次 CLI `plugin-list`、`template-list` 和 `template-read` 直接查询服务器，不复制模板清单到 Skill。模板返回字段格式、关联说明和填写例子；使用实际查询到的模板 ID，停用后不能继续新建，已有资料保留原来的类型和内容。模板查询和提案保存是不同能力：只有 capabilities 声明录入能力时才提交提案，当前未接通的能力不能当作已保存。

当前已接文字资料的 `import-submit`、`import-revise`、`import-status` 和 `update-submit`、`update-revise`、`update-status`。使用稳定的 operationId；提交只产生待核对提案，用户在 App「录入提案」预览并一次保存。相互引用的多条资料在同一份提案里一起入库。App 关闭时仍能提交，重开后处理；状态以服务器返回为准，不能把 pending 或 approved_awaiting_admission 说成保存成功。文件和凭据录入仍需核对各自 capabilities，缺少能力时暂缓该整份提案，不省略材料继续保存。

App 关闭后 CLI 仍直接连接服务器。服务器普通维护不单独结束有效许可，重开后沿用原聊天、原批准字段和原到期时间；根聊天结束、撤销或到期后不能继续新访问。配置文件更新只影响以后首次连接的聊天，已有聊天和结束通知保留原设备与服务器配置。

首次接入失败时先检查服务器地址、证书和设备是否被撤销，不关闭证书校验，已配置服务器不可用时不回退到其他连接。确需更换设备配置时在 App 设置中重新连接，既有聊天不会被静默迁移或续期。当前端到端验收范围和待办见 [GitHub Issues](https://github.com/ShiJiJS/chiyo/issues)。

默认发现只读取本软件的活动设备配置，不读取管理 Token。命名连接或隔离运行可通过 `CHIYO_CONNECTION_DIRECTORY` 指定 App 对应的私有连接目录；显式 `--connection` 仍用于固定目标。已有 hooks 保持原定义，更新发现方式时另行审查准确配置，不自动改写或重新信任。
