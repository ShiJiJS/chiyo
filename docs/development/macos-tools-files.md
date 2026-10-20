# Mac 桌面工具与附件验收（#44）

## 真实同机 HTTP 文件消费（2026-10-21）

QA 源码 `2cd6111` 增加 `--consume-files`：实际签名 Debug Flutter/SQLCipher
创建受管副本，独立 `01c1f14` 整包的 AOT CLI 领取路径，再由系统 `/usr/bin/curl`
直接将该路径的文件 PUT 到只监听 `127.0.0.1` 的临时 HTTP 接收端。
没有把读取路径或 Python 直接读文件当作上传完成；接收端比较实际收到的全部字节，
返回长度和 SHA-256，客户端核对成功响应后才释放副本。

最终第二轮完整通过：10 个原生阶段、44 次 CLI 状态断言、6 份独立交付，
每份收到 1,024 字节并与合成原文完全一致。覆盖初次领取、文本编辑后、修改提案确认后、
文本移除后、文本回收恢复后及同进程资料库/服务重开并重新批准后。
相同操作重查保持同一副本和版本；原附件始终为版本 1，信息最终版本 5。
未批准、另一会话及重开后的旧关联领取被拒绝；文本恢复生成新身份，需要重新批准。

6 次显式 `file-release` 后路径均不存在，再次使用该路径执行 curl 均退出 26，
接收端没有新增成功上传。已接收字节不会因本地释放而撤回；这不是撤回已上传内容的保证。
本例没有模拟远端浏览器；随包 [普通文件说明](../../integrations/codex/skills/agent-info-access/references/information-files.md)
明确工具必须能访问同机文件系统，远端不可访问时报告传输限制，不提供隐式远程桥接。

Flutter 测试宿主及三个 AOT CLI 进程均退出 0，HTTP 接收端关闭，成功合成根清理。
严格签名和沙盒 entitlement 核对通过；测试宿主为带 JIT/调试权限的 Debug 应用，
不是安装后的 Release 整包。八张原生渲染图保留，复核重开界面与数据库状态一致。
第一轮也通过；第二轮仅补 runner 的接收端清理失败记录，最终源码摘要逐一匹配 `2cd6111`，
不将两轮重叠结果累加。普通 `lib/main.dart` Debug 入口随后恢复并验签。

[原始日志、接收回执、源码和截图](evidence/macos-file-consumer/verification.json)。
只有 QA/文档变更，生产代码与现有 `01c1f14` 整包未变。
第 5 条同机消费条件已有直接证据；#44 仍 OPEN，其他复合条件不提前勾选。

复跑（输出目录须不存在）：

```sh
python3 scripts/qa/macos-attachment-preserve-ui.py build/macos-adaptation/file-consumer-next \
  --delivery 'build/macos-adaptation/issue50-package-7/verify/中文 空格 路径/AgentInfoManage' \
  --consume-files
```

Mac 仍锁屏。初始信息/临时数据库密钥/批准为隔离夹具；UI 由原生 tester 驱动，
不代表真实键盘、系统选择/另存面板、Keychain 或浏览器网站验收。
实际工具目录许可、书签重开/升级、外部 GH/AWS、文件替换/版本/撤销到期联合流程、
容量及最终安装包闭环继续按原票执行。

## 较早工具工作流基线

2026-10-21，当前源码 `7a33585`（产品 Keychain 修复 `86e35f3`），#44 保持 OPEN。

重新运行签名 Debug Flutter 沙盒应用自动工作流：

```bash
.tools/qa-python/bin/python scripts/qa/macos-workflows.py --automatic
```

**1 项完整原生工作流通过**。覆盖当前界面组件编辑保存/另存、实际审批、真实
随包 AOT worker、系统 SSH 的 0/1 两种退出码、防重放、执行回执、普通附件原文
领取/释放和两类许可分别撤销。使用实际 SQLCipher、临时测试密钥和只监听
loopback 的合成 SSH 服务；未打开生产库。

本机未能将应用自动置前，原生测试仍完成。自动模式用测试路径替代系统文件面板；
这份结果不能证明当前版本的 NSOpenPanel/NSSavePanel、实际可见页面、
真实 Keychain 或最终发行包已通过。旧版本的真实面板证据仍见
[Mac 适配记录](macos-runtime-adaptation.md)，不自动扩大到新包。

[原始日志与范围清单](evidence/macos-tools-files/verification.json)保留构建警告、
前台失败提示、测试阶段和最终结果。

