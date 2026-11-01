# 知予 Mac M06：普通附件真实接入

对应 [#75](https://github.com/ShiJiJS/agent-info-manage/issues/75)，后续AI文件流程对应
[#76](https://github.com/ShiJiJS/agent-info-manage/issues/76)，均归属#69。不新增申请入口、
演示数据或模式，不改变#73当前换包前置，Windows适配后置。

## 2026-11-01：Owner校验读取与真实版本/文字/图片预览

新增Owner-only `readInformationAttachment`，在现有串行队列和原文固定事务下读取
准确附件版本。先执行既有保留期清理；每块不超过1MiB、总量不超过版本长度及既有
10MiB单文件上限，校验完整长度与SHA256；源读取事务成功结束及库代次仍有效后才
返回不可变原文。失败不返回部分内容，不生成原文临时文件，也不建立Agent交付许可。

`OwnerWorkspaceFiles`接入正式OwnerWorkspaceSource：页面字段key经当前资料codec
解析为准确字段ID，再取实际file字段引用；不能直接用页面提供的附件ID/路径读取。
版本列表来自真实存储，按版本倒序，当前版本与资料修订分别呈现；已清理原文保留
元数据并禁用“恢复此版本”。文字严格UTF-8解码，以普通文本呈现，不执行HTML。
PNG/JPEG/WebP用实际Flutter解码器读取第一帧并转PNG，单边16384及总16Mi像素限制
在申请解码帧前核查，所有图像/codec/buffer均释放。更大或其他格式如实显示不支持预览。

4项真实SQLCipher场景验证：源文件删除后库重开仍读回原文/当前与旧版本；伪造字段、
非法页码和不存在版本拒绝；PDF仍明确不支持而原文保持、无效UTF-8不伪造成功；图片
真实解码为2×3 PNG；31天后旧原文按原保留规则清理且metadata仍在、当前版本仍可读。
此处“重开”为同一Flutter测试进程重建库/service/source，不冒充独立安装App验收。

核心全套357通过/6条件跳过；Owner及附件阅读相关33项桌面回归通过，两侧静态分析
通过。新原文读取的5项故障/只读检查覆盖长度/摘要不符、IO与源事务结束失败，不把
已读到的bytes提前交给调用方。最初静态检查发现未使用导入与花括号问题，修正后通过。
[结构化证据](evidence/zhiyu-round09/m06-owner-read.json)。

剩余：PDF真实分页、原生选择不透明资源、导入/替换/恢复保留版本的持久事务及核对、
主人另存、完整控件与同源沙箱面板；#76真实文件申请/审批/交付尚未接入。当前来源仍
明确拒绝这些未实现动作。本轮没有重建/安装App，已有e3117d4a M05包不含本段修改。
没有个人资料、Keychain、computer use、全局hooks、Windows CI或新App/dSYM。
