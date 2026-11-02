import 'dart:convert';
import 'package:crypto/crypto.dart';

class TemplatePackageFailure implements Exception {
  TemplatePackageFailure(Map<String, String> errors)
    : fieldErrors = Map.unmodifiable(errors);
  final Map<String, String> fieldErrors;
  @override
  String toString() => 'TemplatePackageFailure(invalid_package)';
}

String templatePackageTypeId(String package, String template) =>
    package == 'builtin.$template' &&
        const {'server', 'service', 'profile'}.contains(template)
    ? template
    : '$package/$template';

class TemplatePackageType {
  const TemplatePackageType(this.id, this.name, this.icon);
  final String id, name, icon;
}

Object? _freezePackage(Object? value) => value is Map
    ? Map<String, Object?>.unmodifiable({
        for (final e in value.entries) e.key as String: _freezePackage(e.value),
      })
    : value is List
    ? List<Object?>.unmodifiable(value.map(_freezePackage))
    : value;

class TemplatePackageTemplate {
  TemplatePackageTemplate({
    required this.id,
    required this.type,
    required Map<String, Object?> definition,
  }) : definition = _freezePackage(definition) as Map<String, Object?>;
  final String id;
  final TemplatePackageType type;
  final Map<String, Object?> definition;
}

class TemplatePackageDefinition {
  TemplatePackageDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.digest,
    required this.origin,
    required Iterable<TemplatePackageTemplate> templates,
  }) : templates = List.unmodifiable(templates);
  final String id, name, version, author, description, digest, origin;
  final List<TemplatePackageTemplate> templates;
}

/// Declarative input only. No files, URLs, scripts, settings loaders or IO.
class DeclarativeTemplatePackageDecoder {
  static const maxBytes = 1024 * 1024;
  static const maxDepth = 16;
  static const fieldTypes = {
    'text',
    'url',
    'number',
    'date',
    'multiline',
    'entries',
  };
  static const icons = {
    'server',
    'layers',
    'user',
    'book',
    'file',
    'globe',
    'plugin',
  };
  static Never _fail(String path, String reason) =>
      throw TemplatePackageFailure({path: reason});

