# #38 Windows 固定证据

验收在2026-10-19完成，2026-10-20归档。说明和逐项对应见[完成记录](../../issue38-completion.md)，机器可读索引见[verification.json](verification.json)。

- 生产/完整回归为108403a，最终原生集成为5b1e064；中间仅增加集成验收，生产源码未变。
- 完整665通过/19原生opt-in跳过，四包严格分析及Release通过。原生最终03:53一项完整流程通过，不与完整组加总成独立用例数。
- `raw/`保留失败、最终日志、阶段/接收/清理事实与执行脚本。最终原生和失败浏览器排练的执行源码另存为`.dart.txt`并核对原字节摘要。
- `screens/`为16张已自检的代表图；171张完整渲染图仍在本机`build/qa-issue38-final/matrix-01/screens/`，索引保存全部尺寸、大小和摘要，不声称所有图都入Git或已逐张人工检查。
- 普通附件原字节可以被获准Agent/文档工具读取。浏览器图仅含程序生成的虚构简历，没有真实资料、凭据、会话证明或恢复密钥。

## 本机复现

在仓库根目录使用已配置Flutter/Dart的Windows环境运行原始脚本；它们在整个流水线期间临时使用镜像URL，核对依赖内容后恢复四份原锁。首次需要已有依赖缓存，不在验收中升级依赖。输出目录必须使用新名称，失败结果不覆盖。

```powershell
python docs/development/evidence/issue38-completion/raw/scripts/qa-issue38-native-prepare.py.txt prepare-02
python docs/development/evidence/issue38-completion/raw/scripts/qa-issue38-native-run.py.txt my-native browser
```

第二条需要真正的可用Windows桌面。在`build/qa-issue38-native/my-native/phase.json`观察当前步骤，仅给本轮测试窗口的系统对话框输入该轮自建文件路径。阶段`browser-upload`会给出同机临时URL和已经批准的副本路径：用浏览器真实文件控件选取这个path，核对可读文字，发送至页面自身的本机接收器。成功后保存页面证据、关闭测试标签页，再写入该轮输出目录的`browser-closed`标记，让测试释放副本并结束。标记只控制QA等待，不是应用授权入口。

`synthetic browser`参数仅用于不用系统选择器的排练，不能算原生选择器验收。任何桌面锁屏或Computer Use被用户停止，都停止输入；不操作用户原有程序，也不更改系统安全设置。

全量检查/构建与渲染矩阵的脚本为`raw/scripts/qa-issue38-final-check.py.txt`，分别传入新输出名称和`full`或`matrix`。它们的输出、固定源码和既有运行已列于索引。Release构建不等于最终分发包或干净Windows验收。
