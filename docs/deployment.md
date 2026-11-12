# 安装与部署

[项目首页](../README.md) · [English](deployment.en.md) · [文档导航](README.md) · [使用指南](usage.md)

App 可以独立使用；只有需要 NAS 持续接收 AI 申请或同步资料时，才部署服务器。以下服务器步骤适用于一次新的 Docker 部署；已有服务的备份、升级和回退见[维护说明](../apps/server/OPERATIONS.md)。

## 安装桌面 App

从 [Releases](https://github.com/ShiJiJS/chiyo/releases) 选择实际提供的平台附件，核对同目录的 SHA-256。源码与下载包可能不同步：当前 Windows 适配和最新功能已合入 `main`，发布页仍为较早的 Mac 开发包。需要最新版本时按[开发指南](development/README.md)构建。

| 平台 | 安装方式 |
| --- | --- |
| macOS 14+、Apple Silicon | 打开 DMG，把 `chiyo.app` 拖到「应用程序」，启动知予 |
| Windows x64 | 完整解压对应 ZIP，运行 `app/info_desktop.exe`，保留相邻 DLL、`data`、`cli` 和 `tools`；需要 Microsoft Visual C++ v14 x64 Runtime |

Mac 开发包使用本机签名，尚未公证；更新后可能需要重新允许 App 读取钥匙串，系统密码由你本人输入。Windows 的密钥和私有连接由当前用户的 DPAPI 与文件权限保护，不复制另一台电脑的加密配置。

首次打开可以选择本地模式，直接保存资料并接收本机 AI 申请，不需要 Docker。AI 接入使用开发包附带的 CLI 和同版本说明，见 [AI 接入](../integrations/codex/README.md)。

## 部署可选的 Docker 服务器

服务器运行在自己的 NAS 或 Linux 主机，客户端通过局域网 HTTPS 连接。需要 Docker、Docker Compose 和 OpenSSL。下面使用 POSIX shell；在仓库根目录执行命令，私有数据放在源码目录之外。

### 1. 准备私有目录

把示例监听地址换成服务器的实际局域网地址。运行用户必须能读写这份新目录；NAS 上应使用目标数据目录所属的 UID/GID。

```sh
export CHIYO_STORAGE_DIRECTORY="$HOME/chiyo-data"
export CHIYO_BIND_ADDRESS="192.168.1.20"
export CHIYO_UID="$(id -u)"
export CHIYO_GID="$(id -g)"
export CHIYO_SOURCE_COMMIT="$(git rev-parse HEAD)"

umask 077
mkdir -p "$CHIYO_STORAGE_DIRECTORY/data" "$CHIYO_STORAGE_DIRECTORY/config" \
  "$CHIYO_STORAGE_DIRECTORY/tls" "$CHIYO_STORAGE_DIRECTORY/ca"
cp deploy/server.example.json "$CHIYO_STORAGE_DIRECTORY/config/server.json"
cp deploy/tls.example.cnf "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf"
```

编辑 `ca/tls.cnf` 中的 `[addresses]`：证书必须包含 App 真正连接的 IP 或域名。示例地址不能直接用于另一台 NAS。已有合适的证书时，也可以把服务端证书和私钥分别放到 `tls/server.pem`、`tls/server.key`，跳过下一步。

### 2. 为局域网生成证书

以下建立私有 CA 和服务端证书。CA 私钥放在 `ca/`，不会挂载进运行中的服务容器。

```sh
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -config "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf" \
  -keyout "$CHIYO_STORAGE_DIRECTORY/ca/ca.key" \
  -out "$CHIYO_STORAGE_DIRECTORY/ca/ca.pem"

openssl req -new -newkey rsa:3072 -nodes \
  -subj "/CN=chiyo.local" \
  -keyout "$CHIYO_STORAGE_DIRECTORY/tls/server.key" \
  -out "$CHIYO_STORAGE_DIRECTORY/ca/server.csr"

openssl x509 -req -sha256 -days 825 \
  -in "$CHIYO_STORAGE_DIRECTORY/ca/server.csr" \
  -CA "$CHIYO_STORAGE_DIRECTORY/ca/ca.pem" \
  -CAkey "$CHIYO_STORAGE_DIRECTORY/ca/ca.key" -CAcreateserial \
  -extfile "$CHIYO_STORAGE_DIRECTORY/ca/tls.cnf" -extensions server \
  -out "$CHIYO_STORAGE_DIRECTORY/tls/server.pem"
```

App 只需要 CA 的公开证书 `ca/ca.pem`。不要把 CA 私钥或服务器私钥交给客户端，也不需要修改系统全局信任。

### 3. 构建并初始化

```sh
docker compose -f deploy/compose.yaml build

docker run --rm --user "$CHIYO_UID:$CHIYO_GID" \
  --mount "type=bind,source=$CHIYO_STORAGE_DIRECTORY,target=/setup" \
  chiyo-server:local init-secrets /setup/secrets

docker compose -f deploy/compose.yaml up -d
```

初始化创建数据库密钥、用户接入 Token 和服务器身份。`secrets` 必须尚不存在，重复初始化会被拒绝；升级或重启不再运行这一步。Compose 只给 `data` 写权限，`config`、`secrets` 和 `tls` 只读挂载。

检查运行状态和日志：

```sh
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail 50 chiyo
```

默认容器端口是 `47126`；`CHIYO_PORT` 可调整宿主机端口。监听地址默认仅为本机回环，局域网使用需像示例一样设置 `CHIYO_BIND_ADDRESS`。重新维护容器时使用相同环境变量和私有目录，也可将这些值保存在自己保管的环境配置中；不要提交真实部署配置或密钥。

`server.json` 的 `readCacheMiB` 是数据库读缓存预算，默认 128 MiB，可设为 32～512，重启后生效；不是整个进程的内存上限，也不会把全部附件预载到内存。

## 在 App 连接服务器

1. 打开「设置 → 存储与同步」，选择「服务器同步」。
2. 填写 `https://实际局域网地址:47126`，以及用户接入 Token。
3. 使用上述私有 CA 时，把 `ca/ca.pem` 的完整内容填入服务器证书处。
4. 点击「连接并开启同步」，等首次资料传输完成。已有不同资料的两端不会被自动覆盖；遇到提示时先备份，再选择空目标。

Token 可在自己的可信终端转换后填入 App：

```sh
openssl base64 -A -in "$CHIYO_STORAGE_DIRECTORY/secrets/owner.token" \
  | tr '/+' '_-' | tr -d '='
```

这是 **App 的管理 Token**，不要发给 AI 或写入普通日志。App 会自动准备受限的 Agent 连接，不用把管理 Token 配到 CLI。服务器持有解密能力，应保留在你信任的设备上。

服务器同步模式下，NAS 接收访问申请和提案，App 从 NAS 读取并审批；本地模式由本机服务处理。切换不搬运旧申请，已有聊天仍绑定原服务。详细使用方式见[使用指南](usage.md)。

## 备份、升级与迁移

- 在 App 导出完整加密备份，将恢复密钥分开保管；先在独立空目标验证恢复。
- 升级前正常停止 App 和服务，保留原数据、`secrets`、连接配置及证书。不要重新初始化密钥，也不要把备份直接覆盖进正在运行的数据库。
- 在 NAS 更换硬盘或目录时，迁移整套持久目录并核对文件权限；新容器继续使用原密钥、服务器身份和 Token。
- 完整停机备份、升级顺序、兼容格式和失败回退步骤见[服务器维护说明](../apps/server/OPERATIONS.md)。

停止服务器：

```sh
docker compose -f deploy/compose.yaml stop -t 30
```

这里只停止进程，不删除挂载目录中的资料。确认正常退出后再复制数据或调整挂载位置。
