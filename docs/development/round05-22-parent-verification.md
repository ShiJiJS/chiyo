# #22 主集成复验

2026-10-17。设计实现 `4c2a808`，集成合并 `2f6ffb4`，PR #32。没有生产凭据功能或真实库迁移。

- 主 Agent 在集成 checkout 连续运行 `node docs/design/prototypes/round-05/check-flows.cjs` 三次，每次15项通过；`node --check .../lifecycle.js` 通过。
- 运行 `assemble-lifecycle.cjs` 后 `git diff --exit-code -- .../index.html` 通过，证明拆分原型可重现当前入口；`git diff --check` 通过。
- 已读取 F01–F14 覆盖表、协议v1、JSON schema和实现方的实际浏览器动作/十状态报告。设计状态检查只证明原型状态模型，不证明生产服务、CLI或持久化。
- 主 Agent 实际查看最终 proposal-edit、backup-enable、execution-start_failed 三张1440×900截图：固定头尾与内滚动、无文件前无预览、失败首屏和列表明确未启动及重新申请要求。
- 新上下文独立评审未读源码、不打分，发现4项：提前备份预览、失败恢复步骤与列表反馈不足、长表单底栏遮挡、制作验收控件泄漏。定向复核实际检查了1440×900及1280×720页面与键盘操作，第1/3/4及第2详情说明已解决；最后列表次级失败标签由主 Agent 在最终截图复核通过。

完整编辑、补选、恢复、组合许可、凭据轮换、备份异常、执行/清理四态及大数据的设计入口与后续实现责任见 `docs/design/round05-flow-coverage.md`。新增命令以协议/schema为后续实施输入，现有CLI不因此自动获得该能力。

本票的设计验收完成，#23可开始。Mac实际验收不适用于本设计票，按用户指令推迟；后续生产票仍需各自的核心、CLI、UI与Windows证据。
