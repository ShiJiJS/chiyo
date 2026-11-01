# 知予 Mac M06：普通附件真实接入

对应 [#75](https://github.com/ShiJiJS/agent-info-manage/issues/75)，后续AI文件流程对应
[#76](https://github.com/ShiJiJS/agent-info-manage/issues/76)，均归属#69。不新增申请入口、
演示数据或模式，不改变#73当前换包前置，Windows适配后置。

## 2026-11-01：Mac原生PDF分页预览

OwnerWorkspaceFiles对PDF复用同一Owner校验原文读取，传入本机字节及零起始页码，
NativeOwnerPdfPreview通过独立MethodChannel调用生产OwnerPdfPreview。
CoreGraphics从内存解析、绘制指定cropBox/旋转页面，返回单页PNG及准确页数/尺寸。
不使用外部阅读器、PDF动作执行或临时原文文件，不新增系统权限。单请求10MiB、
最多4096页、单边1600像素；原生串行后台队列且只接纳一个进行中的请求，避免
大PDF阻塞窗口事件或堆积原文请求。Flutter端再次核对响应页码/页数、像素范围、PNG
签名/IHDR与元数据；原生错误只映射准确业务状态，不向界面泄漏路径/诊断。

非法页码、损坏PDF、密码锁定、超出页数/页面边界及繁忙分别可辨；不添加密码输入、
不猜密码、不把无法预览当作原文丢失。正常文字/图片仍只接受page0，历史附件引用和
库代次边界沿用原读取流程。已有LibraryFilePreviewView呈现图片并使用原翻页控件。

原生RenderChecks生成真实双页含字体PDF和URL注释，检查实际红/蓝页面像素与页码、
旋转/裁切几何、1600边界、超4096页、锁定、损坏/空/超10MiB及越界拒绝。
首次像素检查发现CoreGraphics的getDrawingTransform只缩小不放大，小页面在2x位图
中居中留白；已依据本机SDK头文件分离栅格密度缩放，原像素检查通过，未放宽阈值。
四张实际PNG已目视，含字体的两页也单独复看；不是正式Flutter页面截图或S5验收。
坏PDF拒绝场景有CoreGraphics诊断，日志保留，不称无警告执行。

Flutter定向19项、包含Owner/Host/附件阅读的相关48项通过，静态分析通过；包括真实
SQLCipher原文字节/页码到通道（mock渲染）、响应身份/大小/PNG不符和原生错误映射。
Xcode项目结构和MainFlutterWindow语法通过。原生像素为实际CoreGraphics运行；通道
mock不冒充同一App端到端运行。[证据](evidence/zhiyu-round09/m06-pdf.json)。

同源完整ARM64 Release `87a920989d76ea89399e1f2959a80d0b6fc54a9b` 已构建，20阶段
通过，包内确认PDF通道及原生渲染类。短方法名renderPage可能以Swift小字符串内联，
初始字符串检查未命中；实际通道调用另由下述原生App检查证明，不以短字面量作门槛。
ZIP `agent-info-manage-0.4.1+13-mac-dev.87a920989d76-macos-arm64.zip` 共131577036字节，
SHA256 `2595f71ed512c4ae2482645b19a95fa1a75890c364aa61a7717442b93cfe9900`。
载荷位于 `build/macos-adaptation/m06-release-87a92098/AgentInfoManage`，ad-hoc未公证，
未替换固定安装或预览。Xcode仍有exit-code-0诊断和弃用警告，完整命令和产物检查通过。

`scripts/qa/check-owner-pdf-native.py` 在独立源码副本/随机沙箱身份中构建实际Cocoa/
Flutter Debug App（d31cd7a4，生产lib/macos/packages与87a92098逐字节相同），
6个具名检查通过：真实SQLCipher导入合成双页PDF后删除源文件；实际Owner→通道→
Swift返回第1页及准确尺寸；生产阅读器下一页控件选择第2页；第2页不同且越界明确
拒绝；上一页控件回第1页；库/service/source同进程重开仍返回相同原生渲染字节。
签名及真实App Sandbox启用，未使用通道mock、原生面板或computer use。
该证据是同源Debug原生通道及控件，不能称已运行Release二进制/个人原地升级或
独立App进程重开；完整S5/本人输入和文件选择仍未验。

测试合成库由App删净，测试App/dSYM/派生构建树/独立源码副本清理且进程已退出。
旧M05 e3117d4a重复展开载荷移除，仅留ZIP和日志，当前只保留最新M06展开包；
M04原交付候选及旧安装保护保持。原预览kernel摘要仍为30279179…1ce125。
#75不关闭，导入/替换/版本恢复/主人另存继续实现；#76尚未接入。本轮只用合成原文，
不使用个人资料、Keychain、全局hooks或Windows CI。

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
