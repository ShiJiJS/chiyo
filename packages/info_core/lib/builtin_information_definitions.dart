import 'dart:convert';
import 'package:crypto/crypto.dart';

Map<String, Object?> _immutableDefinition(Map<String, Object?> value) {
  Object? freeze(Object? v) {
    if (v is Map)
      return Map<String, Object?>.unmodifiable(
        v.map((k, v) => MapEntry(k as String, freeze(v))),
      );
    if (v is List) return List<Object?>.unmodifiable(v.map(freeze));
    if (v == null || v is String || v is num || v is bool) return v;
    throw ArgumentError('Only JSON-compatible definitions are supported');
  }

  return freeze(value) as Map<String, Object?>;
}

/// Built-in form schemas only. These never create records, packages, sample
/// values or directories. Existing records keep their own frozen definitions.
final Map<String, Map<String, Object?>> builtinWorkspaceDefinitions =
    Map.unmodifiable({
      for (final definition in _definitions)
        definition['id'] as String: _immutableDefinition({
          ...definition,
          ..._guidance(definition['id'] as String),
          'templateVersion': '1',
          'packageDigest': sha256
              .convert(
                utf8.encode(
                  jsonEncode({
                    ...definition,
                    ..._guidance(definition['id'] as String),
                  }),
                ),
              )
              .toString(),
        }),
    });

Map<String, Object?> _guidance(String type) {
  final exampleValues = <String, Map<String, Object?>>{
    'generic': {'body': '资料内容；只填写用户提供的事实。'},
    'document': {
      'bodyFormat': 'markdown',
      'body':
          '## Mac 同步配置\n\n- 本地目录：`/Users/example/Notes`\n- 同步文件夹：`Notes`\n- 连接部署在云主机上的 Syncthing 服务。',
    },
    'server': {
      'host': '192.0.2.10',
      'port': '22',
      'user': 'operator',
      'purpose': '运行内部应用及保存业务数据。',
    },
    'service': {
      'url': 'https://vpn-cloud.example.invalid',
      'purpose': '连接云主机与个人设备。',
      'auth': '通过外部身份服务登录，未提供静态密码。',
    },
    'profile': {
      'name': '示例姓名',
      'email': 'person@example.invalid',
      'direction': '后端开发',
      'city': '示例城市',
      'education': [
        {'title': '示例大学 · 计算机专业', 'period': '2020–2024', 'detail': '本科教育经历。'},
      ],
      'experience': [],
    },
    'file': {'file': 'primary'},
  };
  return {
    'instructions': switch (type) {
      'server' => '用于一台服务器。地址、SSH端口、登录用户分别填写简短值；密码和私钥另存为凭据并关联。不同服务器分别建资料。',
      'service' =>
        '用于一个应用或服务的实际部署或外部平台连接。名称用软件名，独立部署可加位置，例如“WireGuard 云主机”“WireGuard 校园网”；用途放描述。两套部署分别填写各自入口，并用hostedOn关联对应服务器，不合并为一个应用的版本。Mac或Windows专属配置用文档资料单独填写，用docs关联；不要把使用步骤另建成应用。关系格式见本次relationInput：如hostedOn:[{"kind":"information","id":"已有服务器ID"}]，同份提案的新服务器改用itemKey。外部平台无需编造部署主机。认证方式未知就明确未知；只有确知使用密码登录才准备待填密码，Token和密钥按凭据模板另存并关联。',
      'profile' => '只填写源资料中明确给出的个人事实。教育和工作经历按title、period、detail逐段填写，未知内容不编造。',
      'document' =>
        '用于有独立用途的正文或设备配置。bodyFormat选择plain或markdown，body存对应格式；名称与公开用途简短。例子是“Syncthing Mac 配置”：只记录Mac本地目录、同步文件夹和连接端点，related关联实际Syncthing应用，关系格式如related:[{"kind":"information","id":"已有应用ID"}]；同份提案新应用改用itemKey。Windows有不同配置时另建一条并关联同一服务，未知的平台配置不编造。已经由业务Skill及其配置维护的流程不再抄一份；汇总来源先提取事实，需保管原件则用文件模板关联，不把整篇原文塞在这里。',
      'file' =>
        '用于需要独立保管、交付或继续修订的普通原件。信息已完整提取且原件没有独立用途时不再保存来源副本。多处使用同一原件时复用本资料，通过related关联相应对象；同一材料的修订作为文件版本，不同用途各建一条。私钥、登录会话等走凭据入口。',
      _ => '仅在通用资料确实符合内容用途时使用。body填写清晰正文，不堆源文档或过程编号；缺少合适模板时建议并暂缓，不自行创建插件。',
    },
    'example': {
      'name': switch (type) {
        'server' => '业务服务器',
        'service' => 'NetBird 云主机',
        'profile' => '个人基本档案',
        'document' => 'Syncthing Mac 配置',
        'file' => '后端岗位简历',
        _ => '项目说明',
      },
      'summary': switch (type) {
        'server' => '运行内部应用，可按需申请连接信息和维护资料。',
        'service' => '云主机上的设备组网服务。',
        'profile' => '联系资料、求职方向与教育工作经历。',
        'document' => 'Mac 本地目录与同步服务的对应设置。',
        'file' => '用于后端开发岗位投递的简历原文。',
        _ => '项目的用途及基本说明。',
      },
      'values': exampleValues[type]!,
    },
  };
}

Map<String, Object?> _field(String key, String label, [String type = 'text']) =>
    {
      'key': key,
      'label': label,
      'type': type,
      'description': switch (key) {
        'host' => '主机名或IP地址，只填地址，不放整条连接命令。',
        'port' => 'SSH端口，填写十进制数字。',
        'user' => '登录用户名，不包含密码或密钥。',
        'url' => '服务访问入口，不包含Token等秘密参数。',
        'purpose' => '用简短事实说明用途，不复制整段源文档。',
        'auth' => '说明认证方式；秘密另走凭据录入申请。',
        'bodyFormat' => '正文格式：plain为原文字，markdown为Markdown排版。',
        'body' => '资料正文，按声明格式填写；密码和密钥不能放进普通正文。',
        'name' => '源资料中的姓名，未知时留空，不编造。',
        'email' => '源资料中的联系邮箱。',
        'direction' => '本份材料面向的求职方向。',
        'city' => '源资料中明确说明的城市。',
        'education' || 'experience' => '每项含title、period、detail；分别填写经历名称、时间与说明。',
        'file' => '提交普通文件原文；私钥、登录会话等应使用凭据入口。',
        _ => label,
      },
    };
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
