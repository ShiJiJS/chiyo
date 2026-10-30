# 知予 Mac M04：固定候选联合验收记录

对应 #73，前置业务范围为 #70–#72。本记录区分候选打包、完整界面接缝、原生系统以及真实AI宿主，不把分项证据拼成已经日用交付的结论。

## 2026-10-30：完整 Flutter 界面与包内 CLI

新增 `scripts/qa/check-owner-ui.py` / `apps/desktop/tool/check_owner_ui.dart`，在两个独立Owner测试进程运行正式DesktopLauncher/OwnerWorkspaceHost/WorkspaceApp。SQLCipher、HTTP服务和包内独立CLI为真实实现；OS平台使用NativeDesktopFixture，界面输入使用WidgetTester。没有产品代码变更或另加演示模式。

候选为 `b0578cf6ed9890a2c689ec7ee65af5f6ba869bb4` 的 `AgentInfoManage`，UI/核心/存储/CLI实现及pubspec依赖文件已核对与该候选源码一致，CLI摘要与清单一致。Owner界面是Flutter测试进程运行同源实现，不是直接启动已打包的Release App；因此不能据此勾选同候选原生系统验收。

两阶段共12个具名检查通过：

- 完整界面从空加密库录入服务器资料，独立CLI查询公开目录而读不到正文；AI申请出现在真实收件箱。
- 主人在界面取消一个字段并部分批准；CLI只读获批字段，未选字段和另一个聊天被拒绝。
- 主人从信息库编辑已授权字段，实际CLI读取修正值；稳定字段身份和固定期限不变。
- 从审批打开准确历史，新读取刷新实际访问次数（包含拒绝的访问结果，不把批准当读取）。打开批准时快照仍显示原值，而不是当前修正值。
- 从历史页撤销后缓存读取能力被拒绝，返回原审批保持同一请求及撤销状态；另一次申请通过界面拒绝，CLI看到denied。
- 留下一个有效授权后走正式runtime关闭；另一个Owner进程重开同库，通过列表实际打开资料详情，显示修正后的内容。历史对应原请求并显示会话结束，新会话不能领回旧授权。

最终命令：

```sh
python3 scripts/qa/check-owner-ui.py \
  --package build/macos-adaptation/m03-candidate-b0578cf6/AgentInfoManage \
  --report build/macos-adaptation/m04-ui-interop-5.json
```

结果见 [持久证据](evidence/zhiyu-round09/m04-owner-ui-interop.json)；本机日志为 `build/macos-adaptation/m04-ui-interop-5.log`。两阶段分别9项、3项，进程PID不同；测试库、固定测试密钥与临时资料已删除。桌面包 `flutter analyze --no-pub --fatal-infos` 通过，Python AST和diff检查通过。

最初驱动仅等待真实I/O，导致widget zone中的异步审计未推进；随后普通pumpAndSettle也会在等待历史读取时耗尽虚拟时间。已改成同时推进真实I/O和界面帧，并设定有界等待；没有修改产品审批或历史代码来迁就检查。首次分析误在仓库根目录执行，包含SDK及过程文件，不作有效分析结论；最终分析明确在apps/desktop下执行并通过。

本轮没有使用个人资料/Keychain、computer use或Windows CI，没有新建App/dSYM，没有修改已有候选/预览或全局hooks。#73仍OPEN；下一步是原生窗口及独立App重开、真实AI宿主事件/聊天流程和必要系统配合。完整备份UI等后续范围仍未接入。

## 2026-10-30：原生完整界面与独立进程重开

将已有完整界面场景复用于独立沙盒 Debug App：`owner_workflow_native_test.dart` 使用真实 Cocoa/Flutter、系统字体、SQLCipher、正式 bootstrap/runtime 与实际 loopback HTTP。客户端为进程内 CLI AgentClient；包内独立 CLI 另由 widget 回归覆盖，两类证据不混称同一 Release App 或真实 AI 宿主。

```sh
python3 scripts/qa/check-owner-native.py build/macos-adaptation/m04-native-workflow-2 --workflow
```

同一 kernel 的两个独立原生进程分别通过9项和3项检查：界面保存、申请接收、部分批准、越界/跨聊天拒绝、编辑后读取最新值、准确历史及批准时快照、撤销、拒绝、关闭服务，以及独立重开显示已保存修正值且不恢复旧授权。截图为1280×800，已逐张查看；中文及布局正常。发现申请范围与关联资料使用通用“资料字段”标签，缺乏资料名称，作为后续产品修正项，不能因此宣称全部界面验收完成。

驱动仍报告 `Failed to foreground app`；输入由 Flutter 集成框架产生。此结果不证明物理输入、真实 AI 宿主、个人 Keychain 或交付 Release App 通过。没有使用 computer use、Windows CI 或个人资料。原生库已删除，测试 App/dSYM/Xcode产物已清理，原预览摘要保持一致。

第一次运行未注册实际场景，驱动输出null；检查器拒绝把空测试算通过。已将异步准备放入同步注册的测试内部，第二次实际执行通过。最终共享场景重新运行包内独立CLI/widget两进程回归通过12项，desktop静态分析无问题，Python AST检查通过。

[原生结果、截图和回归证据](evidence/zhiyu-round09/m04-native-workflow/result.json)保留准确范围与测试源码摘要。#73保持OPEN；接下来修正上述资料辨识问题，然后更新交付候选并继续真实宿主/系统验收。
