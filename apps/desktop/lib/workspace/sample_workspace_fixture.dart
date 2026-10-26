// Generated from the frozen Round09 fictional fixtures/model/seed.
// Data only; no runtime JavaScript, files, database or platform calls.
const sampleWorkspaceJson = r'''
{
  "source": "round-09 frozen prototype: fixtures.js/model.js/seed.js",
  "directories": [
    {
      "id": "all",
      "name": "全部资料",
      "icon": "grid"
    },
    {
      "id": "selfhost",
      "name": "自托管服务",
      "icon": "folder"
    },
    {
      "id": "home",
      "name": "家庭与设备",
      "icon": "folder"
    },
    {
      "id": "telegram",
      "name": "Telegram 工具",
      "icon": "folder"
    },
    {
      "id": "personal",
      "name": "个人资料",
      "icon": "folder"
    },
    {
      "id": "career",
      "name": "求职材料",
      "parent": "personal",
      "icon": "folder"
    },
    {
      "id": "unfiled",
      "name": "未分类",
      "icon": "folder"
    }
  ],
  "records": [
    {
      "id": "azure",
      "name": "Azure 日本服务器",
      "kind": "server",
      "category": "servers",
      "summary": "公网入口 · 域名与 HTTPS 反向代理",
      "subtitle": "东京 · Ubuntu 24.04",
      "updated": "10月22日",
      "fields": [
        [
          "主机地址",
          "tokyo.beichen.example"
        ],
        [
          "SSH 端口",
          "2222"
        ],
        [
          "登录用户",
          "developer"
        ],
        [
          "服务器用途",
          "HTTPS 入口与反向代理"
        ]
      ],
      "docs": [
        "https",
        "sshguide"
      ],
      "credentials": [
        "sshkey"
      ],
      "related": [
        "aliyun",
        "vikunja",
        "blinko"
      ],
      "tags": [
        "日本",
        "公网入口",
        "生产环境"
      ],
      "directory": "selfhost",
      "templateId": "server",
      "packageId": "builtin.server",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "server",
        "name": "服务器信息",
        "icon": "server",
        "fields": [
          {
            "key": "host",
            "label": "主机地址",
            "type": "text",
            "required": true
          },
          {
            "key": "port",
            "label": "SSH 端口",
            "type": "number",
            "required": false
          },
          {
            "key": "user",
            "label": "登录用户",
            "type": "text",
            "required": false
          },
          {
            "key": "purpose",
            "label": "服务器用途",
            "type": "text",
            "required": false
          },
          {
            "key": "environment",
            "label": "运行环境",
            "type": "text",
            "required": false
          },
          {
            "key": "region",
            "label": "地区",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "连接概览",
            "keys": [
              "host",
              "port",
              "user",
              "purpose",
              "environment",
              "region"
            ]
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "登录凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "维护文档"
          },
          {
            "kind": "relations",
            "key": "related",
            "title": "运行的应用与相关设备"
          }
        ],
        "relations": [
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先查找已有服务器；将连接参数、维护文档与登录凭据分别保存并明确关联。不要从名字或密钥片段猜测关联。不要求先建立目录。"
      },
      "values": {
        "host": "tokyo.beichen.example",
        "port": "2222",
        "user": "developer",
        "purpose": "HTTPS 入口与反向代理",
        "environment": "生产",
        "region": "日本 · 东京"
      },
      "relations": {
        "docs": [
          "https",
          "sshguide"
        ],
        "credentials": [
          "sshkey"
        ],
        "related": [
          "aliyun",
          "vikunja",
          "blinko"
        ]
      },
      "updatedAt": "2026-10-23"
    },
    {
      "id": "aliyun",
      "name": "阿里云杭州服务器",
      "kind": "server",
      "category": "servers",
      "summary": "业务服务 · 应用容器与数据存储",
      "subtitle": "杭州 · Ubuntu 24.04",
      "updated": "10月21日",
      "fields": [
        [
          "主机地址",
          "hangzhou.beichen.example"
        ],
        [
          "SSH 端口",
          "22"
        ],
        [
          "登录用户",
          "operator"
        ],
        [
          "服务器用途",
          "运行自托管应用"
        ]
      ],
      "docs": [
        "deploy"
      ],
      "credentials": [
        "aliyunkey"
      ],
      "related": [
        "azure",
        "blinko",
        "sparky"
      ],
      "tags": [
        "杭州",
        "应用部署",
        "生产环境"
      ],
      "directory": "selfhost",
      "templateId": "server",
      "packageId": "builtin.server",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "server",
        "name": "服务器信息",
        "icon": "server",
        "fields": [
          {
            "key": "host",
            "label": "主机地址",
            "type": "text",
            "required": true
          },
          {
            "key": "port",
            "label": "SSH 端口",
            "type": "number",
            "required": false
          },
          {
            "key": "user",
            "label": "登录用户",
            "type": "text",
            "required": false
          },
          {
            "key": "purpose",
            "label": "服务器用途",
            "type": "text",
            "required": false
          },
          {
            "key": "environment",
            "label": "运行环境",
            "type": "text",
            "required": false
          },
          {
            "key": "region",
            "label": "地区",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "连接概览",
            "keys": [
              "host",
              "port",
              "user",
              "purpose",
              "environment",
              "region"
            ]
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "登录凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "维护文档"
          },
          {
            "kind": "relations",
            "key": "related",
            "title": "运行的应用与相关设备"
          }
        ],
        "relations": [
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先查找已有服务器；将连接参数、维护文档与登录凭据分别保存并明确关联。不要从名字或密钥片段猜测关联。不要求先建立目录。"
      },
      "values": {
        "host": "hangzhou.beichen.example",
        "port": "22",
        "user": "operator",
        "purpose": "运行自托管应用",
        "environment": "生产",
        "region": "中国 · 杭州"
      },
      "relations": {
        "docs": [
          "deploy"
        ],
        "credentials": [
          "aliyunkey"
        ],
        "related": [
          "azure",
          "blinko",
          "sparky"
        ]
      },
      "updatedAt": "2026-10-22"
    },
    {
      "id": "nas",
      "name": "极空间 NAS",
      "kind": "server",
      "category": "servers",
      "summary": "家庭存储 · 视频资源与备份",
      "subtitle": "家庭网络 · SSH",
      "updated": "10月20日",
      "fields": [
        [
          "主机地址",
          "nas.home.example"
        ],
        [
          "SSH 端口",
          "22"
        ],
        [
          "登录用户",
          "media"
        ],
        [
          "服务器用途",
          "媒体存储与本地备份"
        ]
      ],
      "docs": [
        "nasdoc"
      ],
      "credentials": [],
      "related": [
        "video",
        "syncthing"
      ],
      "tags": [
        "家庭",
        "存储",
        "家庭"
      ],
      "directory": "home",
      "templateId": "server",
      "packageId": "builtin.server",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "server",
        "name": "服务器信息",
        "icon": "server",
        "fields": [
          {
            "key": "host",
            "label": "主机地址",
            "type": "text",
            "required": true
          },
          {
            "key": "port",
            "label": "SSH 端口",
            "type": "number",
            "required": false
          },
          {
            "key": "user",
            "label": "登录用户",
            "type": "text",
            "required": false
          },
          {
            "key": "purpose",
            "label": "服务器用途",
            "type": "text",
            "required": false
          },
          {
            "key": "environment",
            "label": "运行环境",
            "type": "text",
            "required": false
          },
          {
            "key": "region",
            "label": "地区",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "连接概览",
            "keys": [
              "host",
              "port",
              "user",
              "purpose",
              "environment",
              "region"
            ]
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "登录凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "维护文档"
          },
          {
            "kind": "relations",
            "key": "related",
            "title": "运行的应用与相关设备"
          }
        ],
        "relations": [
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先查找已有服务器；将连接参数、维护文档与登录凭据分别保存并明确关联。不要从名字或密钥片段猜测关联。不要求先建立目录。"
      },
      "values": {
        "host": "nas.home.example",
        "port": "22",
        "user": "media",
        "purpose": "媒体存储与本地备份",
        "environment": "家庭",
        "region": "中国 · 上海"
      },
      "relations": {
        "docs": [
          "nasdoc"
        ],
        "credentials": [],
        "related": [
          "video",
          "syncthing"
        ]
      },
      "updatedAt": "2026-10-21"
    },
    {
      "id": "blinko",
      "name": "Blinko 笔记",
      "kind": "service",
      "category": "services",
      "summary": "随手记录与饮食笔记",
      "subtitle": "部署于阿里云杭州",
      "updated": "10月22日",
      "fields": [
        [
          "访问入口",
          "https://notes.beichen.example"
        ],
        [
          "部署位置",
          "阿里云杭州服务器"
        ],
        [
          "认证方式",
          "API Token"
        ],
        [
          "日常用途",
          "记录笔记、检索饮食记录"
        ]
      ],
      "docs": [
        "deploy"
      ],
      "credentials": [
        "blinkokey"
      ],
      "related": [
        "aliyun",
        "azure"
      ],
      "tags": [
        "笔记"
      ],
      "directory": "selfhost",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "https://notes.beichen.example",
        "purpose": "随手记录与饮食笔记",
        "auth": "API Token"
      },
      "relations": {
        "docs": [
          "deploy"
        ],
        "credentials": [
          "blinkokey"
        ],
        "related": [
          "aliyun",
          "azure"
        ],
        "hostedOn": [
          "aliyun"
        ]
      },
      "updatedAt": "2026-10-20"
    },
    {
      "id": "vikunja",
      "name": "Vikunja 任务管理",
      "kind": "service",
      "category": "services",
      "summary": "项目任务、进度与协作",
      "subtitle": "部署于阿里云杭州",
      "updated": "10月21日",
      "fields": [
        [
          "访问入口",
          "https://tasks.beichen.example"
        ],
        [
          "部署位置",
          "阿里云杭州服务器"
        ],
        [
          "认证方式",
          "Agent API Token"
        ],
        [
          "日常用途",
          "管理项目与任务"
        ]
      ],
      "docs": [
        "deploy"
      ],
      "credentials": [
        "vikunjakey",
        "vikunja-password"
      ],
      "related": [
        "aliyun",
        "azure"
      ],
      "tags": [
        "任务管理"
      ],
      "directory": "selfhost",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "https://tasks.beichen.example",
        "purpose": "项目任务、进度与协作",
        "auth": "Agent API Token"
      },
      "relations": {
        "docs": [
          "deploy"
        ],
        "credentials": [
          "vikunjakey",
          "vikunja-password"
        ],
        "related": [
          "aliyun",
          "azure"
        ],
        "hostedOn": [
          "aliyun"
        ]
      },
      "updatedAt": "2026-10-19"
    },
    {
      "id": "sparky",
      "name": "SparkyFitness",
      "kind": "service",
      "category": "services",
      "summary": "饮食、运动与健康记录",
      "subtitle": "部署于阿里云杭州",
      "updated": "10月20日",
      "fields": [
        [
          "访问入口",
          "https://fitness.beichen.example"
        ],
        [
          "部署位置",
          "阿里云杭州服务器"
        ],
        [
          "认证方式",
          "API Key"
        ]
      ],
      "docs": [
        "deploy"
      ],
      "credentials": [],
      "related": [
        "aliyun",
        "blinko"
      ],
      "tags": [
        "健康"
      ],
      "directory": "selfhost",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "https://fitness.beichen.example",
        "purpose": "饮食、运动与健康记录",
        "auth": "API Key"
      },
      "relations": {
        "docs": [
          "deploy"
        ],
        "credentials": [],
        "related": [
          "aliyun",
          "blinko"
        ],
        "hostedOn": [
          "aliyun"
        ]
      },
      "updatedAt": "2026-10-18"
    },
    {
      "id": "skillshare",
      "name": "Skillshare",
      "kind": "service",
      "category": "services",
      "summary": "技能仓库与跨设备分发",
      "subtitle": "私有服务",
      "updated": "10月19日",
      "fields": [
        [
          "访问入口",
          "https://skills.beichen.example"
        ],
        [
          "仓库",
          "beichen/agent-skills"
        ],
        [
          "同步方式",
          "Git over SSH"
        ]
      ],
      "docs": [
        "deploy"
      ],
      "credentials": [],
      "related": [
        "aliyun"
      ],
      "tags": [
        "开发工具"
      ],
      "directory": "selfhost",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          },
          {
            "key": "extra0",
            "label": "仓库",
            "type": "text",
            "required": false
          },
          {
            "key": "extra1",
            "label": "同步方式",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth",
              "extra0",
              "extra1"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "https://skills.beichen.example",
        "purpose": "技能仓库与跨设备分发",
        "auth": "",
        "extra0": "beichen/agent-skills",
        "extra1": "Git over SSH"
      },
      "relations": {
        "docs": [
          "deploy"
        ],
        "credentials": [],
        "related": [
          "aliyun"
        ],
        "hostedOn": [
          "aliyun"
        ]
      },
      "updatedAt": "2026-10-17"
    },
    {
      "id": "video",
      "name": "Video Viewer",
      "kind": "service",
      "category": "services",
      "summary": "浏览 NAS 中的视频资源",
      "subtitle": "部署于家庭 NAS",
      "updated": "10月20日",
      "fields": [
        [
          "访问入口",
          "https://video.home.example"
        ],
        [
          "部署位置",
          "极空间 NAS"
        ],
        [
          "媒体目录",
          "/data/media"
        ]
      ],
      "docs": [
        "nasdoc"
      ],
      "credentials": [],
      "related": [
        "nas"
      ],
      "tags": [
        "媒体"
      ],
      "directory": "home",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          },
          {
            "key": "extra0",
            "label": "媒体目录",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth",
              "extra0"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "https://video.home.example",
        "purpose": "浏览 NAS 中的视频资源",
        "auth": "",
        "extra0": "/data/media"
      },
      "relations": {
        "docs": [
          "nasdoc"
        ],
        "credentials": [],
        "related": [
          "nas"
        ],
        "hostedOn": [
          "nas"
        ]
      },
      "updatedAt": "2026-10-16"
    },
    {
      "id": "syncthing",
      "name": "Syncthing",
      "kind": "service",
      "category": "services",
      "summary": "个人资料的设备间同步",
      "subtitle": "桌面端 ↔ NAS",
      "updated": "10月18日",
      "fields": [
        [
          "同步对象",
          "个人资料"
        ],
        [
          "设备",
          "桌面端与家庭 NAS"
        ],
        [
          "用途",
          "保持资料副本一致"
        ]
      ],
      "docs": [
        "nasdoc"
      ],
      "credentials": [],
      "related": [
        "nas"
      ],
      "tags": [
        "同步"
      ],
      "directory": "home",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          },
          {
            "key": "extra0",
            "label": "同步对象",
            "type": "text",
            "required": false
          },
          {
            "key": "extra1",
            "label": "设备",
            "type": "text",
            "required": false
          },
          {
            "key": "extra2",
            "label": "用途",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth",
              "extra0",
              "extra1",
              "extra2"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "",
        "purpose": "个人资料的设备间同步",
        "auth": "",
        "extra0": "个人资料",
        "extra1": "桌面端与家庭 NAS",
        "extra2": "保持资料副本一致"
      },
      "relations": {
        "docs": [
          "nasdoc"
        ],
        "credentials": [],
        "related": [
          "nas"
        ],
        "hostedOn": [
          "nas"
        ]
      },
      "updatedAt": "2026-10-15"
    },
    {
      "id": "tgapi",
      "name": "Telegram 开发者应用",
      "kind": "service",
      "category": "telegram",
      "summary": "应用登记与客户端初始化",
      "subtitle": "API 应用资料",
      "updated": "10月21日",
      "fields": [
        [
          "应用名称",
          "Beichen Assistant"
        ],
        [
          "API ID",
          "12345678"
        ],
        [
          "应用用途",
          "资源整理客户端"
        ]
      ],
      "docs": [],
      "credentials": [
        "tgsession"
      ],
      "related": [
        "mtproto",
        "workflow"
      ],
      "tags": [
        "Telegram"
      ],
      "directory": "telegram",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          },
          {
            "key": "extra0",
            "label": "应用名称",
            "type": "text",
            "required": false
          },
          {
            "key": "extra1",
            "label": "API ID",
            "type": "text",
            "required": false
          },
          {
            "key": "extra2",
            "label": "应用用途",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth",
              "extra0",
              "extra1",
              "extra2"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "",
        "purpose": "应用登记与客户端初始化",
        "auth": "",
        "extra0": "Beichen Assistant",
        "extra1": "12345678",
        "extra2": "资源整理客户端"
      },
      "relations": {
        "docs": [],
        "credentials": [
          "tgsession"
        ],
        "related": [
          "mtproto",
          "workflow"
        ],
        "hostedOn": []
      },
      "updatedAt": "2026-10-14"
    },
    {
      "id": "mtproto",
      "name": "Telegram MTProto 服务器",
      "kind": "service",
      "category": "telegram",
      "summary": "测试、生产连接参数与服务器公钥",
      "subtitle": "公钥附件 · PEM",
      "updated": "10月22日",
      "fields": [
        [
          "测试环境",
          "test.dc.example:443"
        ],
        [
          "生产环境",
          "production.dc.example:443"
        ],
        [
          "公钥用途",
          "验证服务器身份，不是登录凭据"
        ]
      ],
      "docs": [
        "publickey"
      ],
      "credentials": [],
      "related": [
        "tgapi"
      ],
      "tags": [
        "Telegram"
      ],
      "directory": "telegram",
      "templateId": "service",
      "packageId": "builtin.service",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "service",
        "name": "应用与服务",
        "icon": "layers",
        "fields": [
          {
            "key": "url",
            "label": "访问入口",
            "type": "url",
            "required": false
          },
          {
            "key": "purpose",
            "label": "应用用途",
            "type": "text",
            "required": false
          },
          {
            "key": "auth",
            "label": "认证方式",
            "type": "text",
            "required": false
          },
          {
            "key": "extra0",
            "label": "测试环境",
            "type": "text",
            "required": false
          },
          {
            "key": "extra1",
            "label": "生产环境",
            "type": "text",
            "required": false
          },
          {
            "key": "extra2",
            "label": "公钥用途",
            "type": "text",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "服务概览",
            "keys": [
              "url",
              "purpose",
              "auth",
              "extra0",
              "extra1",
              "extra2"
            ]
          },
          {
            "kind": "relations",
            "key": "hostedOn",
            "title": "部署位置"
          },
          {
            "kind": "relations",
            "key": "credentials",
            "title": "认证凭据"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "操作说明"
          }
        ],
        "relations": [
          {
            "key": "hostedOn",
            "label": "部署在",
            "targetTemplates": [
              "server"
            ]
          },
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。"
      },
      "values": {
        "url": "",
        "purpose": "测试、生产连接参数与服务器公钥",
        "auth": "",
        "extra0": "test.dc.example:443",
        "extra1": "production.dc.example:443",
        "extra2": "验证服务器身份，不是登录凭据"
      },
      "relations": {
        "docs": [
          "publickey"
        ],
        "credentials": [],
        "related": [
          "tgapi"
        ],
        "hostedOn": []
      },
      "updatedAt": "2026-10-13"
    },
    {
      "id": "workflow",
      "name": "Telegram 资源整理",
      "kind": "document",
      "category": "telegram",
      "summary": "收件、下载与归档的工作步骤",
      "subtitle": "工作流 · Markdown",
      "updated": "10月20日",
      "owner": "tgapi",
      "tags": [
        "工作流"
      ],
      "directory": "telegram",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-12"
    },
    {
      "id": "profile",
      "name": "个人档案",
      "kind": "profile",
      "category": "profile",
      "summary": "基本信息、教育和工作经历",
      "subtitle": "按经历分组 · 逐项授权",
      "updated": "10月22日",
      "tags": [
        "求职"
      ],
      "docs": [
        "resume",
        "proof"
      ],
      "credentials": [],
      "related": [],
      "directory": "personal",
      "templateId": "profile",
      "packageId": "builtin.profile",
      "templateVersion": "1.0.0",
      "definition": {
        "id": "profile",
        "name": "个人档案",
        "icon": "user",
        "fields": [
          {
            "key": "name",
            "label": "姓名",
            "type": "text",
            "required": false
          },
          {
            "key": "email",
            "label": "联系邮箱",
            "type": "text",
            "required": false
          },
          {
            "key": "direction",
            "label": "求职方向",
            "type": "text",
            "required": false
          },
          {
            "key": "city",
            "label": "所在城市",
            "type": "text",
            "required": false
          },
          {
            "key": "education",
            "label": "教育经历",
            "type": "entries",
            "required": false
          },
          {
            "key": "experience",
            "label": "工作经历",
            "type": "entries",
            "required": false
          }
        ],
        "sections": [
          {
            "kind": "fields",
            "title": "基本信息",
            "keys": [
              "name",
              "email",
              "direction",
              "city"
            ]
          },
          {
            "kind": "timeline",
            "key": "education",
            "title": "教育经历"
          },
          {
            "kind": "timeline",
            "key": "experience",
            "title": "工作经历"
          },
          {
            "kind": "relations",
            "key": "docs",
            "title": "简历与证明"
          }
        ],
        "relations": [
          {
            "key": "docs",
            "label": "文档与附件",
            "targetTemplates": []
          },
          {
            "key": "credentials",
            "label": "关联凭据",
            "targetTemplates": []
          },
          {
            "key": "related",
            "label": "相关资料",
            "targetTemplates": []
          }
        ],
        "instructions": "学校、学历、专业和日期按每段经历成组。简历文件独立保存，通过关联进入；真实版本关系需要核对内容，不能只根据文件名判断。"
      },
      "values": {
        "name": "林予安",
        "email": "yuan.lin@example.com",
        "direction": "服务端研发",
        "city": "上海",
        "education": [
          {
            "title": "北辰大学 · 计算机技术硕士",
            "period": "2024.09 — 2027.06",
            "detail": "信息学院 · 分布式系统方向"
          },
          {
            "title": "南川大学 · 软件工程学士",
            "period": "2020.09 — 2024.06",
            "detail": "计算机学院 · GPA 3.7 / 4.0"
          }
        ],
        "experience": [
          {
            "title": "后端研发实习",
            "period": "2026.04 — 2026.08",
            "detail": "参与任务调度与服务监控开发。"
          }
        ]
      },
      "relations": {
        "docs": [
          "resume",
          "resume-en",
          "proof",
          "portrait"
        ],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-23"
    },
    {
      "id": "resume",
      "name": "服务端开发简历",
      "kind": "resume",
      "category": "career",
      "summary": "中文 · 服务端研发岗位",
      "subtitle": "PDF · 465 KB · 2 个版本",
      "updated": "10月22日",
      "version": "v2",
      "filename": "林予安-服务端开发-v2.pdf",
      "tags": [
        "中文",
        "服务端"
      ],
      "related": [
        "profile",
        "proof"
      ],
      "credentials": [],
      "directory": "career",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "profile",
          "proof"
        ]
      },
      "updatedAt": "2026-10-22"
    },
    {
      "id": "resume-en",
      "name": "英文简历",
      "kind": "resume",
      "category": "career",
      "summary": "英文 · Backend Engineer",
      "subtitle": "PDF · 320 KB · 1 个版本",
      "updated": "10月18日",
      "version": "v1",
      "filename": "Yuan-Lin-Backend.pdf",
      "tags": [
        "英文",
        "服务端"
      ],
      "related": [
        "profile"
      ],
      "credentials": [],
      "directory": "career",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "profile"
        ]
      },
      "updatedAt": "2026-10-21"
    },
    {
      "id": "proof",
      "name": "实习证明",
      "kind": "file",
      "category": "career",
      "summary": "研发实习经历的证明材料",
      "subtitle": "PDF · 180 KB",
      "updated": "10月16日",
      "filename": "研发实习证明.pdf",
      "related": [
        "profile"
      ],
      "tags": [
        "证明材料"
      ],
      "directory": "career",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "profile"
        ]
      },
      "updatedAt": "2026-10-20"
    },
    {
      "id": "offer",
      "name": "录用通知书",
      "kind": "file",
      "category": "career",
      "summary": "录用岗位、入职日期与约定",
      "subtitle": "PDF · 210 KB",
      "updated": "10月15日",
      "filename": "录用通知书.pdf",
      "related": [
        "profile"
      ],
      "tags": [
        "证明材料"
      ],
      "directory": "career",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "profile"
        ]
      },
      "updatedAt": "2026-10-19"
    },
    {
      "id": "portrait",
      "name": "证件照",
      "kind": "file",
      "category": "career",
      "summary": "蓝底 · 1:1 · 用于招聘网站",
      "subtitle": "PNG · 800 × 800",
      "updated": "10月15日",
      "filename": "证件照-方形.png",
      "related": [
        "profile"
      ],
      "tags": [
        "照片"
      ],
      "directory": "career",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "profile"
        ]
      },
      "updatedAt": "2026-10-18"
    },
    {
      "id": "https",
      "name": "域名与 HTTPS",
      "kind": "document",
      "category": "docs",
      "summary": "DNS、反向代理与新增服务的操作说明",
      "subtitle": "Azure 日本服务器 · Markdown",
      "updated": "10月22日",
      "owner": "azure",
      "tags": [
        "运维",
        "HTTPS"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-17"
    },
    {
      "id": "sshguide",
      "name": "SSH 连接与维护",
      "kind": "document",
      "category": "docs",
      "summary": "连接步骤、主机校验与常见故障",
      "subtitle": "Azure 日本服务器 · Markdown",
      "updated": "10月21日",
      "owner": "azure",
      "tags": [
        "运维"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-16"
    },
    {
      "id": "deploy",
      "name": "自托管服务部署",
      "kind": "document",
      "category": "docs",
      "summary": "容器部署、数据目录与更新流程",
      "subtitle": "阿里云杭州服务器 · Markdown",
      "updated": "10月20日",
      "owner": "aliyun",
      "tags": [
        "运维"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-15"
    },
    {
      "id": "nasdoc",
      "name": "NAS 与媒体目录",
      "kind": "document",
      "category": "docs",
      "summary": "共享目录、访问方式与备份",
      "subtitle": "极空间 NAS · Markdown",
      "updated": "10月18日",
      "owner": "nas",
      "tags": [
        "存储"
      ],
      "directory": "home",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-14"
    },
    {
      "id": "publickey",
      "name": "MTProto 服务器公钥",
      "kind": "file",
      "category": "telegram",
      "summary": "测试和生产环境的 RSA 公钥",
      "subtitle": "PEM / PKCS#1 · 公开认证材料",
      "updated": "10月22日",
      "filename": "telegram-server-public.pem",
      "owner": "mtproto",
      "related": [
        "mtproto"
      ],
      "tags": [
        "公钥"
      ],
      "directory": "telegram",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": [
          "mtproto"
        ]
      },
      "updatedAt": "2026-10-13"
    },
    {
      "id": "sshkey",
      "name": "Azure SSH 私钥",
      "kind": "credential",
      "category": "credentials",
      "summary": "登录 Azure 日本服务器",
      "subtitle": "PEM / RSA · 支持 SSH 注入",
      "updated": "10月21日",
      "owner": "azure",
      "format": "PEM / RSA",
      "filename": "azure-jp.pem",
      "capability": "可用于 SSH",
      "binding": "SSH_KEY_FILE",
      "tags": [
        "SSH"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-12"
    },
    {
      "id": "aliyunkey",
      "name": "阿里云 SSH 私钥",
      "kind": "credential",
      "category": "credentials",
      "summary": "登录阿里云杭州服务器",
      "subtitle": "OpenSSH · 支持 SSH 注入",
      "updated": "10月20日",
      "owner": "aliyun",
      "format": "OpenSSH",
      "filename": "aliyun_ed25519",
      "capability": "可用于 SSH",
      "binding": "SSH_KEY_FILE",
      "tags": [
        "SSH"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-23"
    },
    {
      "id": "blinkokey",
      "name": "Blinko API Token",
      "kind": "credential",
      "category": "credentials",
      "summary": "通过 API 读取和创建笔记",
      "subtitle": "字符串 · 环境变量",
      "updated": "10月21日",
      "owner": "blinko",
      "format": "Token 字符串",
      "capability": "可注入环境变量",
      "binding": "BLINKO_TOKEN",
      "tags": [
        "API"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-22"
    },
    {
      "id": "vikunjakey",
      "name": "Vikunja Agent Token",
      "kind": "credential",
      "category": "credentials",
      "summary": "管理指定项目的任务",
      "subtitle": "字符串 · 环境变量",
      "updated": "10月20日",
      "owner": "vikunja",
      "format": "Token 字符串",
      "capability": "可注入环境变量",
      "binding": "VIKUNJA_TOKEN",
      "tags": [
        "API"
      ],
      "directory": "selfhost",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-21"
    },
    {
      "id": "tgsession",
      "name": "Telethon 登录会话",
      "kind": "credential",
      "category": "credentials",
      "summary": "保留 Telegram 客户端的登录状态",
      "subtitle": "SQLite / .session · 仅保管",
      "updated": "10月21日",
      "owner": "tgapi",
      "format": "SQLite / .session",
      "filename": "telegram-client.session",
      "capability": "尚未支持使用",
      "binding": "",
      "tags": [
        "登录会话"
      ],
      "directory": "telegram",
      "templateId": null,
      "packageId": null,
      "templateVersion": null,
      "definition": null,
      "values": {},
      "relations": {
        "docs": [],
        "credentials": [],
        "related": []
      },
      "updatedAt": "2026-10-20"
    },
    {
      "id": "ideas",
      "name": "下一次整理的想法",
      "summary": "尚未分类的几条工作记录",
      "directory": "unfiled",
      "kind": "note",
      "templateId": null,
      "values": {
        "body": "先梳理服务用途，再补充维护文档。没有合适模板的资料，可以先保存为通用信息。"
      },
      "relations": {},
      "tags": [],
      "updatedAt": "2026-10-19"
    },
    {
      "id": "github-token",
      "name": "GitHub 仓库 Token",
      "summary": "查看 northstar/agent-skills 仓库与事项；授权范围仅限该仓库",
      "kind": "credential",
      "directory": "selfhost",
      "tags": [
        "代码仓库"
      ],
      "format": "Token 字符串",
      "binding": "GH_TOKEN",
      "owner": "ideas",
      "relations": {},
      "values": {},
      "updatedAt": "2026-10-18"
    },
    {
      "id": "vikunja-password",
      "name": "Vikunja 登录密码",
      "summary": "任务管理网页登录使用，与 Agent API Token 分开保管",
      "kind": "credential",
      "directory": "selfhost",
      "tags": [
        "任务管理"
      ],
      "format": "密码字符串",
      "binding": "当前输入焦点",
      "delivery": "focus",
      "owner": "vikunja",
      "relations": {},
      "values": {},
      "updatedAt": "2026-10-17"
    }
  ],
  "pending": 5,
  "proposals": 2,
  "trash": [
    {
      "id": "retired-doc",
      "name": "旧部署笔记",
      "summary": "已迁移到新的维护文档",
      "kind": "document",
      "directory": "selfhost",
      "tags": [
        "归档"
      ],
      "values": {
        "body": "旧的容器部署步骤。"
      },
      "deletedAt": "2026-10-20",
      "relations": {}
    }
  ]
}
''';
