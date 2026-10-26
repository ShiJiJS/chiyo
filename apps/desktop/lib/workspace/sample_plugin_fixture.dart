import 'dart:convert';

// Derived from the frozen domain fixture; external references are scoped for S2.
const sampleDomainPackageJson = r'''
{
  "id": "local.domain",
  "name": "域名管理",
  "version": "1.0.0",
  "hostApi": 1,
  "author": "本机 Agent",
  "description": "记录域名、续费时间与 DNS 配置，按需关联服务器。",
  "templates": [
    {
      "id": "domain",
      "name": "域名",
      "icon": "globe",
      "fields": [
        {
          "key": "domain",
          "label": "域名",
          "type": "text",
          "required": true
        },
        {
          "key": "registrar",
          "label": "注册商",
          "type": "text",
          "required": false
        },
        {
          "key": "expires",
          "label": "到期日期",
          "type": "date",
          "required": false
        },
        {
          "key": "dns",
          "label": "DNS 服务",
          "type": "text",
          "required": false
        },
        {
          "key": "purpose",
          "label": "域名用途",
          "type": "text",
          "required": false
        }
      ],
      "sections": [
        {
          "kind": "fields",
          "title": "域名概览",
          "keys": [
            "domain",
            "registrar",
            "expires",
            "dns"
          ]
        },
        {
          "kind": "text",
          "key": "purpose",
          "title": "用途说明"
        },
        {
          "kind": "relations",
          "key": "pointsTo",
          "title": "指向的服务器"
        }
      ],
      "relations": [
        {
          "key": "pointsTo",
          "label": "指向服务器",
          "targetTemplates": [
            "builtin.server/server"
          ]
        }
      ],
      "instructions": "先按完整域名检索已有资料，避免重复录入。注册商与 DNS 服务分别填写；没有到期日期时留空，不推测。关联服务器需要明确依据，可以暂不关联。认证材料作为独立托管凭据，不写入域名字段。",
      "example": {
        "name": "北辰服务域名",
        "summary": "统一访问个人自托管服务",
        "values": {
          "domain": "beichen.example",
          "registrar": "示范注册商",
          "expires": "2027-06-18",
          "dns": "托管 DNS",
          "purpose": "为笔记、任务管理与健康记录提供统一入口。"
        }
      }
    }
  ]
}
''';

Map<String, ({String filename, List<int> bytes})> samplePluginInputs() {
  final update = jsonDecode(sampleDomainPackageJson) as Map<String, dynamic>;
  update['version'] = '1.1.0';
  final template = (update['templates'] as List).single as Map<String, dynamic>;
  (template['fields'] as List).add({
    'key': 'maintainer',
    'label': '维护负责人',
    'type': 'text',
    'required': false,
  });
  ((template['sections'] as List).first['keys'] as List).add('maintainer');
  final changed = jsonDecode(sampleDomainPackageJson) as Map<String, dynamic>;
  changed['description'] = '同版本内容被修改';
  final invalid = jsonDecode(sampleDomainPackageJson) as Map<String, dynamic>;
  invalid['templates'][0]['fields'][0]['type'] = 'secret';
  return {
    'domain-v1': (
      filename: '域名管理-1.0.0.json',
      bytes: utf8.encode(sampleDomainPackageJson),
    ),
    'domain-v2': (
      filename: '域名管理-1.1.0.json',
      bytes: utf8.encode(jsonEncode(update)),
    ),
    'domain-same-version': (
      filename: '域名管理-1.0.0-内容变更.json',
      bytes: utf8.encode(jsonEncode(changed)),
    ),
    'invalid-field': (
      filename: '字段格式错误.json',
      bytes: utf8.encode(jsonEncode(invalid)),
    ),
    'duplicate-key': (
      filename: '重复身份.json',
      bytes: utf8.encode('{"id":"local.first","id":"local.second"}'),
    ),
  };
}
