# 包含编辑与审批修正的 Mac ARM64 候选（#50）

2026-10-22，干净源码 f93c3bd8fe576c7002d42711c420426c0a29c92f，版本
`0.4.0+12-mac-dev.f93c3bd8fe57`。包含此前原生复制/剪切/粘贴、撤销/重做、
匹配样式粘贴、默认键盘动作及审批计数修正。只在 Mac 分支生成；没有替换已授权的
4690e79 固定安装，没有新 Keychain 提示、Codex hook 信任或 Windows CI。
[阶段、manifest、源码快照与清理证据](evidence/macos-package-f93c3bd/verification.json)。

保留 ZIP：
`build/macos-adaptation/issue50-package-14/agent-info-manage-0.4.0+12-mac-dev.f93c3bd8fe57-macos-arm64.zip`

130,953,645 字节，SHA256：
`e1b964d36ce6f4d0cbf763a613d94d4a56dab60282e88fb043f5d68745b6b8c7`。
Manifest SHA256：
`77e4c6d46b5e28ccb062d50b86142ba174a65981d8b91080cd394c37de689aab`。

Stock 打包器使用 --check，21阶段全部退出0。四包严格分析通过；Core285/6、CLI75/40、
Storage159/18、Desktop205/2，合计724通过、66条件跳过。源码640项在构建前后逐字节
一致，并逐项核对固定提交 Git 对象；快照 SHA256：
`b072ec6e721462d13cba95749024e79c2e6c97d3df61166ed95862bd379cd1ae`。
之后新增的组合输入测试不在此包源码中，单独14项相关结果见组合文字记录，不重复累加。

Release/AOT签名、中文空格目录解包、SQLCipher与CLI/hook/worker检查通过。
载荷7,971项、75个Mach-O；App及主程序ARM64，沙盒和worker继承保持，无Release调试
entitlement。包和解包后deep/strict验签通过。仍为本机 ad-hoc 开发包，未公证；最低声明
macOS14.0，实测仅ARM64/macOS27.0.1。上述结果不代替干净用户、普通GUI、物理IME、
Keychain跨版本授权或真实Codex联合验收；#50继续OPEN、2/6。

监督器注销三份生成App，六处明确的归档前/解包/诊断构建与生成缓存已回收
1,881,736KiB（约1.79GiB），保留ZIP、manifest和日志。固定安装7,971项无差异，
deep/strict签名退出0，PID53592仍在。测试/预览扫描范围只有固定安装一份完整App、
零生成dSYM；SDK、依赖、旧ZIP、加密备份和恢复密钥保留。
