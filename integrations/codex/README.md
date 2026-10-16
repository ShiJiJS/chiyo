# Codex 接入开发预览（Issue #6）

这份接入用官方 SessionStart hook 提供当前聊天的私密关联。用户不需要
手工生成 token。它仍须真实桌面两聊天验收；当前实现不等于已安装或已验收。
来源：[OpenAI Hooks 文档](https://learn.chatgpt.com/docs/hooks)，2026-10-16 核对。

## 凭据边界

- 随机 256-bit 文件名指向不可变的会话凭据文件；文件在用户私有状态目录，
  Windows 设置仅当前用户继承 ACL，macOS 目录模式 700。创建权限失败则不交付关联。
- 文件只保存本机端口、聊天关联和随机会话能力，不保存全库密钥或授权 token。
  token 每次从服务按私密会话证明领取，读取不会续期。公开请求 ID、聊天 ID
  和 CODEX_THREAD_ID 均不能领取授权。
- 模型收到的随机文件引用本身也是敏感能力。它只用于该聊天 CLI 的 stdin，
  不进入普通响应、日志、argv、仓库或公开缓存。CLI 不接受按聊天 ID 寻找文件。
- CODEX_THREAD_ID 与记录的聊天 ID 比对用于防止误用继承的上下文，是附加关联
  检查，不是认证因素。可读同用户私有文件或已窃取能力的程序仍在 ADR 0002
  明确的安全边界之外。安装 hook 前应复核路径及命令。
- 不读取 hook 的 transcript_path，也不读取 Codex 登录认证或私人聊天历史。
- startup/clear/fork 创建新的未授权会话，重复启动也不会按 ID 复活旧授权。
  resume/compact 不新建关联，提示保留上下文已有引用；服务逐次核查是否仍有效，
  不续期、不复活已结束或撤销的授权。若引用丢失则需明确重新连接，不搜索磁盘。
  旧会话直到撤销、到期或服务退出前仍可能有效；SessionEnd 清理由 #7 实现。
- 应用退出或重启后，磁盘关联文件不会恢复服务端权限。连接失败、损坏文件、
  聊天不匹配分别给出 service_unavailable/association_unavailable，不自动申请。
  私有文件目前由用户在完全退出后清理；自动生命周期清理仍待 #7。

## 生成可审查安装材料

从 `packages/info_cli` 执行（先 `dart pub get`）：

```text
dart run tool/prepare_codex.dart ../../build/codex-preview
```

生成本机可执行文件、hooks.json 和 Skill。命令不会修改任何用户或项目的
`.codex`、不会信任 hook，也不会打开桌面。输出路径应选稳定位置，生成后
移动目录必须重新生成 hook 命令。Windows 命令编码只是安全传参，不含秘密。

准备用户实测时，再经用户明确授权：

1. 保留已有配置，只把 bundle 的 SessionStart 条目合入测试项目的
   `.codex/hooks.json`。先确认没有同一 hook 的重复安装。不要覆盖现有 hook。
2. 将 bundle `skills/agent-info-access` 放到测试项目 `.agents/skills/`，或按
   当前 Codex 的技能安装流程安装此目录。检查 Skill 中的可执行文件绝对路径。
3. 在 Codex 审查并信任准确的 hook 定义；官方 CLI 文档提供 `/hooks`。桌面端
   实际信任入口待用户现场验证，不能据此宣称桌面安装成功，也不要绕过信任。
4. 用户启动信息应用后，新建一个测试聊天。默认服务端口 47125。
   若服务尚未启动，hook 明确报告失败；启动后需重新连接，不能按聊天 ID 补领。
   已存在的聊天若从未收到引用，用户明确要求重新连接后运行 bundle 的
   `info-codex-hook --connect`，它使用当前 CODEX_THREAD_ID 创建未授权会话并交付
   hook 格式上下文；不读取历史，不查询旧凭据。普通 resume 保留已有引用。

目前不会自动执行上述安装步骤。用户只需要配合真实 UI 验证，不要求透露 token。

## 用户配合的两聊天验收

只用虚构资料，避免把关联引用、文件内容和 token 放入报告或截图。

1. 聊天 A 请求 demo-server 的 host 字段。用户确认桌面展示聊天关联、用途及
   字段，仅批准 host。记录公开请求 ID、字段及到期时间。
2. A 退出一次 CLI 进程后，再启动 CLI 两次读取同一字段，应成功且无新审批，
   到期时间不变；读取未批准 username 应失败。
3. 聊天 B 独立启动，只提供 A 的公开请求 ID 和聊天 ID，领取/读取均应失败。
   B 自己提交请求后应出现独立审批。不得把 A 的私密引用交给 B 做演示。
4. A 正常恢复聊天时有效引用仍可使用且不续期；手动撤销后再次读取应失败。
   恢复已撤销/过期会话或 fork 成新的聊天后不能复活原授权。
   自动压缩后验证原引用保留；丢失时应明确重新连接，不静默扩大访问。
5. 完全退出信息应用后读取失败；重启再用旧引用/请求 ID 仍失败。重新连接后
   新申请才能获准。记录 Windows/macOS、Codex 版本、信任入口和实际结果。

CLI 一次 stdin JSON 的内容见 Skill。通用 `info` 仍支持 JSON-lines；Codex 适配
独立于业务命令。wait/cancel 由 #4 提供，主子 agent 和结束事件由 #7 完成。

## 已验证与未验证

Windows 自动化测试启动真实 Dart CLI 子进程、核心服务和 hook payload，覆盖多次
CLI 的复用、固定到期、撤销、已知 ID 无法领取、同 ID 重新启动不复活、其他
聊天引用误用、缺失/错误关联、服务端会话失效、不读取 transcript_path。
这些测试不创建真实 Codex 聊天，不打开应用窗口。

尚未验证：真实桌面安装/信任、两聊天及压缩体验、macOS 执行与权限、主子 agent、
SessionEnd。Issue #6 的真实接入验收在这些必要用户步骤完成前保持未完成。
