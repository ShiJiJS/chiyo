# Mac 原生编辑菜单的可用状态与选区删除（#48 / #50）

2026-10-22，基于63e1ce9，仅Mac分支。
[原始运行、源码、失败和清理记录](evidence/macos-editing-menu-state/verification.json)。

原生桥原先只要焦点在Flutter NSTextView就对全部项目返回true；实际不可复制、只读或
没有历史时，菜单仍看似可用。现通过同一MethodChannel请求当前EditableText的七项布尔
状态：复制、剪切、粘贴、全选、撤销、重做、删除选区。只查剪贴板是否有字符串，不为
菜单查询读取剪贴板正文，也不跨通道传文字、历史内容或凭据。

选区、只读、obscure及selectionEnabled限制由当前编辑器决定；历史可用性复用框架
UndoManager的当前焦点client，不维护另一套撤销栈。异步剪贴板查询结束后重新核对
焦点、State和当前owner；换焦点或卸载后的旧结果丢弃。新增Delete仅删除有效非空选区，
只读/禁用选择时明确拒绝，交给框架DeleteCharacterIntent；没有拦截Backspace普通输入。

原生菜单验证是同步调用，因此合并同轮查询，收到变化的状态后再update菜单；相同
快照不再触发update，避免循环。跟踪通知改变时使旧回复失效，非Flutter响应者仍按原生
动作验证。首轮仅依赖NSMenu跟踪通知，实际辅助功能打开菜单没有观察到通知，全部变灰；
首轮未接受。现也从真实validateMenuItem入口刷新。第一次AX读取可能仍是禁用或上次
快照，后续实际收到Flutter回复才准确；本轮未宣称菜单状态同步零延迟。

## 实际原生验收

独立Release，普通WidgetsFlutterBinding、产品DesktopWindowFrame/编辑桥及标准TextField，
不启动Bootstrap、资料库、Agent服务或Keychain。QA增加只读/obscure切换、合成文本状态
日志及此前审计的内存剪贴板保存/恢复。NativeTextEditingMenu除两行布尔日志与产品
逐字节一致，Dart桥完全一致；MainFlutterWindow去除隔离剪贴板块后与产品完全一致。

| 进程与动作 | 结果 |
| --- | --- |
| 首轮94057 | 菜单一直灰，未见跟踪通知日志；保留失败实现和日志，退出0。 |
| 第二轮94661 | 验证入口查询收到布尔状态，异步更新后空框可粘贴、全选可复制/剪切、只读仅可复制；发现原生Delete仍可用，未作为最终实现。退出0。 |
| 最终95562，输入FlutterBaseline并全选，实际菜单Delete | controller与AX均清空。空框复制/剪切/Delete/全选禁用，Undo启用。 |
| 实际菜单Undo、再次打开菜单、Redo | 恢复15字节合成原文，Undo禁用/Redo可用；Redo再次清空模型。 |
| 快捷键撤销后全选、切只读并重新聚焦 | Copy启用；Cut、Paste、匹配样式、Delete、Undo、Redo禁用。 |
| 恢复可编辑并切obscure后全选 | Copy/Cut禁用，Paste/Delete可用；遮蔽仍允许编辑和删除。 |
| 真正NSSavePanel文件名Delete、Undo、Redo、Cancel | 文件名清空且Save禁用→原名恢复且Save可用→再次清空且Save禁用→取消，没有保存文件，Flutter草稿仍是原合成值。 |
| 回到遮蔽字段，全选后⌘C、⌘V | 先前合成中文剪贴板未被英文覆盖，controller最终fixtureExact=true，确认复制保护生效。 |

三轮均实际⌘Q退出0，原剪贴板各格式只在native内存保存，退出恢复；未输出原剪贴板
正文或落盘。实际AX/截图保留在会话，归档为明确的转录，没有宣称另存了一套截图。

## 尚未通过的辅助功能隐私检查

在QA切换只读/obscure及开关菜单、保存面板后，可视画面显示圆点，但CUA AX有时返回
已知合成明文。另一次恢复可编辑时AX暂为空而画面/controller仍保留原文。不能把AX值
直接等同于模型，也不能因复制受保护就宣布辅助功能不会暴露遮蔽字段。未确定是
Flutter字段编辑器、切换状态或工具的行为；需要独立对照，列入#48/#50待验证事项。
没有使用真实秘密，未宣称此问题由本补丁引入或已经修复。

## 自动回归与清理

两项新状态查询回归在旧实现均失败（方法未实现）；初步相关16项通过。追加Delete后，
最终完整桌面209通过/2条件跳过、严格分析退出0。覆盖全选/无选区、各字段历史、只读、
遮蔽复制/剪切限制、遮蔽可删除、无文本剪贴板及等待期间切焦点；查询不调用
Clipboard.getData。中间误将可编辑遮蔽字段的Delete预期为false，失败日志保留，随后
纠正测试预期；生产删除只读限制保持。最初路径错误导致没有匹配测试的准备日志也
保留，与真正旧实现两项失败分别记录。Core/CLI/Storage未改动，没有重复累加旧结果。

最终Release及deep/strict签名通过，原有原生弃用警告保留。注销独立App、删除自有源
副本/构建和本轮测试缓存；具体分配空间及固定安装7971项/签名/PID复核见cleanup.json。
SDK、旧ZIP、加密备份、恢复密钥保持。固定4690e79安装及保留的f93c3bd候选均未包含
本轮修正；没有新增系统确认、Keychain调用、普通库变更、Windows原生改动或CI。
#48继续OPEN、3/6；#50继续OPEN、2/6，最终同包、物理IME和其余条件继续待验。
