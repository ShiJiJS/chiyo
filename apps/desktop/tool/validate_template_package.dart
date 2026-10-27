import 'dart:convert';
import 'dart:io';
import 'package:info_desktop/workspace/template_package_decoder.dart';
import 'package:info_desktop/workspace/workspace_records.dart';

/// Read-only developer entry; never constructs an owner, repository or UI.
Future<void> main(List<String> args) async {
  final known = <String>{};
  String? path;
  void report(Map<String, Object?> value, int status) {
    stdout.writeln(jsonEncode(value));
    exitCode = status;
  }

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--known-template' && i + 1 < args.length) {
      known.add(args[++i]);
    } else if (args[i].startsWith('-') || path != null) {
      report({
        'valid': false,
        'code': 'usage',
        'message':
            '使用：validate_template_package.dart [--known-template 包ID/模板ID] 文件.json',
      }, 64);
      return;
    } else {
      path = args[i];
    }
  }
  if (path == null) {
    report({
      'valid': false,
      'code': 'usage',
      'message': '请指定一个待校验的JSON文件。',
    }, 64);
    return;
  }
  try {
    final file = File(path);
    if (await file.length() > TemplatePackageDecoder.maxBytes) {
      report({
        'valid': false,
        'code': 'invalid_package',
        'errors': {r'$': '包不能超过1 MiB。'},
      }, 2);
      return;
    }
    final input = await file.open();
    late List<int> bytes;
    try {
      bytes = await input.read(TemplatePackageDecoder.maxBytes + 1);
    } finally {
      await input.close();
    }
    final package = TemplatePackageDecoder().decode(
      bytes,
      origin: file.uri.pathSegments.last,
      knownTemplates: known,
    );
    report({
      'valid': true,
      'id': package.id,
      'version': package.version,
      'sha256': package.digest,
      'templates': [
        for (final t in package.templates)
          {
            'id': '${package.id}/${t.id}',
            'fields': (t.definition['fields'] as List).length,
          },
      ],
      'referenceContext': known.toList(),
      'installed': false,
    }, 0);
  } on WorkspaceFailure catch (e) {
    report({'valid': false, 'code': e.code, 'errors': e.fieldErrors}, 2);
  } on Object {
    report({
      'valid': false,
      'code': 'input_unavailable',
      'message': '无法读取指定文件，请检查输入。',
    }, 2);
  }
}
