---
status: accepted
---
# 用户保存的普通附件历史版本长期保留

2026-11-02，用户明确选择普通附件历史版本长期保留，使 Agent 可以把同一文件的前后修订组织为版本，而不用为防止原文过期被清理而拆成多条信息。接受历史原文增加存储与备份占用的代价；不再因为它退出当前版本就按 30 天规则自动清理。

本决定调整 [ADR0011](0011-ordinary-attachments-in-encrypted-database.md) 后续实施中的普通附件版本保留规则，范围限于用户仍保管的普通附件历史版本。受管交付临时副本、用户主动删除后的回收处理、托管凭据的材料保留分别讨论，不由此推定改为永久保存。

实现归 GitHub #80。Mac 分支已接入仍保管的附件系列长期保留及相应加密备份格式，开发检查与未完成部分见[当前进度](https://github.com/ShiJiJS/chiyo/blob/46ff2a9ba5bda130c88f9aac9beef72eb586e781/docs/development/ordinary-file-ingestion.md)；尚未替换本机预览或完成最终独立新会话验收。
