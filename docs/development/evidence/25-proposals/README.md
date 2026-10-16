# D3 提案证据索引

`fidelity/` 是可重新运行的最新原始 Flutter capture，`review-round2/` 是不可覆盖的固定送审批次，manifest含每张PNG和相关源码的SHA。`compare-round2/` 为十对 oil `--compare`。早期 `compare-r1*` 保留过程记录，不能当作最后验收；r1最初的弹窗截图边界与DEBUG banner问题已在r2修正。

`review-round3/` 固定70张PNG（46 Flutter、24 HTML）与源码hash，新增整理无改动/冲突/撤销及按D0来源对齐的整批失败流程面板。`compare-round3/` 为24对同尺寸比较。两个review轮互不覆盖；独立审查与主入口组合验收仍待完成。

原参考来自外部 `round05-page-reference-prep/cases/proposal-*`，r2已复制到固定批次；`reference-aux/` 通过未改的最终HTML补D0真实状态。`capture_proposals.dart`、`capture_proposal_references.mjs`、`compare_proposals.mjs`、`freeze_proposals.mjs` 为复现入口，需在desktop工作目录运行Flutter capture。所有图片保持1440×900或1280×800自然像素，没有用压力图替代基准。

证据仅使用合成数据、临时内存服务与独立资料库。原生结果与各项边界见 `docs/development/round05-25-proposals.md`。Mac实测、主入口组合导航和静态视觉终核尚未在本索引宣称完成。