下一步为沙盒桌面里的真实 GH/AWS 外部工具路径与权限验证、普通副本实际消费、
当前包的原生文件面板复验及完整历史/重开/容量边界。独立 CLI 接收器通过不能
替代桌面沙盒路径验收。

## 外部工具实际失败（同日）

新增 opt-in 原生入口 `macos_external_tools_native_test.dart`，在同一签名沙盒
内读取用户指定的工具，并调用生产的身份/版本检查器。没有传入任何凭据或调用
外部服务；不会通过开发终端继承认证。

本机项目内的 GH 2.102.0 与 AWS CLI 2.38.1 两条已知路径都在读取阶段返回
EPERM（errno 1），尚未执行版本检查；原生测试 **0 通过/1 失败**，严格分析通过。
这证明当前桌面应用还不能使用这两份容器外工具，独立 CLI 的旧通过记录不能
覆盖它。未禁用沙盒或把拒绝改成通过。

需要补主人通过系统面板选择工具目录、保存 security-scoped bookmark、启动时
恢复访问、失效/拒绝时显示重新选择入口，再核对随包 worker 继承访问及实际
GH/AWS 接收端。AWS 的依赖文件还需同目录范围验证，不能只授予入口文件后
推定整套工具可用。

Computer Use 只读查询确认当前 Mac 锁屏，无法进行原生选择；其他自动化仍可
运行。这是实际面板验收的暂时条件，不是停止实现和其他票据的理由。

## 工具目录访问入口与故障回归（同日）

源码 `3c0e2886a2c44c65ade0a48f279c803a14cd2ccb`。在现有“设置 → 应用运行”
加入 Mac 工具目录入口，使用实际 NSOpenPanel 选择目录，原生层创建 app-scoped
security-scoped bookmark，持有访问范围并在启动时恢复。只能选择文件夹，
没有允许 Dart 或 Agent 传入路径自行授予访问的接口；书签内容不经过 MethodChannel、
HTTP 接口或便携备份。新增 bookmark entitlement，App Sandbox 保持启用。

选择 GH/AWS 时应包含实际程序及其依赖的安装目录；快捷方式指向目录范围外的
程序不能据此推定可用。这里恢复的是系统目录访问，凭据使用仍须独立审批和
实际程序身份/版本核查。持久书签请求只读访问，但现有 user-selected.read-write
entitlement 保留；不将本次面板选择宣称为强制只读隔离。

书签文件位于应用容器的 Application Support/AgentInfoManage/tool-access/
directories.json，与资料库分离。原生层限制记录数和输入容量，原子写入，
临时文件创建即为 0600。保存失败保留原记录与已有访问，损坏文件不被空列表覆盖；
失效、拒绝和目录移除显示为需要重新选择。移除保存项不删除用户文件，也不承诺
收回已运行工具持有的访问。更新包后是否仍能恢复访问仍需真实系统验收。

本轮结果：

| 验证 | 结果与边界 |
| --- | --- |
| Swift 原生存储 | 9 项通过；真实磁盘，受控 OS scope adapter，不能替代实际沙盒许可 |
| 设置入口及通道 | 8 项新增测试通过，覆盖取消、写入失败、重选、移除、并发禁用、销毁、窄窗及放大文字 |
| 完整 desktop 回归 | 严格分析通过；173 项通过、2 项跳过，包含上述 8 项 |
| Release | 构建通过，deep/strict codesign 通过；保留已有 Keychain API 弃用警告 |
| 新签名 Debug 联合工作流 | 1 项通过；真实 SQLCipher、worker、SSH 0/1、审批/历史、附件领取/释放和独立撤销；密钥与文件面板路径为测试夹具 |

第一次原生回归发现 URL 属性缓存导致已删除目录仍显示可用。修复为清除缓存后
重新核查，随后完整 9 项通过；该失败不是 GH/AWS 授权成功的证据。
原始日志、源版本与摘要见
[本轮验收清单](evidence/macos-tools-files/tool-access-verification.json)。

复验命令（Swift 输出目录必须新建）：

```bash
xcrun swiftc -parse-as-library \
  apps/desktop/macos/Runner/ToolAccessStore.swift \
  scripts/qa/macos-tool-access-store-test.swift -o build/macos-tool-access-test
build/macos-tool-access-test build/macos-adaptation/tool-access-new-run
```

锁屏状态再次得到 Computer Use 确认。当前实现已可继续做其他独立测试；
真实外部工具目录选择、取消和焦点、书签跨重开/更新恢复、GH/AWS 及 worker
继承访问仍未通过。之前 EPERM 失败记录保持有效，#44 不关闭。
