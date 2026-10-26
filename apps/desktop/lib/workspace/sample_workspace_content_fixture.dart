// Central fictional content. Widgets do not know fixture IDs or invent body
// text. Frozen HTML files remain unchanged.
const sampleDocumentDefinition = <String, Object?>{
  'id': 'document',
  'name': '文档',
  'icon': 'book',
  'fields': [
    {'key': 'bodyFormat', 'label': '正文格式', 'type': 'text'},
    {'key': 'body', 'label': '正文', 'type': 'multiline'},
  ],
  'sections': [
    {'kind': 'text', 'title': '正文', 'key': 'body', 'formatKey': 'bodyFormat'},
    {'kind': 'relations', 'title': '关联资料', 'key': 'related'},
  ],
  'relations': [
    {'key': 'related', 'label': '关联资料', 'targetTemplates': <String>[]},
  ],
};

const sampleDocumentBodies = <String, String>{
  'https': '''## 用途与适用范围

日本节点作为公网入口，接收 HTTPS 请求，再通过内部网络转发到杭州服务器。应用数据和容器保留在杭州。

## 访问入口

| 入口 | 服务 |
| --- | --- |
| notes.beichen.example | Blinko 笔记 |
| tasks.beichen.example | Vikunja 任务管理 |

## 维护步骤

1. 核对对应服务器与服务的连接资料。
2. 申请所需凭据，通过获批方式执行操作。
3. 检查配置和服务状态，记录变更结果。

```sh
caddy validate --config /etc/caddy/Caddyfile
```

认证材料单独保存在关联凭据中，操作说明不包含密钥原文。
''',
  'sshguide': '''## 登录与日常维护

连接前核对主机身份。私钥保存在关联凭据中，获批后由 CLI 准备运行时材料。

1. 确认目标主机、端口和登录用户。
2. 通过批准的凭据使用方式启动 SSH。
3. 检查服务状态并记录维护结果。

```sh
ssh -i {{SSH_KEY_FILE}} -p 2222 developer@tokyo.beichen.example
```
''',
  'deploy': '''## 容器与数据目录

应用运行在杭州服务器；持久化数据与容器配置分开保存。

- 核对应用入口、部署主机和数据目录。
- 更新前备份配置及持久化数据。
- 更新后检查应用健康状态和公网入口。

```sh
docker compose ps
```
''',
  'nasdoc': '''## 媒体目录与备份

NAS 保管媒体文件与个人资料副本。应用只访问各自需要的目录。

1. 确认共享目录和当前访问账号。
2. 核对挂载路径及读写范围。
3. 检查备份任务与最近同步结果。

`/data/media`
''',
  'workflow': '''## 收件与资源整理

按主题整理收到的资源，下载与登录会话分别管理。

1. 确认资源来源及保存目的。
2. 按需要领取已获准资料或使用登录凭据。
3. 保留来源说明，再归入对应目录。
''',
};
