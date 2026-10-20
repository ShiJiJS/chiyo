# Agent Info Manage：Mac ARM64 开发预览

这是本机开发预览包，最终安装升级验收由 #50 跟踪。产品名称为
Agent Info Manage，应用文件仍固定为 `app/info_desktop.app`，
bundle ID 保持 `com.example.infoDesktop`，不另建资料身份。

仅支持 Apple Silicon ARM64。最低构建目标为 macOS 14.0，来自随包 Dart AOT
程序的实际最低系统声明；目前仅在本机 macOS 27.0.1 执行相关验证，
macOS 14 和其他设备尚未实机验收。App、worker 和 CLI 主程序均为 ARM64，
依赖库至少包含 ARM64；不提供 Intel 兼容承诺。

## 包含内容

- `app/info_desktop.app`：Release 桌面应用、SQLCipher、Flutter 运行库及随包 worker。
- `cli/`：无需 Dart SDK 的通用 CLI、Codex 适配器、hook、worker 和材料生成器，
  同时包含 Skill 模板及凭据/普通附件引用。
- `diagnostics/bin/macos-storage-check` 与 `diagnostics/lib/`：
  使用新建合成库验证加密、重开和独立备份恢复的可选诊断程序。
  它使用临时内存密钥，不读取生产库、不验证 Keychain。
- `notices/` 与 `provenance/`：许可证、第三方声明、依赖锁和原生资产来源记录。
- `manifest.json`：版本、源码 SHA、构建宿主、应用身份、最低系统、
  原生架构、签名类型、文件摘要/权限和符号链接。

运行 App 和随包程序不需要 Xcode、Flutter 或 Dart。
当前为本机 ad-hoc 签名，未公证；它不代表其他设备的 Gatekeeper 已通过，
也不保证替换构建后能继续读取旧 Keychain 项。不要用尚未验证的预览包覆盖唯一
可用的旧应用。先保留旧包，并在旧应用中导出完整备份、另存恢复密钥；
旧应用的实际升级/授权恢复仍由 #42/#50 完成，不关闭系统保护来绕过失败。

## 路径与 Codex 材料

先将整个 `AgentInfoManage` 目录放到稳定位置，保留目录结构。
本包的准备命令只写入一个不存在的新目录：

```bash
"/你的稳定路径/AgentInfoManage/cli/info-prepare-codex" \
  "/另一个稳定路径/agent-info-codex"
```

它复制同版本 CLI/hook/worker，生成最终绝对路径的 `hooks.json`、Skill 和引用，
拒绝覆盖已有目录。支持中文、空格与 shell 特殊字符路径。生成后移动目录会让
旧 hook 路径失效，应在新的稳定位置重新生成并审查接入配置。

该命令不会安装/注册/信任 hook，不修改已有 Codex 配置或启动聊天。
接入与实际聊天事件验收见随包 `CODEX-INTEGRATION.md` 和 #49；
其中 Windows 的实机记录不自动适用于此 Mac 包。Mac 的焦点填充尚未支持，
以当前服务 capabilities 为准。

## 构建与验证范围

在干净、已提交的 Mac 分支根目录运行：

```bash
python3 scripts/package-macos.py build/macos-adaptation/new-delivery
# 同时执行四包全部源码检查
python3 scripts/package-macos.py build/macos-adaptation/new-checked-delivery --check
```

仅构建者需要项目工具链和 Python。打包器不改 Flutter 全局设置，
检查源码期间未变化，核对签名/沙盒/架构/最低系统和开发机外部库依赖，
生成 ZIP 与 SHA-256，再解压到中文空格目录复核文件、权限、符号链接和签名。
从解压目录限制 PATH 运行合成存储诊断，并用实际 AOT 材料生成器和 CLI worker
执行相应测试。诊断的源码测试驱动仍需 SDK；随包运行程序本身不需要。

构建输出的 `verification.json` 只有 `complete: true` 才代表上述打包检查通过；
源码四包检查仅在 `sourceChecksRequested: true` 时由打包器运行。
这些结果不等于干净用户安装、Keychain 升级、真实通知、可见系统面板或
真实 Codex 接入已验收。最终同版本应用全流程仍需 #41–#49 的剩余门槛。
