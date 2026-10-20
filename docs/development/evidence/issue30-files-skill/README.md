# #30 普通文件随包材料证据

对应源码 `5d9e50efd40265ee3a3fd0ce337a8231722e598d`，完整范围、失败轮与未完成门槛见[检查点说明](../../issue30-information-files-skill.md)。

`verification.json` 登记 66 份原始字节文件、17 份源码/依赖锁摘要和 4 个本地 AOT 输入摘要。`adapter-08` 是最终定向与完整源码验证；`adapter-01` 至 `06` 是失败轮，`07` 是前一版测试断言的定向绿轮，`regression-01` 与最终完整组重叠。不得累加通过数。

`raw/` 的脚本是最终重跑版本快照，不是各早期轮脚本或中间测试草稿。Git 源码摘要针对提交内容，workingTreeSha256 针对实际工作区字节，两者仅允许 Git 行尾转换。AOT 可执行文件保留在忽略的 build QA 目录，不随证据提交。

没有真实 Codex 安装/信任、真实模型子 Agent 或最终 ZIP 验收。新用例的输入驱动为假驱动、仓储为 Memory；实际 Windows 副本和进程 Job 的验证边界不能扩大为真实浏览器填充。
