part of 'chiyo_cli.dart';

extension _ChiyoRequestTemplates on ChiyoCli {
  Future<ChiyoRunResult> _requestTemplate(ChiyoInvocation i) async {
    final kind = i.path.split(' ').first;
    final via = kind == 'ssh' ? '' : i.options['via'] as String;
    final template = chiyoRequestTemplate(kind, via);
    final destination = i.options['out'] as String?;
    if (destination == null) {
      return _success({'status': 'ok', 'kind': kind, 'template': template}, i);
    }
    final file = File(destination).absolute;
    Directory? staging;
    try {
      await file.parent.create(recursive: true);
      staging = await file.parent.createTemp('.chiyo-template-');
      final prepared = File('${staging.path}/request.json');
      await prepared.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(template)}\n',
        flush: true,
      );
      file_publication.publishNewFile(prepared.path, file.path);
    } on FileSystemException {
      throw const ChiyoUsageFailure('无法写入模板；请检查目录，并使用尚不存在的文件名。现有文件不会被覆盖。');
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
    return _success({
      'status': 'ok',
      'kind': kind,
      'path': file.path,
      'next': '填写 title、summary 和实际参数，再使用 chiyo $kind request --input 提交。',
    }, i);
  }
}
