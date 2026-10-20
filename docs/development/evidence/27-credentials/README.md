# D5 验证证据

全部为虚构资料。PNG 是实际 Flutter 离屏捕获，未重绘或编辑像素；原 HTML 参考未修改。捕获脚本：`apps/desktop/tool/capture_credentials.dart`、`capture_credentials_states.dart`。正常 1440×900 / 1280×800、DPR 1，字体加载本机 SimSun/Georgia/Consolas 与项目 NotoSansSC。

| 目录 | 内容 |
| --- | --- |
| r1 | 首次三种代表状态 × 两视口，保留已发现的行边线、toolbar、footer 差异 |
| r2 | 修正后的凭据详情、添加字符串、添加文件，两视口；供首轮独立检查 |
| r3 | 完整状态初轮，已识别简单流程多余 footer separator |
| r4 | 简单流程修正后的完整 58 图：紫1440/1280、绿/蓝/灰、空/长/125条、失败草稿/放弃确认、真实关联导航 |
| r5 | 200% toolbar 可见滚动条与实际末端/轮换/删除操作，发现关闭字形裁切 |
| r6 | 200% 最终5图，关闭控件随字号扩大；操作来自实际按钮和 owner，不填假callback |
| r7 | 独立复核定向修正后的61张原始图；manifest逐项冻结SHA-256/UTC/尺寸及源码hash，不覆盖r4/r6 |
| r8 | 仅过期未选框色值修正：紫色双视口与黑白双视口links共4图；manifest冻结，compare仅紫色links两图 |
| r9 | 实际runtime一分钟tick产生的材料清理失败提示，紫色双视口2图；共享QuietNotice延伸，无专属HTML参考 |
| compare-r1/r2/r4 | oil --compare 的自然尺寸 Flutter PNG 对原 HTML PNG 与差异定位报告 |
| logs | 实际 native picker 首轮失败/修正后通过；协议和工具栏红绿记录；最终集成检查另行追加 |

`compare-r4` 的 file/add-file/add-string 与原参考同视口直接比较；辅助 rotate/discovery/string/expired/links/server 同样比较。文件页“尚未使用”、额外版本恢复入口、真实随机 opaque ID、可见性编辑入口及信息条目数量属于实际状态/必要能力差异，不以改参考或改假数据抹平。

真实 Windows picker 证据 `logs/native-picker-pass.log`：`D5_NATIVE_VERIFIED nativePicker=true`，第一次真实取消、第二次真实选择测试文件。该 runner 物理2534×1414、DPR2、逻辑1267×707，不能作为同视口1×视觉通过证据。主 Flutter 窗口只截图观察，未查询 UIA、未抑制 SemanticsHandle 断言。Mac 尚未实测。

当前 D5 的 lifecycle 证据是 fixed-version/material/generation guard，真实使用申请的 pending/approved invalidation 留给 #28；不以没有实现的许可数量或执行记录冒充验收。#31格式5前禁止导出旧格式凭据备份，真实资料交付仍待后续集成。

独立复核后的定向修正：1280失败时body滚动、动作保留完整独立footer；过期 notice恢复clock、1px warning边线、粗标题及13/1.9自然高度；links恢复paper状态tag和未选过期框灰态；discovery恢复48ch帮助文字及摘要/公开名称粗体；仅秘密概要文件名/隐藏标记恢复1px字距。删除modal移除工程进度说明，保留失效及离线备份副本边界。`compare-r7` 只覆盖这8种受影响状态×两视口；200%删除确认属于同语法延伸，不假称有专属参考。

独立r2复核关闭其余项后，r8只调整未选过期框的浅填充和边框色，以paper混合中性色保留主题表面。紫1440原始参考和新图同一框内区域x449–458/y547–555的72像素均为#f8f7f7；参考直边#d1d0d0，控件采用同一边框色，边缘覆盖受Flutter栅格化影响。没有改变关联业务状态、标签或布局；未重复61图与全套检查。

r9通过共享公开repository故障fixture和实际runtime定时器生成；没有直接赋值失败flag。30天边界首次写失败保留材料，提示可见；下一分钟写恢复后清理并关闭提示的widget先红后绿。截图只留失败状态两视口，保留正常当前版本，没有秘密/源路径；本轮仅self-view和已有QuietNotice语法，不宣称有专属逐像素原图。`logs/maintenance-red.log`、`maintenance-green.log`和`maintenance-capture.log`分别记录红、绿和2个捕获。
