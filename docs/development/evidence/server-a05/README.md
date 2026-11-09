# #95：App 和 CLI 共用服务器模板

2026-11-08，codex/server-first-stage，使用隔离合成资料、HTTPS 和真实 SQLCipher。没有替换日常 App、接触真实资料或个人钥匙串。

## 实现

- 原 App 的插件投影、解码、预览、版本核查、变更和回执抽到纯 Dart 的 info_workspace。服务器与原本机兼容入口使用同一份规则；桌面只保留本机文件选择和现有界面。
- 正常联网 App 在「设置 → 插件」选择 JSON、预览并安装，可启停、升级及移除。声明式包最多1 MiB，不接受执行代码。更新保留原启停选择，版本变化会触发工作区刷新。
- 正式 CLI 的 plugin-list、template-list、template-read 经受限设备通道查询当前服务器，返回内置和插件模板、格式、关联说明和填写例子。没有在 Skill 或 CLI 写死清单；Agent 身份不能管理插件。
- 旧资料保持原类型、字段和模板快照。停用、升级或移除后仍能读取原内容，筛选列表保留已有类型，不降为通用资料。未知插件字段和操作明确拒绝，失败没有产生安装回执。

## 实际检查

- Mac 服务包15项、Linux ARM64服务包15项通过。模板场景经过正常用户 HTTPS 接口安装/启停/升级/移除，CLI 查询立即跟随变化；整体关闭并重开加密库和服务，当前模板与原操作回执仍在。
- Mac/Linux 最新模板专项各1项通过，包含不支持的字段/操作拒绝，不能借设备身份访问管理接口。CLI 返回的普通资料、应用部署、设备配置、个人档案、密码、Token、凭据文件和真实内置普通文件例子均交给现有共享录入校验；仅测试原文占位符被换成合成材料。完整远程提案提交仍属 #96，不将此校验说成已接通提案保存。
- 正常 OnlineDesktopLauncher + Widget + HTTPS/SQLCipher 场景通过：真实选择器通道返回合成文件，App 上传、预览、安装，通过原表单新建并保存自定义资料，原 Markdown 展示器排版正文；停用、更新、重新启用、移除后原资料定义和内容保持。系统文件面板本身没有人工实测。
- 原插件、模板发现和凭据模板回归6项通过；原远程审批、共用预览和模板录入13项通过。原联网编辑/重连/换Token/换服务器/离线场景单独复验通过（67秒）。初次回归只等到“编辑信息”文字出现，点到了刷新期间的禁用按钮；改为等待按钮实际可用及输入框出现后通过，没有删掉原编辑或断线检查。
- 共享包、服务及 App 静态分析通过。

主要测试：apps/server/test/template_catalog_test.dart、apps/desktop/test/online_plugins_widget_test.dart。现有 shared_template_preview_test.dart 验证信息库和提案使用同一插件展示及 Markdown 逻辑。

本机日志：server-template-suite.log、server-template-tests.log、linux-server-templates.log、linux-template-examples.log、online-plugin-ui-tests.log、shared-plugin-regression.log、online-template-regression.log、online-editor-template-regression.log、desktop-template-analysis.log、server-template-analysis.log，均在忽略的 local/server-first-stage。组合回归日志保留首次失败，以后续编辑专项为有效通过证据，不将失败日志写成全绿。

Linux 完整服务检查使用 a03 验证基础镜像并只读挂载当前服务、测试和共享模块；最新专项使用已构建的 a05 镜像及当前测试/共享模块，均为当前源码、无真实材料。两者都是开发验证镜像，不是 #102 最终发布镜像。统一候选、正式安装和真实资料迁移尚未进行；#103–#105 未推进。
