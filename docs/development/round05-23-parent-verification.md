# D1 主集成复验

2026-10-17。实现`3d13b5a`，合入`1852f8c`；其后`5842e6a`只补原型参考，`e78673e`合入默认禁用的隔离通知探针与实际超时记录，未改生产UI。

## 已验证

- 主Agent在集成分支独立运行`./scripts/check.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin -Offline`：CLI18、Core84、Storage41、desktop60及各analyze全部通过。另在公开服务边界复跑收件箱/整理13项，目标异步桌面流程在完整检查后再连续复跑两次，见执行日志。
- 主集成真实Windows `test-windows-native.ps1`通过。独立CLI经随机loopback端口申请，桌面缩小/跨项补选，核对8小时、claim实际范围、重复读取、未批字段拒绝、撤销、一次整理、无改动结束与结果入口、SQLCipher/DPAPI主题重新打开。通知probe的可选fixture参数合入后，默认惰性fixture原生流程再次通过。
- 主Agent从实际CMake配置编译并执行`notification_queue_test`，固定ID的队列/测试通知交错、点击/超时/隐藏/失败/重置合约通过。此合约不冒充实际系统点击。
- 主Agent实看Flutter正常三图、scope、handled、组织pending/complete、mono组织/离线、空结果、审计失败及200%首末字段，并多轮使用oil截图工具的`--compare`。独立评审按HTML精准对照，不打审美分；已列布局和控件遗留最终闭合。参照在[prototype-reference](../design/prototype-reference/)，实际图在[evidence/23-workspace](evidence/23-workspace/)。
- 主Agent另用Computer Use观察唯一隔离exe的真实Windows窗口。测试输出physical2534×1414、DPR2、logical1267×707，含原生caption/fixture横幅的窗口观察不能冒充1x的1440×900或1280×800内容截图。文字保留Chromium次像素/Flutter灰阶栅格记录，不通过改色或换字库追图。

精确核对覆盖：72顶栏、310侧栏、244决定栏、宋体与0.5字距、原SVG、字段横排、期限/V和批准边界、主题描边；扩展态的用途行盒、scope双gutter/48ch/28px行节奏/自然最大高度、handled期限及clock分隔、整理路径右对齐、完成摘要空隙及mono覆盖。200%为原型未覆盖的同风格可访问性延伸，已单列，不能以其替换普通首屏。

## 仍未验成功

两次显式60秒人工通知探针均由真实Shell接受投递并输出READY，均无实际点击回调、无VERIFIED，测试明确非零退出。第二次READY后，主Agent立即做两次窗口枚举及一次应用枚举，工具没有提供可操作的通知窗口，未发送点击。不能因此声称OS没有展示或权限故障；未改OS设置、未伪造回调。详见已入库[探针记录](round05-23-workspace.md)及两份日志。

#23保持OPEN，第五项仍未勾选；不是已完成的Windows人工通知验收。Mac实际运行/通知及跨平台互通仍按用户授权延后。其他页面及凭据功能尚未实现，不作全软件忠实还原或整体交付通过结论。

## 消费者前置条件

#24/#26需要的工作区与API已经合入并独立复验。剩余人工系统点击不改变这些接口，因此两票继续保留#23来源关联，移除仅为该实现前置建立的原生阻塞边，避免用一个外部人工观察缺口阻塞可独立的代码工作。GitHub读回确认：#23为5/6勾选且OPEN，#24/#26为0/6且OPEN，两票blocked_by均空。其余依赖及所有验收条件未删减；总Windows与样式门槛仍保留，尚未进入服务器同步。
