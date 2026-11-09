# Windows：让 AI 领取附件并释放本机副本

父任务：[#104](https://github.com/ShiJiJS/chiyo/issues/104)。用户确认的方案号：6。直接前置：[#110](https://github.com/ShiJiJS/chiyo/issues/110)。

## 做完后能做什么

AI 获批后把指定版本的 NAS 附件领取到 Windows 本机，取得可用路径，使用后释放并清理副本。

## 做哪些改动

- 接通 DeviceInformationFiles、Windows worker、守护进程和私有日志，复用已有 Windows 文件驱动、进程身份和文件锁。
- 核对路径、重开、占用、异常退出及清理结果，保留原交付和 cleanup capability 规则。

## 完成条件

- [x] 实际 AOT CLI/worker 在 App 关闭时仍可领取获批版本，字节一致；未批准、撤销、到期或结束后拒绝新领取。
- [x] 同操作重试保持原版本和交付，两个 CLI 并发或丢失响应不重复下载/启动守护。
- [x] 释放、进程异常和服务重启后能核对原交付，只清理登记的受管副本，保留文件占用和未知结果。
- [x] 返回真实 Windows 本机路径供同机进程使用；响应和日志不包含清理私密证明，不使用服务器路径冒充本机路径。

## 从哪里接续

- `packages/info_cli/lib/device_information_files.dart`
- `packages/info_cli/lib/information_file_client.dart`
- `packages/info_cli/lib/runtime_worker.dart`
- `packages/info_core/lib/information_delivery_driver.dart`

## 本轮约定

直接对接现有 NAS，沿用现有服务端与产品规则，不要求 WSL 或另建服务。验证写入使用有明确标识的合成资料，现有资料和旧 Windows 库保持独立。持续目标启动后按依赖接续，相关检查、提交和实际结果随票记录。computer-use 与正式安装等用户操作集中到最后；本票不扩入密码自动填充、SSH 密码登录或 #105 跨电脑审批。

<!-- windows-online-nine:W06 -->

## 完成结果

实现与证据 `fe37707`：[w112.md](https://github.com/ShiJiJS/chiyo/blob/fe37707/docs/development/evidence/windows-online/w112.md)。Windows 日志枚举和已确认清理的队列竞态已修正；7 项定向检查（包含真实 AOT 看护进程）及另一个实际 AOT 旧协议组合检查、分析通过。现有 NAS/真实 AOT 在 App 关闭时完成并发领取、原文核对、丢失回复、异常退出、重启原交付、撤销、到期、占用与结束后清理/拒绝。只使用本轮 Windows 附件说明和全新隔离验证聊天，不恢复本聊天丢失的 association。

实际两秒 SessionEnd 回调未确认，保留原事实后，在回调外通过原 end-only 索引以 20 秒上限恢复成功；未放宽 hook 预算，也未把恢复当成两秒内成功。完整包/真实宿主连续事件仍归 #116。正式安装与全局接入未操作。

