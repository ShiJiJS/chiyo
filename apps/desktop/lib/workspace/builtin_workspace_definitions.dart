import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';

/// Built-in form schemas only. These never create records, packages, sample
/// values or directories. Existing records keep their own frozen definitions.
final Map<String, Map<String, Object?>> builtinWorkspaceDefinitions =
    Map.unmodifiable({
      for (final definition in _definitions)
        definition['id'] as String: workspaceImmutableMap({
          ...definition,
          'templateVersion': '1',
          'packageDigest': sha256
              .convert(utf8.encode(jsonEncode(definition)))
              .toString(),
        }),
    });

Map<String, Object?> _field(String key, String label, [String type = 'text']) =>
    {'key': key, 'label': label, 'type': type};
Map<String, Object?> _relation(
  String key,
  String label, [
  List<String> types = const [],
]) => {'key': key, 'label': label, 'targetTemplates': types};
Map<String, Object?> _section(String title, List<String> keys) => {
  'kind': 'fields',
  'title': title,
  'keys': keys,
};
final _commonRelations = [
  _relation('docs', '文档与附件'),
  _relation('credentials', '关联凭据', ['credential']),
  _relation('related', '相关资料'),
];

final _definitions = <Map<String, Object?>>[
  {
    'id': 'file',
    'name': '文件',
    'icon': 'file',
    'fields': [_field('file', '文件', 'file')],
    'sections': [
      _section('文件', ['file']),
      {'kind': 'relations', 'title': '关联资料', 'key': 'related'},
    ],
    'relations': [_relation('related', '关联资料')],
  },
  {
    'id': 'generic',
    'name': '通用资料',
    'icon': 'file',
    'fields': [_field('body', '内容', 'multiline')],
    'sections': [
      {'kind': 'text', 'title': '内容', 'key': 'body'},
      {'kind': 'relations', 'title': '关联资料', 'key': 'related'},
    ],
    'relations': [_relation('related', '关联资料')],
  },
  {
    'id': 'document',
    'name': '文档',
    'icon': 'book',
    'fields': [_field('bodyFormat', '正文格式'), _field('body', '正文', 'multiline')],
    'sections': [
      {'kind': 'text', 'title': '正文', 'key': 'body', 'formatKey': 'bodyFormat'},
      {'kind': 'relations', 'title': '关联资料', 'key': 'related'},
    ],
    'relations': [_relation('related', '关联资料')],
  },
  {
    'id': 'server',
    'name': '服务器信息',
    'icon': 'server',
    'fields': [
      {..._field('host', '主机地址'), 'required': true},
      _field('port', 'SSH 端口', 'number'),
      _field('user', '登录用户'),
      _field('purpose', '服务器用途'),
    ],
    'sections': [
      _section('连接概览', ['host', 'port', 'user', 'purpose']),
      {'kind': 'relations', 'key': 'credentials', 'title': '登录凭据'},
      {'kind': 'relations', 'key': 'docs', 'title': '维护文档'},
      {'kind': 'relations', 'key': 'related', 'title': '相关资料'},
    ],
    'relations': _commonRelations,
  },
  {
    'id': 'service',
    'name': '应用与服务',
    'icon': 'layers',
    'fields': [
      _field('url', '访问入口', 'url'),
      _field('purpose', '应用用途'),
      _field('auth', '认证方式'),
    ],
    'sections': [
      _section('服务概览', ['url', 'purpose', 'auth']),
      {'kind': 'relations', 'key': 'hostedOn', 'title': '部署位置'},
      {'kind': 'relations', 'key': 'credentials', 'title': '认证凭据'},
      {'kind': 'relations', 'key': 'docs', 'title': '操作说明'},
      {'kind': 'relations', 'key': 'related', 'title': '相关资料'},
    ],
    'relations': [
      _relation('hostedOn', '部署在', ['server']),
      ..._commonRelations,
    ],
  },
  {
    'id': 'profile',
    'name': '个人档案',
    'icon': 'user',
    'fields': [
      _field('name', '姓名'),
      _field('email', '联系邮箱'),
      _field('direction', '求职方向'),
      _field('city', '所在城市'),
      _field('education', '教育经历', 'entries'),
      _field('experience', '工作经历', 'entries'),
    ],
    'sections': [
      _section('基本信息', ['name', 'email', 'direction', 'city']),
      {'kind': 'timeline', 'key': 'education', 'title': '教育经历'},
      {'kind': 'timeline', 'key': 'experience', 'title': '工作经历'},
      {'kind': 'relations', 'key': 'docs', 'title': '简历与证明'},
      {'kind': 'relations', 'key': 'related', 'title': '相关资料'},
    ],
    'relations': _commonRelations,
  },
];
