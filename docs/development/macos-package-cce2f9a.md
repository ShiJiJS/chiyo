# 含审批计数修正的Mac ARM64候选包（#50）

2026-10-22，固定干净源码cce2f9a66fa2e355752fec391e6aac89e99eeff8，仅Mac分支。
版本 `0.4.0+12-mac-dev.cce2f9a66fa2`，包含此前集中修正及
[审批筛选计数](macos-inbox-status-counts.md)。没有替换4690e79固定安装，没有打开普通
资料库、访问Keychain、发起新系统确认或注册/信任Codex hooks。
[26份阶段、载荷、监督脚本及清理证据](evidence/macos-package-cce2f9a/verification.json)。

ZIP保留在项目：

`build/macos-adaptation/issue50-package-13/agent-info-manage-0.4.0+12-mac-dev.cce2f9a66fa2-macos-arm64.zip`

130,950,924字节，SHA256：
`1bd79368eb61309e9c8e34480cd46dc3bc8ce6ba1dd5218645eeea6c7db3f1d7`。
manifest SHA256：
`b148ccb8f1179620aac03775ccd0072faba30779bea15b9219e88f115cfd4322`。

## 完整源码检查与打包是两个分别记录的步骤

先实际运行 `scripts/dev-macos.sh check`：四包严格分析通过，Core285/6、CLI75/40、
Storage159/18、Desktop201/2（通过/条件跳过），合计720通过/66跳过。随后保存637项
源码字节摘要，与干净提交中的Git对象逐项相同；打包监督器在构建前后再核对相同
637项。此轮未重新执行同一套源码测试，stock打包器按以下命令运行：

```sh
python3 scripts/package-macos.py build/macos-adaptation/issue50-package-13
```

因此原manifest的sourceChecksRequested如实为false，20阶段中不包含source-checks；
没有把它伪称为21阶段或未运行的--check。完整源码结果及摘要见
[原始检查](evidence/macos-inbox-status-counts/verification.json)，快照SHA256为
`d541adc58252b21dec15c10dfdb80af88356feb316c5a875217a8c77e50a5c90`。
没有把条件跳过或重叠的解包后6项CLI/hook/worker检查额外累加。

20个Release、AOT编译/签名、归档、中文空格解包和运行阶段全部退出0。
7,971项文件/链接的字节、模式、内部链接及manifest与归档前一致；75个Mach-O，
App/worker/CLI主程序ARM64，bundle身份、App沙盒及worker继承保持，无Release调试
entitlement。App两次deep/strict验签、随包10个本地说明链接及系统PATH下的SQLCipher
4.19.0 AOT诊断通过，实际解包CLI/hook/worker6项通过。

仍为本机ad-hoc开发预览；最低声明macOS14.0，实测宿主仅ARM64/macOS27.0.1。
源码与解包验证不等于本ZIP的普通GUI/Keychain升级、物理键盘/中文IME、干净用户或
真实Codex客户端验收。这些范围仍由对应tickets和#50收口。

## 监督器自动清理

本轮监督器在成功或失败后都清理明确的自有输出。成功归档并核对ZIP后，注销三份
生成App（均退出0），清理归档前/解包/诊断编译及根desktop生成缓存共六处，原分配
1,882,004KiB（约1.79GiB）。仅保留ZIP、manifest、运行/阶段日志及监督记录，未删
SDK、依赖、资料容器、任何旧ZIP、私有备份或恢复密钥。

固定安装7,971项字节/模式/链接无差异、deep/strict签名通过，原PID53592仍在；
扫描build/macos-adaptation、local和apps/desktop/build只余一份完整App、零生成dSYM
（SDK/依赖缓存除外）。旧安装已恢复原备份设置页面。

#50继续OPEN、2/6；#47为1/5、#48为3/6。没有发布Release、合并main/Windows分支或
执行Windows CI。最终新签名原资料升级、普通GUI与同包联合闭环仍未完成。
