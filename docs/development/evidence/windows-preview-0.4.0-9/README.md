# 0.4.0+9 开发预览证据

固定源码 `50e2c091824bc97436bd93607b3e22ed63f7aafb`。实际范围、包路径、归档校验与待验项见[交付记录](../../windows-preview-0.4.0-9.md)。

`verification.json`保存7份原始资料及10份Git源码/依赖锁摘要；manifest登记的113项载荷和53,288,619字节ZIP已独立复核。ZIP和二进制不入Git。

全量668/19与解包16/0有重叠，不累加。最初包装器进程未启动，`initial-wrapper-result.json`中exitCode为null；实际成功轮在`package.txt`和`result.json`。限制PATH、合成DPAPI/SQLCipher及受控适配器不是干净Windows、实际GUI或真实Codex验收，`acceptanceComplete`保持false。
