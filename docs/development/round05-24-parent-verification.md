# D2 信息库主集成复验

2026-10-17。实现 `8d6667f`，同步及最终修正 `2ee7c4f`，由独立 merger 无冲突合入 `df63de6`。合并树与冻结候选一致；本记录不将截图检查当成业务验收，也不将本页结论推广到其他页面。

## 合入与公开接口

信息库继续采用目录、列表、详情三栏。owner 原子编辑、稳定目录身份、有界结果分页、共享纯编辑草稿和恢复来源映射的接口见[实现说明](round05-24-library.md)。旧授权不能读取显式恢复所得的新字段身份；普通值修正保持字段身份，旧授权仍读取当前值。没有通过迁移猜测或改写既有字段身份。

merger 在集成分支复验 Core library/recycle/revisions 21 项、Storage library/complete_backup 12 项、Desktop inbox/library/library_workspace/organization_widget/recycle/revisions 16 项及 CLI delete 1 项，均通过；desktop analyze 与 diff-check 通过。日志位于工作目录忽略的 `.scratch/24-merge-*.log`。以下主任务独立检查另行记录，不能用 merger 结果替代。

## 实际画面

主任务直接运行真实字体的 `capture_library.dart`，复验五个相关控件文件共 9 项，并查看同尺寸原图及 oil `--compare`。独立评审的 r1–r4 固定双方原图及 SHA，按既定 HTML 定向闭合；未修改参照原型。

修正包括编辑器段落/框高、目录实体行距、工具栏左右锚点、弹窗操作和恢复列表宽度。末轮另外修复 1280 目录底行裁半字，以及结构化中文内容落入测试缺字字体的黑块：Consolas 仍为代码主字体，中文优先回退到已有 ProductSans/AppSans。原中文长值保留不变，主任务和独立评审均查看修正后的实际图。

[固定 r4 证据](evidence/24-library/README.md)包含 35 张 PNG 与 SHA，常规 1440×900、1280×800，以及空/失败/恢复、四主题、长内容和 200% 状态。主任务还检查了真正详情滚动末端的 `purple-long-bottom.png`，关联区、提示和固定操作区完整可读。压力图没有对应的原型压力截图，不宣称其逐像素一致。

独立报告原件位于仓库外 `C:/Project/network_config/info-manage-worktrees/24-fidelity-review.md`，限定所提供静态视觉；实际保存/恢复和原生链路按相应测试记录。真实排序、未关联凭据的自然高度，以及 Chromium 与 Flutter 文字栅格差异单列，不能用于豁免实体布局偏差。#27 接入真实凭据关联后仍需核对该区域。

## 平台范围

子任务最新隔离 Windows native 日志已随源码归档到 `evidence/24-library/native-r4.txt`，使用合成 SQLCipher/DPAPI 资料、loopback 随机端口及独立 JSON-lines CLI，未访问用户实际信息库。

Mac 实测依用户指示延期。#23 的真实系统通知点击仍未验成功，不能据本票测试关闭该缺口。凭据关联由 #27、秘密转换和完整凭据备份由 #31 接续；当前不是正式真实凭据迁移交付。

## 主任务合入后结果

在 `df63de6` 的生产源码上独立运行 `scripts/check.ps1 -FlutterBin C:/Users/Todoki/.local/share/flutter/bin -Offline`，退出 0：CLI18、Core93、Storage42、Desktop64，共217项及全部 analyze 通过。存储负向错误密钥用例有预期 SQLCipher HMAC 拒绝诊断，不是失败断言。没有因输出出现该诊断而删除错误密钥验证。

随后独立运行 `scripts/test-windows-library.ps1`，退出0；Windows 构建28.1秒，测试25秒，实际输出 `D2_NATIVE_VERIFIED`。真实 Flutter 控件与独立 CLI 完成模板新建、编辑分类、删除、回收恢复、新身份重新批准、删除前历史修正，并以 SQLCipher/DPAPI 重开确认来源和当前内容。原生内容视口为 physical2534×1414、DPR2、logical1267×707；视觉精准对照使用前述离屏 DPR1 双视口，两者没有混称。

原始主日志分别为 `.scratch/24-parent-full-check.log`、`.scratch/24-parent-windows-native.log`；命令、计数及日志 SHA 另归档在[验证清单](evidence/24-library/parent-verification.json)。没有运行通知探针或修改 OS 设置。主任务确认 #24 在本轮 Windows 范围完成，#25/#27 由此进入实施前沿；其余软件及服务器同步仍未完成。
