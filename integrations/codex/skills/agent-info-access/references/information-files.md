# 普通附件：申请、领取和释放

资料字段为 `kind:file`，且任务需要阅读或上传简历、文档等原件时读本页。密码、Token、私钥等认证材料走[凭据使用](credential-use.md)，不能通过附件申请领取。

## 申请与领取

从 `catalog list` 确认真实的资料 ID 和 file 字段 ID。公开目录不包含原文件名、路径或原文。使用本聊天的私有配置；普通终端也可用，不需要切换为 Codex 聊天。

```bash
chiyo access request --item ITEM_ID --field FILE_FIELD_ID --purpose "阅读简历并填写招聘网站" --json
chiyo requests show REQUEST_ID --json
chiyo files fetch --request REQUEST_ID --item ITEM_ID --field FILE_FIELD_ID --operation resume-copy-01 --json
```

申请可以通过 `--input` 同时包含多个附件和普通字段，格式见 `access request --help`。批准后只领取最终获准的字段；未获准、到期、撤销或聊天结束时停止。等待命令超时不取消申请，也不延长批准。

`files fetch` 的统一结果在 `data.delivery`：

- `state:ready` 且有 `path`：本机副本已准备好。保留返回的 deliveryId、operationId、版本和实际路径。
- `preparing`：原操作仍在准备，用 `files status` 有限等待。
- `released`、`expired`、`failed`、`unknown` 或 `cleanup_pending`：查看原结果，不把它当作可用文件。

`fileName` 是原文件名，受管路径可能使用 `attachment.txt` 等安全文件名。直接使用返回路径，不猜目录、改名或移动受管文件。文件就绪不代表工具已读过，也不代表上传完成。

## 使用与释放

把 `data.delivery.path` 交给同机文件阅读工具，或正常浏览器的上传／文件选择接口。普通附件可按任务阅读原文；上传目的地仍以用户任务为准。只有浏览器实际提交并确认后才能报告上传成功，文件选择成功本身不够。

远程或无头工具不能访问本机文件时，说明该工具的传输限制；本功能不提供远程上传桥或 Base64 原文输出。连接服务器时，副本也在 Agent 所在设备生成，NAS 路径不是本机路径。

工具用完并关闭输入文件后释放副本；任务取消时也处理：

```bash
chiyo files release --delivery DELIVERY_ID --json
```

释放只处理软件生成的受管副本，不删除用户自行另存的文件。App 关闭后，远程副本仍由本机看护进程检查到期、撤销与聊天结束；清理失败时保留登记并报告待清理。

## 查询与重试

```bash
chiyo files status --operation resume-copy-01 --json
chiyo files status --delivery DELIVERY_ID --json
chiyo operations show resume-copy-01 --json
chiyo operations retry resume-copy-01 --json
```

状态查询和 `operations list/show` 只返回事实，不返回路径或原文。回复丢失时，先用原 operationId 查询。恢复使用原编号和原参数；`operations retry` 或同一 `files fetch` 可取回仍有效的原副本，不会创建第二份或改取新版。修改原编号的内容会冲突。

`unknown`、网络超时后的 `not_found` 不证明第一次领取从未到达，不换编号掩盖未知结果。已释放或过期的旧操作不再次交付；确有新的业务用途且原许可仍有效时，才建立新操作。一次新领取使用字段当时的附件版本，不改变已有副本。新增字段仍需申请。

普通服务器重启保留原有效申请和期限；备份恢复的只读历史不恢复聊天或副本使用能力。许可撤销不能追回已经读过、另存或上传的内容。

## 录入与错误

用户提供文件要求保存或修订，走[来源整理与文件提案](information-file-intake.md)和动态模板，不把源文件先当作已有附件申请领取。预检与提案不表示入库或获准阅读。

能力不支持时报告需要更新当前软件；不要把 file 字段改成普通文本读取。权限、完整性、容量或清理出错时保留原编号，核对原结果；不删除登记或改范围强行重领。
