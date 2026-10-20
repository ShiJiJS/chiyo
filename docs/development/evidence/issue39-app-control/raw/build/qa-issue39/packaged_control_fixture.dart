import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<void> main(List<String> args) async {
  final root = Directory(args[1]);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith('$temp${Platform.pathSeparator}'.toLowerCase()) ||
      !root.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('aim-app-control-')) {
    throw StateError('Not an owned synthetic control fixture');
  }
  if (args.first == 'prepare') {
    if (!await root.list().isEmpty) throw StateError('Fixture is not empty');
    final records = <String, Object?>{};
    for (final name in ['normal', 'missing-key']) {
      final dir = '${root.path}/$name/AgentInfoManage';
      final keyFile = '$dir/database-key.dpapi';
      final repo = await EncryptedInformationRepository.open(dir, WindowsDatabaseKeyStore(keyFile));
      final service = InformationService(repository: repo);
      try {
        await service.owner.setNotificationsEnabled(false);
        final server = await service.owner.createInformation('北辰测试服务器', '虚构资料，仅用于新整包验收', const [
          FieldInput('访问地址', '公开说明', 'https://synthetic.example.invalid'),
          FieldInput('维护账号', '待单独批准的字段', 'fictional-developer'),
        ]);
        final source = File('${root.path}/fictional-resume.txt');
        await source.writeAsString('这是一份虚构简历，仅用于新整包文件交付验收。');
        final draft = await service.owner.beginInformationFileDraft();
        final staged = await service.owner.stageInformationFile(draft, source.path);
        final document = await service.owner.commitInformationDraft(draft, 'save', InformationDraftInput(
          name: '虚构个人简历', description: '普通附件流程，不是真实个人资料',
          fields: [InformationDraftField.stagedFile('简历文件', '允许读取原文的普通文件', staged.id)],
        ));
        await service.owner.releaseInformationFileDraft(draft);
        await service.owner.createStringCredential(name: '虚构 GitHub Token', publicPurpose: '界面展示用，无外部权限', secret: 'SYNTHETIC_NOT_A_REAL_TOKEN', suggestedBinding: 'GH_TOKEN');
        if (name == 'normal') records.addAll({
          'serverId': server.id, 'addressField': server.fields[0].id, 'accountField': server.fields[1].id,
          'documentId': document.id, 'documentField': document.fields.single.id,
          'documentBytes': await source.length(),
        });
      } finally { await service.close(); await repo.close(); }
      if (name == 'missing-key') await File(keyFile).delete();
    }
    final failedDb = File('${root.path}/missing-key/AgentInfoManage/library.db');
    records['failedDbSha256'] = sha256.convert(await failedDb.readAsBytes()).toString();
    await File('${root.path}/fixture.json').writeAsString(jsonEncode(records));
    stdout.writeln('{"status":"prepared"}');
  } else if (args.first == 'inspect') {
    final dir = '${root.path}/normal/AgentInfoManage';
    final repo = await EncryptedInformationRepository.open(dir, WindowsDatabaseKeyStore('$dir/database-key.dpapi'));
    final service = InformationService(repository: repo);
    try {
      final history = await service.owner.history();
      stdout.writeln(jsonEncode({
        'status':'inspected', 'grants':history.grants.length,
        'allClosed':history.grants.isNotEmpty && history.grants.every((g) => !g.active && g.events.last.kind == GrantEventKind.applicationClosed),
        'successfulReads':history.accesses.where((a) => a.outcome == AccessOutcome.allowed).length,
        'items':service.owner.information.length,
      }));
    } finally { await service.close(); await repo.close(); }
  } else if (args.first == 'lock') {
    final dir = '${root.path}/normal/AgentInfoManage';
    final key = await WindowsDatabaseKeyStore('$dir/database-key.dpapi').read();
    final db = sqlite.sqlite3.open('$dir/library.db');
    try {
      final hex = key!.map((n)=>n.toRadixString(16).padLeft(2,'0')).join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute('BEGIN IMMEDIATE');
      key.fillRange(0,key.length,0);
      stdout.writeln('{"status":"locked"}'); await stdout.flush();
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
      db.execute('ROLLBACK');
    } finally { key?.fillRange(0,key.length,0); db.close(); }
  } else { throw StateError('Invalid action'); }
}
