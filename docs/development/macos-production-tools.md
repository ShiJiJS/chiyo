# Mac 生产构建随包工具与路径发现（#44 / #50）

2026-10-21，独立 `codex/macos-adaptation`。生产实现 `1efb4bb`，最终固定源码
`4690e79357bb728da22193d8dadd6dc8a8ce2ce6`。
[原始日志、界面、源码和逐文件摘要](evidence/macos-production-tools/verification.json)。

## 产品改动

Release 入口 `scripts/dev-macos.sh build` 现在组装完整官方 GH 2.102.0 ARM64
和 AWS CLI 2.38.1 载荷，不再依赖 QA 向应用临时复制工具。归档 URL、SHA256、
入口摘要及声明来源固定在 `third_party/macos-tools.json`；只从校验后的归档提取，
不复制本机可变安装、不执行 AWS 安装脚本。AWS 另核对 AMZN Mobile LLC 的安装器签名。

完整文件、权限、内部符号链接、安装器许可、GH MIT 许可与 AWS 固定源码 tag 的
第三方声明均保留；内层清单含 7,832 个文件/链接。外层应用重新封签并做 deep/strict
核对。App Sandbox、Release entitlements 和 worker 继承方式保持，没有新增执行例外。
来源为 [GH 官方发布](https://github.com/cli/cli/releases/tag/v2.102.0)、
[AWS 固定安装器](https://awscli.amazonaws.com/AWSCLIV2-2.38.1.pkg) 及
[AWS 2.38.1 固定源码](https://github.com/aws/aws-cli/tree/10b7b71c678dd01942a88071be7cddb683daa802)。

Mac `capabilities` 增加 `credential-tools.v1` / `credentialTools`，给出 receiver、
随包版本、当前绝对路径及入口校验状态。缺失、改字节、无执行位、重复/错误版本声明、
路径穿越或链接逃逸均不提供可用入口；不回退到 PATH。移动应用后按新位置发现。
SSH 使用系统 `/usr/bin/ssh`，实际版本在每次使用检查。公开发现不创建授权会话，
不批准凭据、不启动程序；真实操作继续冻结身份/计划并遵守原批准期限。
非 Mac bootstrap 不提供这个可选能力，Windows 原生目录无改动，未运行 Windows CI。

设置 → 应用运行提供状态与复制路径，明确外部目录书签只提供文件访问。
Debug `flutter run` 不组装工具；需要工具验收时使用完整 Release 入口。
入口摘要核对不替代实际版本、完整依赖运行或签名验收。

## 实际移动、界面与沙盒执行

`macos-tools-ui.py --bundled` 使用普通 binding、生产 bootstrap/设置/审批与随包
AOT worker，只改变 QA bundle ID、合成内存密钥和夹具资料。Release 由生产入口组装，
构建后没有 QA 工具复制或额外重签步骤。应用移动到中文空格路径后再启动，
deep/strict 签名通过；没有工具目录书签。

实际设置界面显示两条移动后的正确路径和版本，点击复制后显示成功反馈；精确复制值
另由 widget 测试核对。实际审批三个独立合成申请后：

| 操作 | 实际结果 |
| --- | --- |
| AWS STS 身份查询、SSM 写入、同一授权读取 | 三次退出 0，独立回环服务核对完整 SigV4，读写值一致。 |
| AWS 另一份错误合成秘密 | 服务拒绝签名一次，退出 254。 |
| GH 无效非空合成 Token 的 `/user` 请求 | 实际 HTTP401、退出 1，不把网络失败作为通过。 |
| 五次 operationId 重查 | 原执行 ID 保持，不重跑，截止时间不变。 |
| 清理与输出 | 四次 AWS 材料清理 complete，GH 无文件材料，输出无合成秘密原文。 |

实际界面查看 GH 已退出/1；⌘Q 后主进程退出 0、资料库关闭一次、Flutter 异常 0。
回环服务测试清理退出 -15 单列。8 个准备/分析/构建/签名阶段均退出 0。
初始资料和请求由夹具准备，审批由真实 CUA 完成；没有真实账号成功访问、生产 Keychain、
最终安装后的普通 main.dart GUI 或全部键盘可访问性承诺。

## 正式整包与回归

同一干净源码生成 `issue50-package-10`，四包严格分析通过：Core 285/6、CLI 75/40、
Storage 159/18、Desktop 188/2（通过/条件跳过），共 **707 通过、66 跳过**。
构建器的错误缓存摘要/依赖链接逃逸两项负向检查通过。
先前 package-8 因设置测试点击屏幕外按钮失败，修复为滚动后点击；package-9 在并行
Release 构建期间一个 CLI 测试达到既有 30 秒上限。两轮失败原样保留；未放宽超时，
最终单独运行完整 suite 通过，不累加重复测试。

新包 `0.4.0+12-mac-dev.4690e79357bb`，ZIP **130,946,101 字节**，SHA256：
`0bebec70ba5860b25592024f8f6f00760b587ea91ef4c0d77c0fb0940bce360a`。
21 个打包/签名/解包阶段退出 0，7,971 个文件/链接、75 个 Mach-O。
App、worker 和 CLI 主程序 ARM64，依赖至少有 ARM64；最低声明 14.0，实测宿主仍为
macOS 27.0.1。中文空格路径解包后全部字节/权限/链接一致，deep/strict 签名通过。
只用系统 PATH 的 AOT 存储诊断和六项实际随包 CLI/worker 检查通过，后者与源码测试重叠。

正式整包与实际界面测试的完整工具清单 SHA256 相同：
`27110b9f4c2053a98f8b852b3ffc93a83e2548724370b5e60ca34ca20b7f087c`。
这将实际沙盒执行关联到同一完整工具载荷，但不能替代普通整包 main.dart 的最终 GUI 联验。

生成的测试应用、合成库、私密关联、控制文件和编译缓存已清理；项目验收目录只保留
一份最新解包应用，生成 dSYM 为 0。旧 `01c1f14` ZIP 仅保留作后续升级基线，旧解包应用已移除。
最新 ZIP 和应用位于 `build/macos-adaptation/issue50-package-10/`。

## 仍待完成

#44 保持 OPEN、1/6；#50 保持 OPEN、1/6，本轮刷新生产工具与整包组成证据。
继续最终同包 SSH/系统文件面板、版本变更拒绝、撤销/真实到期、历史重开等联合条件；
稳定位置安装和签名/真实 Keychain 升级、通知、睡眠唤醒、干净用户及 Codex 日常闭环
仍需分别验证。原验收范围保留，不把隔离 UI 或限制 PATH 当作干净环境验收。

复跑时输出目录须不存在，UI runner 等待实际批准三次合成申请后正常退出：

```sh
python3 scripts/package-macos.py build/macos-adaptation/NEW_PACKAGE --check
.tools/qa-python/bin/python scripts/qa/macos-tools-ui.py \
  build/macos-adaptation/NEW_PRODUCTION_TOOLS_UI --bundled
```

避免在完整 CLI 回归期间同时做大型 native Release 编译。每轮结束清理生成应用和缓存，
保留日志、源码版本和失败事实；复用已校验下载缓存不会修改系统安装。
