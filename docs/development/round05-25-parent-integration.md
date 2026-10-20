# D3 提案工作区主集成

2026-10-17。最终候选 `b0826ac26c59800473a39c0d92b18bb8198ac382` 经独立merger合入 `1d986becb4170b9b723cfa01af54a7c9c7a8410d`。统一队列包含新增、修改、删除和整理结果；草稿可独立编辑，整批确认采用真实原子接口，终态按真实身份读取当前信息，不显示已删除旧值。实现与分步验证见[交付记录](round05-25-proposals.md)。本页记录合并检查，最终导航与联合native尚待补齐。

## 冻结画面和合并

独立首轮报告固定70张原图并指出用途颜色、回执段落、200%头像、离线提示及累计行盒偏移。最终r2再次查看70/70，五组关闭；r3只看两张current-missing图，关闭句号行首P3，保留真实ID。报告在仓库外 `C:/Project/network_config/info-manage-worktrees/25-fidelity-review-r2.md` 与 `25-fidelity-review-r3.md`。原型与前轮证据没有修改。结论只覆盖所提供静态画面，不由截图推断保存或导航成功。

实际合并仅协调 `PrototypeDialog` 和Core `part` 声明。无divider的D3确认动作保留26px默认留白；D5显式22px和simpleFlow的0px动作/14px body均保留；独立width、200%关闭叉、空标题和显式body留白也保留。共享信息编辑器与D3候选字节一致，main/library/D5弹窗、schema14/备份4及回收来源validator与原root一致。

merger对受影响四种弹窗各捕获双视口，共8PNG：D5新增失败与换版本图和原r7全图相同；D3确认与失败的纸张边界和内部像素相同，变化仅在背景右上方的真实请求ID条。主任务另外实际查看1280的四张当前图，动作完整、无截字或相互遮挡。这是共享控件合并回归，不取代独立原型评审，也不将像素差数量当通过阈值。[固定合并证据](evidence/25-proposals/parent-integration/manifest.json)包含原图、比较记录、QA源及日志SHA。

## 检查与剩余

merger运行Core proposal/update/import 11项、Storage proposal/update/import/complete-backup 15项、Desktop proposal/import/review/update/organization/library/credentials 26项，全部通过；Core、Storage、Desktop分析无issue，捕获fixture4项通过。合并diff-check通过，旧日志与manifest原样保留。主任务完整249项是此前D5接口点的结果，不冒称已在新的D3合并源码重复执行。

三个公开导航回调已在提案页保留，main尚未接线：按ID打开当前信息、普通前往信息库，以及按同一taskId打开整理许可。由D5实现者统一接到既有InformationWorkspace，普通切页保留筛选，明确外部导航才清冲突筛选并定位；完成后再跑当前源码联合Windows流程与完整检查。此前实现者native-r3仍只证明其固定源码的业务链，不代替本轮合并原生。#25/#27继续OPEN，Mac实机按用户指示延期。
