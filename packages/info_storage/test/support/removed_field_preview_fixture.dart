// SDK setup for a disposable actual-release history display check. The delete
// and restore below are fixture setup, never evidence of a GUI delete action.
import 'dart:convert';
import 'dart:io';

import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1)
    throw StateError('Explicit new synthetic root required');
  final root = Directory(args.single);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-removed-field-preview-') ||
      !await root.list().isEmpty) {
    throw StateError('Not a new owned preview fixture');
  }
  final directory = '${root.path}/profile/AgentInfoManage';
  final repo = await EncryptedInformationRepository.open(
    directory,
    WindowsDatabaseKeyStore('$directory/database-key.dpapi'),
  );
  final service = InformationService(repository: repo);
  try {
    await service.owner.setNotificationsEnabled(false);
    final input = File('${root.path}/synthetic-resume.txt');
    await input.writeAsString('仅供新版历史状态显示检查的虚构简历。');
    final draft = await service.owner.beginInformationFileDraft();
    late InformationItem item;
    try {
      final staged = await service.owner.stageInformationFile(
        draft,
        input.path,
      );
      item = await service.owner.commitInformationDraft(
        draft,
        'removed-field-preview',
        InformationDraftInput(
          name: '虚构状态复验简历',
          description: '只检查实际发行界面的旧范围名称与失效提示',
          fields: [
            InformationDraftField.stagedFile('简历文件', '合成普通附件', staged.id),
          ],
        ),
      );
    } finally {
      await service.owner.releaseInformationFileDraft(draft);
    }
    final field = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('虚构历史状态复验');
    final request = service.agent.request(session, '检查已移除字段的显示', [field]);
    service.owner.approve(request.id, [field]);
    final entry = await service.owner.deleteInformation(item.id, item.version);
    final restored = await service.owner.restoreRecycled(entry.id);
    if (restored.fields.single.id == field.fieldId ||
        service.owner.canReadGrantedField(repo.grantHistory.single, field)) {
      throw StateError('Fixture did not invalidate the original field');
    }
    final proof = {
      'fixtureOnly': true,
      'itemIdentityPreserved': item.id == restored.id,
      'fieldIdentityChanged': field.fieldId != restored.fields.single.id,
      'itemVersion': restored.version,
      'historyCount': repo.grantHistory.length,
      'recordedName': repo.grantHistory.single.fields.single.fieldName,
      'oldScopeReadable': false,
      'bytes': await input.length(),
    };
    await File('${root.path}/expected.json').writeAsString(jsonEncode(proof));
    stdout.writeln(jsonEncode(proof));
  } finally {
    await service.close();
    await repo.close();
  }
}
