# Round05 Windows 0.4.0+8 预览交付

2026-10-18。源码291801046f7d1e6e4217a4bc001ea714689855c5；后续证据/进度文档不改变程序。主会话处理，无子Agent；服务器同步暂停，Mac/双向恢复延期。

## 交付物

- ZIP：build/windows-preview-round05-2918010/agent-info-manage-0.4.0+8-dev.291801046f7d-windows-x64.zip
- 大小52,802,814字节，约50.4MiB；Windows x64未签名开发预览，111个清单内文件。
- SHA-256：09d0515326dd4d6e5355ad2301d73c231287d43401024862380662aad687edb5
- 解压应用：同目录AgentInfoManage/app/info_desktop.exe。应用、CLI及worker需整包替换，内部worker握手升级为2；公开协议仍v1、schema16/备份格式5不变。

保留Round05已确认全部界面与功能，本次不改UI样式。修复Windows读句柄阻止后续回执发布（各阶段一次发布不覆盖），拒绝不兼容worker启动，避免混用后互等；不重试已消费的启动、不放宽Job/身份/清理检查。旧单次超时缺阶段日志，不能唯一归因于这条复现路径。

## 验证与范围

固定来源完整351项零跳过、严格分析、Release编译；中文/空格解压、SDK-free子进程PATH下11项实际CLI/hook，以及SQLCipher4.19.0/DPAPI检查通过。版本修复后的真实Windows窗口/独立AOT适配器/worker/OpenSSH三轮，每轮配置60次重复审批/短启动；包内CLI/worker另跑一轮10次及主任务/历史/重开通过。独立整个GUI进程突然结束并重开两次（一次用新包worker），7项运行/未知/清理/旧会话事实均通过。

原始失败与通过、配置和来源差异、GUI二进制清单、原包manifest及日志哈希见[排查记录](windows-timeout-investigation.md)和[evidence](evidence/windows-timeout-fix/verification.json)。保留旧一次超时、测试草案错误、UIA干扰轮和两次通知失败；不把它们计入通过。先前备份迁移/格式兼容证据仍按各自固定来源保留。

## 未完成的人工门槛

- 真实系统通知点击：Shell接受，Computer Use未提供可靠可点目标，未发出输入；两次本轮尝试均失败，#23保持开放。
- 用户实际Codex安装/信任与联合流程：没有调用模型或改现有配置；随包材料生成与独立适配器测试不等同该项。
- 干净Windows机器/用户和完整安装验收：当前Win11家庭版26300测试，SDK-free PATH不等于新系统；本包无安装器、签名或自动升级，VC++v14 x64运行库需已满足。

测试窗口/worker/SSH及任务容器退出，Computer Use会话reset；未自动启动用户应用或迁移用户资料库。#18/#21/#30保持开放以跟踪以上门槛，没有将预览包当成正式发行验收完成。
