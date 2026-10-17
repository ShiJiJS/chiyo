# D3 提案证据索引

`fidelity/` 是可重新运行的最新原始 Flutter capture，`review-round2/` 是不可覆盖的固定送审批次，manifest含每张PNG和相关源码的SHA。`compare-round2/` 为十对 oil `--compare`。早期 `compare-r1*` 保留过程记录，不能当作最后验收；r1最初的弹窗截图边界与DEBUG banner问题已在r2修正。

`review-round3/` 固定70张PNG（46 Flutter、24 HTML）与源码hash，新增整理无改动/冲突/撤销及按D0来源对齐的整批失败流程面板。`compare-round3/` 为24对同尺寸比较。两个review轮互不覆盖；独立审查与主入口组合验收仍待完成。

`review-round4/` 固定独立首轮报告后的70张PNG与产品提交 `d2df00e7f77894671d44d80ce8f45b1485e22886`：用途 muted 色、回执行距、200%头像、查询失败文案、队列/字段/footer行盒及当前说明48ch宽度。`compare-round4/` 24对退出0，issues/lint为空；70图SHA复验零不符。`fidelity/geometry-*-new.json` 记录真实Flutter布局边界，辅助区分行盒与抗锯齿。定向控件21项和analyze通过，详见 `validation-round4.json`。本轮仍待独立定向复核；旧round2/3及其审查结论不覆盖。

主任务已回报 r4 独立复核70/70，原五组关闭。`review-round5/` 仅固定 current-missing 双视口两张替代图及 `c5a8ea0b058ab4b12ff720831627ff9e04196df7` 源码hash：完整保留ID，把“可到回收站检查。”独立成行，避免句号行首；宽度和其他样式不变。原r4仍保留，r5 manifest记录仅输出该状态的截图复现方式和退出0。

原参考来自外部 `round05-page-reference-prep/cases/proposal-*`，r2已复制到固定批次；`reference-aux/` 通过未改的最终HTML补D0真实状态。`capture_proposals.dart`、`capture_proposal_references.mjs`、`compare_proposals.mjs`、`freeze_proposals.mjs` 为复现入口，需在desktop工作目录运行Flutter capture。所有图片保持1440×900或1280×800自然像素，没有用压力图替代基准。

证据仅使用合成数据、临时内存服务与独立资料库。原生结果与各项边界见 `docs/development/round05-25-proposals.md`。Mac实测、主入口组合导航和静态视觉终核尚未在本索引宣称完成。