  TemplatePackageDefinition decode(
    List<int> bytes, {
    required String origin,
    Set<String> knownTemplates = const {},
    bool allowMissingTargets = false,
  }) {
    if (bytes.length > maxBytes) _fail(r'$', '包不能超过1 MiB。');
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      _fail(r'$', '需要有效的UTF-8 JSON文件。');
    }
    _JsonShape(text).check();
    Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      _fail(r'$', 'JSON语法错误。');
    }
    final package = _map(raw, r'$');
    _keys(package, {
      'id',
      'name',
      'version',
      'hostApi',
      'author',
      'description',
      'templates',
    }, r'$');
    final id = _text(package, 'id', r'$', max: 128);
    if (!RegExp(r'^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+$').hasMatch(id) ||
        id.startsWith('builtin.')) {
      _fail(r'$.id', '外部包需要独立命名空间，不能占用builtin身份。');
    }
    final version = _text(package, 'version', r'$', max: 64);
    if (!RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
    ).hasMatch(version)) {
      _fail(r'$.version', '版本须为三段非负整数，不带前缀或预发行标记。');
    }
    if (package['hostApi'] is! num || package['hostApi'] != 1) {
      _fail(r'$.hostApi', '仅支持hostApi 1。');
    }
    final list = _list(
      package['templates'],
      r'$.templates',
      10,
      nonempty: true,
    );
    final ids = <String>{};
    for (final (index, item) in list.indexed) {
      final p =
          r'$.templates'
          '[$index]';
      final template = _map(item, p), key = _identifier(template, 'id', p);
      if (!ids.add(key)) _fail('$p.id', '模板身份重复。');
    }
    final available = {...knownTemplates, for (final key in ids) '$id/$key'};
    final templates = <TemplatePackageTemplate>[];
    for (final (index, item) in list.indexed) {
      final p =
              r'$.templates'
              '[$index]',
          t = _map(item, p);
      _keys(t, {
        'id',
        'name',
        'icon',
        'fields',
        'sections',
        'relations',
        'instructions',
        'example',
      }, p);
      final key = t['id'] as String,
          name = _text(t, 'name', p, max: 160),
          icon = _text(t, 'icon', p, max: 32);
      if (!icons.contains(icon)) _fail('$p.icon', '图标不在宿主支持范围内。');
      final fields = _list(t['fields'], '$p.fields', 40),
          fieldKinds = <String, String>{};
      for (final (n, rawField) in fields.indexed) {
        final path = '$p.fields[$n]', f = _map(rawField, path);
        _keys(f, {'key', 'label', 'type', 'required', 'description'}, path);
        final field = _identifier(f, 'key', path),
            kind = _text(f, 'type', path, max: 32);
        _text(f, 'label', path, max: 160);
        if (f.containsKey('description')) {
          _text(f, 'description', path, max: 2000, empty: true);
        }
        if (fieldKinds.containsKey(field)) _fail('$path.key', '字段身份重复。');
        if (!fieldTypes.contains(kind)) {
          _fail('$path.type', '不支持此字段类型；文件和凭据由宿主管理。');
        }
        if (f['required'] is! bool) _fail('$path.required', '需要明确的布尔值。');
        fieldKinds[field] = kind;
      }
      final relations = _list(t['relations'], '$p.relations', 40),
          relationKeys = <String>{};
      final resolved = <Map<String, Object?>>[];
      for (final (n, rawRelation) in relations.indexed) {
        final path = '$p.relations[$n]', r = _map(rawRelation, path);
        _keys(r, {'key', 'label', 'targetTemplates'}, path);
        final relation = _identifier(r, 'key', path);
        if (!relationKeys.add(relation)) _fail('$path.key', '关联身份重复。');
        _text(r, 'label', path, max: 160);
        final targets = _list(
          r['targetTemplates'],
          '$path.targetTemplates',
          40,
        );
        if (targets.any(
          (value) =>
              value is! String ||
              (!available.contains(value) &&
                  (!allowMissingTargets ||
                      !RegExp(
                        r'^[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+/[a-z][a-zA-Z0-9_-]*$',
                      ).hasMatch(value))),
        )) {
          _fail('$path.targetTemplates', '目标需要现存的包ID/模板ID，不能引用未知定义。');
        }
        if (targets.toSet().length != targets.length) {
          _fail('$path.targetTemplates', '目标定义重复。');
        }
        resolved.add({
          ...r,
          'targetTemplates': [
            for (final target in targets.cast<String>())
              templatePackageTypeId(
                target.split('/').first,
                target.split('/').last,
              ),
          ],
        });
      }
      final sections = _list(t['sections'], '$p.sections', 40);
      for (final (n, rawSection) in sections.indexed) {
        final path = '$p.sections[$n]', s = _map(rawSection, path);
        final kind = _text(s, 'kind', path, max: 32);
        _text(s, 'title', path, max: 160);
        if (kind == 'fields') {
          _keys(s, {'kind', 'title', 'keys'}, path);
          final keys = _list(s['keys'], '$path.keys', 40);
          if (keys.any(
                (key) => key is! String || !fieldKinds.containsKey(key),
              ) ||
              keys.toSet().length != keys.length) {
            _fail('$path.keys', '字段引用不存在或重复。');
          }
        } else if ({'text', 'timeline', 'relations'}.contains(kind)) {
          _keys(s, {
            'kind',
            'title',
            'key',
            if (kind == 'text') 'formatKey',
          }, path);
          if (s.containsKey('formatKey')) {
            final formatKey = _identifier(s, 'formatKey', path);
            if (fieldKinds[formatKey] != 'text') {
              _fail('$path.formatKey', '正文格式需引用一个文本字段。');
            }
          }
          final field = _identifier(s, 'key', path);
          if (kind == 'relations'
              ? !relationKeys.contains(field)
              : !fieldKinds.containsKey(field) ||
                    (kind == 'timeline'
                        ? fieldKinds[field] != 'entries'
                        : fieldKinds[field] == 'entries')) {
            _fail('$path.key', '章节引用不存在或与内容形态不符。');
          }
        } else {
          _fail('$path.kind', '仅支持fields、text、timeline、relations布局。');
        }
      }
      final instructions = _text(
        t,
        'instructions',
        p,
        max: maxBytes,
        empty: true,
      );
      if (utf8.encode(instructions).length > 16 * 1024) {
        _fail('$p.instructions', '录入说明不能超过16 KiB。');
      }
      if (t['example'] != null) {
        final example = _map(t['example'], '$p.example');
        _keys(example, {'name', 'summary', 'values'}, '$p.example');
        _text(example, 'name', '$p.example', max: 160);
        _text(example, 'summary', '$p.example', max: 2000, empty: true);
        final values = _map(example['values'], '$p.example.values');
        for (final entry in values.entries) {
          if (!fieldKinds.containsKey(entry.key)) {
            _fail('$p.example.values.${entry.key}', '样例字段没有定义。');
          }
          if (fieldKinds[entry.key] != 'entries' && entry.value is! String) {
            _fail('$p.example.values.${entry.key}', '标量样例需要字符串。');
          }
          if (fieldKinds[entry.key] == 'entries') {
            for (final value in _list(
              entry.value,
              '$p.example.values.${entry.key}',
              100,
            )) {
              final row = _map(value, '$p.example.values.${entry.key}');
              _keys(row, {
                'title',
                'period',
                'detail',
              }, '$p.example.values.${entry.key}');
              for (final leaf in ['title', 'period', 'detail']) {
                _text(
                  row,
                  leaf,
                  '$p.example.values.${entry.key}',
                  max: 2000,
                  empty: true,
                );
              }
            }
          }
        }
      }
      templates.add(
        TemplatePackageTemplate(
          id: key,
          type: TemplatePackageType(templatePackageTypeId(id, key), name, icon),
          definition: {
            ...t,
            'relations': resolved,
            'packageId': id,
            'templateVersion': version,
            'packageDigest': sha256.convert(bytes).toString(),
          },
        ),
      );
    }
    return TemplatePackageDefinition(
      id: id,
      name: _text(package, 'name', r'$', max: 160),
      version: version,
      author: _text(package, 'author', r'$', max: 160),
      description: _text(package, 'description', r'$', max: 2000, empty: true),
      digest: sha256.convert(bytes).toString(),
      origin: origin,
      templates: templates,
    );
  }

  static Map<String, Object?> _map(Object? value, String path) {
    if (value is! Map<String, dynamic>) _fail(path, '需要JSON对象。');
    return value;
  }

  static void _keys(
    Map<String, Object?> value,
    Set<String> allowed,
    String path,
  ) {
    for (final key in value.keys) {
      if (!allowed.contains(key)) {
        _fail('$path.$key', '未知属性，不会加载脚本、路径、远端资源或设置代码。');
      }
    }
  }

  static String _text(
    Map<String, Object?> value,
    String key,
    String path, {
    required int max,
    bool empty = false,
  }) {
    final text = value[key];
    if (text is! String ||
        text.length > max ||
        (!empty && text.trim().isEmpty)) {
      _fail('$path.$key', '需要${empty ? '0' : '1'}–$max字的文本。');
    }
    return text;
  }

  static String _identifier(
    Map<String, Object?> value,
    String key,
    String path,
  ) {
    final text = _text(value, key, path, max: 64);
    if (!RegExp(r'^[a-z][a-zA-Z0-9_-]*$').hasMatch(text)) {
      _fail('$path.$key', '身份须以小写字母开头，其后仅含字母、数字、下划线或连字符。');
    }
    return text;
  }

  static List<Object?> _list(
    Object? value,
    String path,
    int max, {
    bool nonempty = false,
  }) {
    if (value is! List || value.length > max || (nonempty && value.isEmpty)) {
      _fail(path, '需要${nonempty ? 1 : 0}–$max项的列表。');
    }
    return value;
  }
}

