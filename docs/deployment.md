# 安装与部署

[项目首页](../README.md) · [English](deployment.en.md) · [文档导航](README.md) · [使用指南](usage.md)

App 可以独立使用；只有需要 NAS 持续接收 AI 申请或同步资料时，才部署服务器。以下服务器步骤适用于一次新的 Docker 部署；已有服务的备份、升级和回退见[维护说明](../apps/server/OPERATIONS.md)。

## 安装桌面 App

从 [Releases](https://github.com/ShiJiJS/chiyo/releases) 选择对应平台的附件，核对同目录的 SHA-256。v0.5.0 提供 Mac ARM64、Windows x64 及 Linux amd64 Docker 服务端，均记录源码提交。其他架构按[开发指南](development/README.md)构建。

| 平台 | 安装方式 |
| --- | --- |
| macOS 14+、Apple Silicon | 打开 DMG，把 `chiyo.app` 拖到「应用程序」，启动知予 |
| Windows x64 | 完整解压对应 ZIP，运行 `app/info_desktop.exe`，保留相邻 DLL、`data`、`cli` 和 `tools`；需要 Microsoft Visual C++ v14 x64 Runtime |

Mac 开发包使用本机签名，尚未公证；更新后可能需要重新允许 App 读取钥匙串，系统密码由你本人输入。Windows 的密钥和私有连接由当前用户的 DPAPI 与文件权限保护，不复制另一台电脑的加密配置。

首次打开可以选择本地模式，直接保存资料并接收本机 AI 申请，不需要 Docker。AI 接入使用开发包附带的 CLI 和同版本说明，见 [AI 接入](../integrations/codex/README.md)。

## 部署可选的 Docker 服务器

服务器运行在自己的 NAS 或 Linux 主机，客户端通过可信局域网 HTTPS 连接。需要 Docker 和 Docker Compose；镜像内含生成证书所需的 OpenSSL。下面用于**全新部署**，在仓库根目录执行；已有部署保留原配置和挂载，只更新镜像，不能用新示例覆盖旧目录。

### 1. 准备私有目录

把监听地址换成服务器的实际局域网地址。运行用户必须能读写这份新目录；NAS 上使用目标数据目录所属的 UID/GID。

```sh
export CHIYO_STORAGE_DIRECTORY="$HOME/chiyo-data"
export CHIYO_BIND_ADDRESS="192.168.1.20"
export CHIYO_UID="$(id -u)"
export CHIYO_GID="$(id -g)"
export CHIYO_SOURCE_COMMIT="$(git rev-parse HEAD)"

umask 077
mkdir -p "$CHIYO_STORAGE_DIRECTORY/data" "$CHIYO_STORAGE_DIRECTORY/config"
cp deploy/server.example.json "$CHIYO_STORAGE_DIRECTORY/config/server.json"
```

### 2. 构建并启动

```sh
docker compose -f deploy/compose.yaml build
docker compose -f deploy/compose.yaml up -d
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail 50 chiyo
```

新配置的 `autoInitialize: true` 仅在空安装中生成数据库密钥、服务器身份及 HTTPS 证书，存于持久化的 `data/server-identity/`。重启和升级沿用原文件；已有数据库缺少密钥或证书时拒绝启动，不重新生成替代品。无需手动生成、复制证书或运行 `init-secrets`。

默认容器端口是 `47126`；`CHIYO_PORT` 可调整宿主机端口。监听地址默认仅为本机回环，局域网使用需设置 `CHIYO_BIND_ADDRESS`。维护容器时使用相同环境变量和私有目录，不提交真实配置或密钥。

`server.json` 的 `readCacheMiB` 是数据库读缓存预算，默认 128 MiB，可设为 32～512，重启后生效；不是整个进程的内存上限，也不会把全部附件预载到内存。

## 在 App 连接服务器

1. 首次打开选择「服务器同步」；已经使用 App 时，在「设置 → 存储与同步」切换。
2. 填写服务器的 IP 或域名及端口，不需要填写 `https://`。
3. App 自动取得并记住服务器证书。尚未初始化时设置一次「知予连接密码」；已初始化时输入原密码。它与 NAS 系统登录密码无关。
4. 等首次资料传输完成。已有不同资料的两端不会被自动覆盖；先备份并选择空目标。以后重开会复用有效连接，无需重输密码。

第一次连接应在可信局域网进行，核对自己部署的地址。已有连接的证书或服务器身份变化时 App 会拒绝连接并保留旧设置，不会自动接受新的身份。密码仅保存校验值，App 保存私有连接 Token，不保存密码原文；证书私钥始终留在服务器。服务器能解密资料，应部署在你信任的设备上。

修改连接密码使用「设置 → 存储与同步」中的密码管理。其他电脑原来通过该密码登录的连接会失效，需用新密码重新登录；当前电脑会自动更新连接。AI 使用独立受限身份，仍需申请和审批，不获得 App 的管理 Token。

已有旧版服务先更新镜像，保持原 `server.json`、数据、密钥和 TLS 挂载不变。更新后原 App 连接仍可使用；在原已连接电脑的设置中首次设置知予连接密码，再供新电脑登录。未设置密码的旧资料库不能被陌生客户端认领。服务器未升级时原连接仍可继续使用，但不能使用新密码功能。

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
