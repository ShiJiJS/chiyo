# Mac 桌面工具与附件验收（#44）

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