/// Scan before decoding so duplicate keys (including escaped aliases) cannot
/// silently overwrite definitions; recursion is bounded independently of bytes.
class _JsonShape {
  _JsonShape(this.text);
  final String text;
  int i = 0;
  Never bad(String path, String message) =>
      DeclarativeTemplatePackageDecoder._fail(path, message);
  void space() {
    while (i < text.length && ' \t\r\n'.contains(text[i])) {
      i++;
    }
  }

  void check() {
    value(r'$', 0);
    space();
    if (i != text.length) bad(r'$', 'JSON末尾有多余内容。');
  }

  String string(String path) {
    space();
    if (i >= text.length || text[i] != '"') bad(path, '需要JSON字符串。');
    final start = i++;
    while (i < text.length) {
      final c = text[i++];
      if (c == '\\') {
        if (i < text.length) i++;
      } else if (c == '"') {
        try {
          return jsonDecode(text.substring(start, i)) as String;
        } on FormatException {
          bad(path, '无效的JSON字符串。');
        }
      }
    }
    bad(path, 'JSON字符串未结束。');
  }

  void take(String expected, String path) {
    space();
    if (i >= text.length || text[i++] != expected) bad(path, 'JSON语法错误。');
  }

  void value(String path, int depth) {
    space();
    if (i >= text.length) bad(path, 'JSON内容不完整。');
    final c = text[i];
    if (c == '{' || c == '[') {
      if (depth >= DeclarativeTemplatePackageDecoder.maxDepth) {
        bad(path, 'JSON嵌套不能超过16层。');
      }
      i++;
      space();
      final close = c == '{' ? '}' : ']';
      if (i < text.length && text[i] == close) {
        i++;
        return;
      }
      final keys = <String>{};
      var n = 0;
      while (true) {
        String next;
        if (c == '{') {
          final key = string(path);
          if (!keys.add(key)) bad('$path.$key', 'JSON键重复。');
          take(':', path);
          next = '$path.$key';
        } else {
          next = '$path[${n++}]';
        }
        value(next, depth + 1);
        space();
        if (i < text.length && text[i] == close) {
          i++;
          return;
        }
        take(',', path);
      }
    } else if (c == '"') {
      string(path);
    } else {
      final start = i;
      while (i < text.length && !' \t\r\n,]}'.contains(text[i])) {
        i++;
      }
      try {
        final v = jsonDecode(text.substring(start, i));
        if (v is Map || v is List || v is String) bad(path, '无效的JSON值。');
      } on FormatException {
        bad(path, '无效的JSON值。');
      }
    }
  }
}
