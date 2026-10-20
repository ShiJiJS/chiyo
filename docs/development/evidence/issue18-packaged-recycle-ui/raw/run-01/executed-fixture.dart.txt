// Disposable Owner-created attachment; never opens the user's actual library.
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2 || !{'prepare', 'inspect'}.contains(args.first)) {
    throw StateError('Explicit synthetic recycle action required');
  }
  final root = Directory(args[1]);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (root.absolute.path.toLowerCase() != actual.toLowerCase() ||
      !actual.toLowerCase().startsWith(
        '$temp${Platform.pathSeparator}'.toLowerCase(),
      ) ||
      !root.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .last
          .startsWith('aim-packaged-recycle-ui-')) {
    throw StateError('Not an owned synthetic recycle fixture');
  }
  if (args.first == 'prepare' && !await root.list().isEmpty) {
    throw StateError('Fixture is not new');
  }
  final directory = '${root.path}/profile/AgentInfoManage';
  final repo = await EncryptedInformationRepository.open(
    directory,
    WindowsDatabaseKeyStore('$directory/database-key.dpapi'),
  );
  final service = InformationService(repository: repo);
  try {
    if (args.first == 'prepare') {
      await service.owner.setNotificationsEnabled(false);
      final input = File('${root.path}/synthetic-resume.txt');
      await input.writeAsString('虚构简历，仅用于最终Windows发行包回收与恢复界面验收。');
      final draft = await service.owner.beginInformationFileDraft();
      late InformationItem item;
      try {
        final staged = await service.owner.stageInformationFile(
          draft,
          input.path,
        );
        item = await service.owner.commitInformationDraft(
          draft,
          'synthetic-recycle',
          InformationDraftInput(
            name: '虚构回收验收简历',
            description: '专属临时库，没有真实个人资料',
            fields: [
              InformationDraftField.stagedFile('简历文件', '合成普通附件', staged.id),
            ],
          ),
        );
      } finally {
        await service.owner.releaseInformationFileDraft(draft);
      }
      // Fixture setup only. Actual package UI must perform restore; this is
      // explicitly not evidence of package UI deletion.
      final entry = await service.owner.deleteInformation(
        item.id,
        item.version,
      );
      await File('${root.path}/expected.json').writeAsString(
        jsonEncode({
          'itemId': item.id,
          'oldFieldId': item.fields.single.id,
          'attachment': item.fields.single.attachment!.toJson(),
          'entryId': entry.id,
          'bytes': await input.length(),
        }),
      );
      stdout.writeln(
        jsonEncode({'status': 'prepared', 'bytes': await input.length()}),
      );
    } else {
      final expected =
          jsonDecode(await File('${root.path}/expected.json').readAsString())
              as Map<String, dynamic>;
      final item = repo.items.single;
      final ref = item.fields.single.attachment!;
      final bytes = await File(
        '${root.path}/synthetic-resume.txt',
      ).readAsBytes();
      final actual = await repo.readInformationAttachmentChunk(
        ref,
        0,
        bytes.length,
      );
      stdout.writeln(
        jsonEncode({
          'status': 'inspected',
          'information': repo.items.length,
          'itemIdentityPreserved': item.id == expected['itemId'],
          'fieldIdentityChanged':
              item.fields.single.id != expected['oldFieldId'],
          'attachmentIdentityPreserved':
              ref ==
              InformationAttachmentRef.fromJson(
                expected['attachment'] as Map<String, dynamic>,
              ),
          'originalMatches':
              actual.length == bytes.length &&
              List.generate(
                bytes.length,
                (i) => actual[i] == bytes[i],
              ).every((v) => v),
          'itemVersion': item.version,
          'availableRecycle': service.owner.recycleEntries.length,
          'restoredRecycle': repo.recycleEntries
              .where((e) => e.state == RecycleState.restored)
              .length,
          'deletionFacts': repo.recycleFacts
              .where((f) => f.kind == RecycleFactKind.deleted)
              .length,
          'restoreFacts': repo.recycleFacts
              .where((f) => f.kind == RecycleFactKind.restored)
              .length,
          'deliveries': repo.informationFileDeliveries.length,
          'noHeldCopies': repo.informationFileDeliveries.every(
            (d) => !d.holdsCopy,
          ),
          'activeGrants': repo.grantHistory.where((g) => g.active).length,
        }),
      );
    }
  } finally {
    await service.close();
    await repo.close();
  }
}
