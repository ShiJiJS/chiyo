# 知予 Mac 外壳与预览准备（#62，进行中）

2026-10-26最新指令仅调整tickets和文档，暂不继续开发；以下为此前已保存的Mac首轮准备。工作区中的后续未提交实现保留，不能据此勾选完成条件。恢复时先审阅当前diff及失败/未完成的检查，再按票序继续。本轮从已有Mac适配3ed4573e建立`codex/zhiyu-macos`，以36437d1a整合前端/规划fbff65ee；实现检查点为9cd5314e。main及Windows分支未修改。本文覆盖#62首轮Mac准备，票保持OPEN，尚未进入#63。

## 已实现

- `scripts/dev-macos.sh preview`以独立`com.example.infoDesktop.zhiyuPreview`身份运行；`preview-check`用同一原生配置检查集成。原普通预览、资料容器、Keychain、hooks和安装身份均不替换。
- 原生窗口创建时先判断预览配置，跳过ToolAccessStore、已保存bookmark、秘密编辑器/填充、Keychain、文件面板和正式桌面服务通道。仅保留普通编辑、辅助功能、预览导航和Cocoa正常退出机制；不为菜单开启生产服务。
- Dart启动会验证原生隔离状态和实际窗口标题，缺少正确配置就失败，不静默退回生产。标题在Flutter应用启动覆盖之后设置为“知予 · 界面预览·示例数据”。系统设置/查找菜单接入预览导航，弹窗期间禁止导航，Dock重开保留当前页面。
- Mac使用本机SFNS及PingFang字体，原生和离屏加载同一文件；不将系统字体放入分发包。`zhiyu-macos-reference.py`只在loopback提供冻结原型和已记录的系统字体，平台覆盖仅改变字体族；冻结15文件保持原字节。
- 截图和原生检查支持Mac。原生QA只写其独立容器中的UUID临时目录；退出后由宿主`collect-zhiyu-native.py`收集并编码，避免让沙盒应用运行外部Python或开放文件范围。预览构建不含worker；正常生产构建路径保留。

## 检查和证据范围

[Mac r1证据](evidence/zhiyu-round09/u01/macos/r1/)记录原生隔离状态、检查输出、Mac字体来源/摘要、画面、原始时间采样及编码信息。独立应用实际报告正确标题、无生产服务/目录存储，四个生产通道调用均为MissingPlugin；构建包的预览标记为YES，执行worker不存在。

当前源码严格分析通过，桌面回归296项通过/2项条件跳过，最终预览与离屏6项通过，原生集成1项通过；这些范围有重叠，不相加。固定结果与摘要见[r1检查点](evidence/zhiyu-round09/u01/macos/r1/checkpoint.json)。明/暗、1440×900及1280×800的32组顶部几何对照最大差1.0078125逻辑像素；仅证明顶部这些元素，不扩大为完整页面还原。2项条件跳过为Windows专用的随包焦点填充探针，未计为Mac通过。实际preview_main.dart入口已以独立身份启动、连接Flutter调试器，并经Flutter q退出0；这不代表实际⌘Q链路通过。五个主入口仍为U01基础状态面板，各业务页面由#63–#68负责。

原始PNG帧只在当前build目录保留供动效细查；提交保留GIF、关键图、采样时钟和原帧摘要，可按命令重现。

原生渲染检查覆盖菜单键盘选择、Escape恢复焦点、快速关闭、黑暗主题、200%文字滚动/底部动作及减少动画。实际DPR为2、内容初始800×600；这与离屏两个指定尺寸分开记录，不宣称切换了系统DPI。Flutter报告未能自动置前；本轮证据来自实际Mac Flutter framebuffer与Widget输入，不宣称OS输入或前台桌面截图验收。

已抽帧查看交互记录及明暗菜单/放大文字画面：外壳进入访问审批，打开设计说明，示例保存出现反馈，菜单展开、快速关闭和切换黑暗外观均有画面。弹窗标题/底部动作保持可达，长正文在中间滚动。记录保留原始时钟，未加速；仅凭这段记录不能证明所有120/150/180ms动画误差均在20ms内。

首轮按FLUTTER_TARGET文件名判断预览，遇到Flutter集成测试生成listener.dart时失败；改用作用域内Xcode预览配置和独立身份后通过。随后实测发现Flutter默认标题覆盖，修正启动顺序并增加实际标题断言。失败不计为通过；本轮未要求主人处理Keychain或系统通知。

## 重现

在仓库根目录运行：

```bash
./scripts/dev-macos.sh preview
./scripts/dev-macos.sh preview-check --reporter expanded
```

`preview-check`打印准确的ZHIYU_NATIVE_EVIDENCE临时目录。将输出保存为日志，再以宿主有Pillow的Python运行：

```bash
python3 scripts/qa/collect-zhiyu-native.py --log <检查日志> --output <新输出目录> --python <有Pillow的Python>
```

离屏和包内分析在`apps/desktop`目录运行（不要从仓库根扫描SDK、缓存及历史QA目录）：

```bash
../../scripts/dev-macos.sh flutter analyze --no-pub --fatal-infos
../../scripts/dev-macos.sh flutter test --no-pub test/ --reporter expanded
../../scripts/dev-macos.sh flutter test --no-pub tool/capture_zhiyu_foundation.dart --reporter expanded
```

离屏输出在`build/zhiyu-ui/u01/macos/offscreen`。参考服务运行`python3 scripts/qa/zhiyu-macos-reference.py --fonts build/zhiyu-ui/u01/macos/offscreen/fonts.json`，使用它打印的本机URL，在浏览器按相同内容视口取参照；完成后关闭该服务。不得把本机字体或临时服务器地址作为异机依赖。

## #62接着完成什么

1. 补齐最小查询/选中/详情/返回及操作结果合同。当前WorkspaceSource只提供外壳摘要，导航有对象身份与返回，尚不足以把T01最小准备整条勾选；按实际页面需要补齐，不提前开发全套服务。
2. 补齐共享控件状态及对应R状态的剩余对照，尤其逐项测量动画起止/位移/中断；当前记录不够证明完整S5动态合同。
3. 检查新预览中的⌘编辑、中文组合输入与焦点接缝；区分合成输入和真正系统输入。需要本人配合的部分按既有计划集中处理，未完成内容保留，不触发个人系统授权来做UI演示。
4. 复查原生窗口、菜单和正常关闭/退出的实际行为；源码及Widget输入通过不替代这条完整实机链路。
5. 按S5逐项收口后再关闭#62并开始#63，继续共用正式Widget、控制器和集中示例来源。真实服务和Windows专项仍后置。

本轮只保留当前预览构建及必要证据，不复制测试源码或生成多份App；本机旧普通预览和恢复来源不动，未知`.local/`不处理。
