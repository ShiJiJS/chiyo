# 集中修正后的Mac ARM64候选包（#50）

2026-10-22，从干净Mac分支源码a458035aba8aad582e14877553bd7e696b909957构建。
版本 `0.4.0+12-mac-dev.a458035aba8a`；只生成和验证产物，没有替换当前4690e79普通
安装，没有打开生产资料库、访问Keychain或新增系统确认。仍为本机ad-hoc开发预览。
[产物、阶段、源码检查及清理证据](evidence/macos-package-a458035/verification.json)。

ZIP保留在：

`build/macos-adaptation/issue50-package-12/agent-info-manage-0.4.0+12-mac-dev.a458035aba8a-macos-arm64.zip`

大小130,950,765字节；SHA256：
`927d9d0f0aa5a4c14fac3322c95e8cdfaf94e9f4e5f8dd00e1836ffd07c70c39`。
随包manifest SHA256：
`7601302fdd9405d396f14a2d5bf4ff1aa27fe99b0d6977064f561b8d6e6d06a4`。

本包集中纳入此前已分别验证、尚未换入普通安装的修正：

- [Mac原生全选](macos-native-text-editing.md)、凭据最近使用显示及准确的随包使用说明。
- [持久工作目录读写范围](macos-working-directory.md)，保留旧只读书签的访问边界。
- [状态项实际可见性和隐藏窗口回退](macos-status-fallback.md)。
- [原生面板取消后的原控件焦点](macos-editor-focus.md)。
- [搜索动作不再覆盖默认键盘动作](macos-default-keyboard-actions.md)。

以上各自实机证据仍保留其原源码/入口范围，不因打包自动变为本ZIP的普通GUI验收。
从按钮发送CUA Shift-Tab、真实中文组合输入、系统面板快捷键等未通过范围没有消失。

## 固定源码构建和解包检查

```sh
python3 scripts/package-macos.py build/macos-adaptation/issue50-package-12 --check
```

四包严格分析和测试通过：Core285/6、CLI75/40、Storage159/18、Desktop199/2
（通过/条件跳过），合计718通过、66跳过。21个源码检查、Release、AOT编译/签名、
归档、中文空格路径解包及运行阶段均退出0；解包后6项CLI/hook/worker测试与源码
检查有重叠，不累加成724项。原生编译既有弃用警告原样保留，不宣称全日志零警告。

7,971项文件/链接、75个Mach-O；载荷包含App、worker、五个AOT CLI程序、SQLCipher
诊断、GH/AWS工具、Skill、说明与许可证。App/worker/CLI主程序ARM64；原bundle身份
com.example.infoDesktop、沙盒、用户选择文件范围和worker继承保持，无Release调试
entitlement。最低声明macOS14.0，实测宿主仅ARM64/macOS27.0.1；未验证其他系统或Intel。

解包的全部文件字节/模式/内部链接及manifest与归档前一致；App两次deep/strict
签名核对通过。随包说明10个本地链接均存在且不越出整包。仅PATH=/usr/bin:/bin
运行实际AOT存储诊断，确认SQLCipher4.19.0 community；CLI/hook/worker检查通过。
应用/随包工具运行不依赖开发SDK；测试驱动本身使用SDK，不能以此代替干净用户。

## 生成副本清理和保留范围

ZIP摘要再次核对后，注销三份生成App的LaunchServices登记（均退出0），再删除本轮
归档前载荷、验证解包目录、诊断编译目录及根desktop的macOS/flutter_build/hooks_runner
生成缓存，共六个明确目录，原分配空间1,881,712KiB（约1.79GiB）。没有删除SDK、
依赖、任何资料容器、旧新ZIP、私有备份或恢复密钥。

清理后扫描build/macos-adaptation、local、apps/desktop/build，只剩固定中文目录一份
完整App，零生成dSYM（SDK/依赖缓存除外）。原固定manifest字节不变，7,971项内容/
模式/链接无差异、deep/strict签名通过，原PID53592仍运行。没有将旧目录逐文件混入新包。

#50继续OPEN、2/6。仍需最终新签名取得原Keychain访问、原资料升级和普通GUI复验，
最终一致产物的通知/备份恢复/Codex联合闭环，以及用户提供的干净macOS用户或另一ARM
Mac。旧版合成资料的当前私有备份保留，未因构建成功声称升级、回滚或干净环境通过。
本轮没有发起新的系统允许，没有变更签名信任/ACL或Codex hook信任，也未发布Release、
合并main/Windows分支或运行Windows CI。
