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
| compare-r1/r2/r4 | oil --compare 的自然尺寸 Flutter PNG 对原 HTML PNG 与差异定位报告 |
| logs | 实际 native picker 首轮失败/修正后通过；协议和工具栏红绿记录；最终集成检查另行追加 |

`compare-r4` 的 file/add-file/add-string 与原参考同视口直接比较；辅助 rotate/discovery/string/expired/links/server 同样比较。文件页“尚未使用”、额外版本恢复入口、真实随机 opaque ID、可见性编辑入口及信息条目数量属于实际状态/必要能力差异，不以改参考或改假数据抹平。

真实 Windows picker 证据 `logs/native-picker-pass.log`：`D5_NATIVE_VERIFIED nativePicker=true`，第一次真实取消、第二次真实选择测试文件。该 runner 物理2534×1414、DPR2、逻辑1267×707，不能作为同视口1×视觉通过证据。主 Flutter 窗口只截图观察，未查询 UIA、未抑制 SemanticsHandle 断言。Mac 尚未实测。

当前 D5 的 lifecycle 证据是 fixed-version/material/generation guard，真实使用申请的 pending/approved invalidation 留给 #28；不以没有实现的许可数量或执行记录冒充验收。#31格式5前禁止导出旧格式凭据备份，真实资料交付仍待后续集成。
