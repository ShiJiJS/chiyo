# D5 · 托管凭据与信息关联

2026-10-17，Issue #27。实现范围是独立字符串/文件托管、元数据、版本与生命周期、信息关联、显式可发现目录；实际使用申请、许可、CLI 启动和执行历史由 #28–30 接续。#31 升级完整备份到格式 5 前，只使用虚构测试材料，不交付正式真实凭据支持。

## 保存与边界

`CredentialRepository` 在一个事务中提交凭据元数据与不可变材料快照，成功后才发布内存状态。SQLCipher schema 14 新增 `managed_credentials` 和 `credential_materials`，后者仅在加密数据库中保存内容；字符串 1–65536 UTF-8 字节，文件 1 字节–1 MiB。文件作为不透明字节导入，不解析私钥、Cookie 或授权文件格式；文件选择器复制字节及 basename，源绝对路径不持久化、不传入目录和界面错误。修改或删除源文件不影响托管副本。

普通信息仍只保存普通字段；多对多关联存凭据侧的稳定信息 ID，不复制秘密，不扩大普通读取权限。删除凭据不会删除关联信息。文件名是 owner 可见元数据；Agent catalog 只返回 credentialId、name、publicPurpose、form、version、availability 六项。默认不可发现，回收站、私有备注、文件名、绑定建议和退休版本均不列出。目录按 NFC 名称、ID 排序，1–100 条分页，默认 50。

新 JSON 协议解码在形状校验前拒绝重复 key（包括转义后重复）、嵌套非有限数值及超限。通用 CLI 和 Codex 适配器使用同一解码入口；Codex 的私有 association 是适配器上下文，不作为 catalog 属性转发。HTTP 新路由保留 protocolVersion:1 和固定错误码，不回显输入或内部异常。

## 版本及后续使用接缝

每次轮换建立新 version，旧材料只供 owner 恢复，加密保留 30 天，不可申请使用。停用、删除、轮换、恢复、有效期变更会递增 `useGeneration`；重新启用不会复活旧 generation。恢复建立新版本且停用；回收站及版本恢复不把旧许可映射给新版本。永久删除清除全部材料并保留非秘密 tombstone；定时维护及 reopen 清除超期退休材料。

`owner.checkCredentialEligibility(id, version, {useGeneration})` 只返回非秘密当前元数据，核对当前版本、generation、启停、到期和当前材料仍在。core 内部 `_currentCredentialMaterial` 只给同库后续使用服务消费，owner 和 Agent 接口不提供字节读取。这是 #28 集成的 guard：D5 没有假造待审/已批使用申请，所以不能声称已经验证这些真实申请的失效；#28 需将 generation 和请求终态单调保存，并在轮换、停用、删除、到期后验证旧许可不能启动。

当前备份格式不能包含托管凭据，因此非空凭据库禁止导出旧格式；恢复也拒绝覆盖已有凭据。这是 #31 格式 5 前的明确门槛，不能静默丢弃材料或宣称已完成凭据备份。

## 界面及导航

唯一视觉源是未修改的 `docs/design/prototypes/round-05/`。信息库使用共享 `InformationWorkspace`，保持 240/340/详情三栏和共享字体、颜色、SVG 图标；新增及关联弹窗宽 650，轮换与可见性简单流程宽 780。原型没有真实使用记录时显示“尚未使用”，不伪造历史。`onOpenUsageHistory` 与 `hasUsageRecords` 保留独立的“查看使用记录”入口供 #30；版本与恢复是同一 text-button 语法下的必要新增入口。

普通 tab/信息与凭据切换保留筛选和选择。明确外部导航经 `focusItemId + focusRevision` 定位当前 ID 并清除冲突筛选；不存在时显示缺失状态，不回显其他条目。凭据关联行复用这一接缝。#25 的提案结果应消费同一 main `_openInformation`，普通“前往信息库”仅切 tab。#26 整理许可导航通过 history 的 initialRecordId 接续。

200% 字体下三栏保持独立滚动，详情工具栏显示可交互横向滚动条，真实横拖后可以打开轮换/删除。长名称、备注、125 条列表、空状态、保存失败和放弃草稿均使用实际 owner/UI 状态捕获。轮换/可见性原型采用无分隔线的 simple-flow footer；原有 panel 弹窗默认行为保持。

## 验证记录

核心 owner/service、真实 JSON-lines CLI、实际 SQLCipher 关闭再打开、备份公开边界、widget 和隔离 Windows runner 分别验证。测试目录、字符串和文件均为虚构数据；不启动用户资料库，不读取 infos，不修改 Codex 或系统安全设置。

- 先红后绿：独立凭据/发现目录、轮换与材料保护、CLI catalog、Codex association、HTTP 错误分型、嵌套非有限 JSON、200% 工具栏可达；保存失败、NFC 排序及导航状态的后补测试明确作为行为刻画。
- 实际 Windows native picker 两次：第一次真实取消、第二次真实选择虚构文件；之后创建、关联、catalog、轮换、停用/启用、回收恢复及 SQLCipher reopen。日志标记 `D5_NATIVE_VERIFIED nativePicker=true`。首轮因 driver 未等异步 OS picker 完成而失败，修正等待公共 picker future 后通过；没有抑制 Flutter 断言。
- 可重复自动 native 使用注入的文件选择边界，日志标记 nativePicker=false，不能称为真实 OS picker 验证。Mac 接口保留但没有本机 Mac 实测。
- 视觉 r1/r2/r3 保留迭代，r4 是常规最终完整状态，r6 是补齐真实横滚/操作和关闭控件后的 200% 状态。oil compare 是未修改 Flutter PNG 与原 HTML PNG 的定位工具，像素差异百分比不作为自动通过阈值；正式视觉验收仍依赖 self-view 和独立 review。

具体证据及最终检查见 `docs/development/evidence/27-credentials/README.md`。
