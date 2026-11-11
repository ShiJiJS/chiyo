# Windows 联网版 Codex 接入

先使用同包 App 在设置中连接现有 NAS。连接校验及首次加载成功后自动准备本机受限设备配置，CLI 默认发现当前连接；审批仍由用户在 App 完成。

## 准备运行目录

从完整同版本包调用，选择一个全新且稳定的输出目录：

```powershell
& 'C:\知予完整包\cli\info-prepare-codex.exe' --state-root 'C:\本机私有状态\codex' 'C:\知予运行目录'
```

生成器复制实际 Codex CLI、hook、worker，生成 hooks.json 和 skills/agent-info-access 下的模板及引用，拒绝覆盖已有目录。它不会安装、合并个人配置或自动授予 hook 信任。GH/AWS 工具保留在原完整包；准备目录通过公开指针核对匹配的完整包和二进制，保留原完整包的位置。

用户准备接入后审查准确的路径和 hook 定义，按当前 Codex 正式入口安装/信任，保留已有配置。Windows 私有状态由当前用户 DPAPI/ACL 保护；不能复制其他设备的状态代替本机登记。

## 能力和使用

公开能力查询不创建批准范围：

```powershell
'{"command":"capabilities"}' | & 'C:\知予完整包\cli\info.exe'
```

联网版的 credentialToolScope=current_device 表示工具观察来自当前电脑。GH/AWS 使用返回的完整随包路径，SSH 使用返回的系统路径；不可用或版本不符时先修复工具，不退回个人登录配置。

正式宿主启动事件或显式接入为新聊天建立未批准的关联；主/子身份按原会话范围核对。访问或凭据使用仍须申请和用户批准，提交提案不等于已保存。App 可以关闭，CLI 仍连接 NAS。

关联引用是该聊天的私密能力，只使用当前上下文已经收到的引用，并通过独立 stdin 交给 CLI。不要放入 shell 命令、argv、日志或仓库。引用丢失时重新连接；公开聊天 ID、请求 ID 或结束索引不能恢复读取关联。

结束只使用原 end-only 能力；普通 CLI 退出、切换聊天和子调用结束不自动结束根聊天。两秒结束回调未确认时保留 end_pending，按原结束索引核对，不把超时当成功或生成新的读取关联。恢复或 NAS 正常重启不会延长原期限。

当前模板位于 [cli/template](cli/template/)，实际能力说明随生成目录一并提供。正式安装/信任、真实宿主启动和结束事件的验收，与受控 CLI 检查分别记录；待办见 [ACCEPTANCE.md](ACCEPTANCE.md)。
