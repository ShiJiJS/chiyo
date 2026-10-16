import 'dart:io';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  test(
    'Windows recovery works with fresh DPAPI key after original envelope is gone',
    () async {
      final root = await Directory.systemTemp.createTemp('info-backup-dpapi-');
      addTearDown(() => root.delete(recursive: true));
      final originalKeys = WindowsDatabaseKeyStore(
        '${root.path}/original/key.dpapi',
      );
      final source = await EncryptedInformationRepository.open(
        '${root.path}/original',
        originalKeys,
      );
      await InformationService(repository: source).owner.createInformation(
        'Fictional independent',
        '',
        [const FieldInput('Value', '', 'FICTIONAL-DPAPI-BACKUP-41232')],
      );
      final originalKey = await originalKeys.read();
      final recovery = await source.backups.enable();
      final backup = '${root.path}/independent.aimbackup';
      await source.backups.exportTo(backup);
      await source.close();
      await File(originalKeys.path).delete();
      expect(await originalKeys.read(), isNull);
      final freshKeys = WindowsDatabaseKeyStore('${root.path}/fresh/key.dpapi');
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/fresh',
        freshKeys,
      );
      await recipient.backups.restoreFrom(backup, recovery);
      expect(await freshKeys.read(), isNot(originalKey));
      expect(
        recipient.items.single.fields.single.value,
        'FICTIONAL-DPAPI-BACKUP-41232',
      );
      await recipient.close();
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('FICTIONAL-DPAPI-BACKUP-41232')),
        );
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'independent recovery key restores current information without live access',
    () async {
      final root = await Directory.systemTemp.createTemp('info-backup-');
      addTearDown(() => root.delete(recursive: true));
      final sourceKeys = _Keys();
      var source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
      );
      final ownerService = InformationService(repository: source);
      final item = await ownerService.owner
          .createInformation('Fictional server', 'Public', [
            const FieldInput(
              'Notes',
              '',
              'BACKUP-FICTIONAL-CONTENT-12921',
              kind: FieldKind.textNote,
            ),
          ]);
      await ownerService.owner.correctValue(
        FieldRef(item.id, item.fields.single.id),
        'BACKUP-FICTIONAL-CORRECTED-12921',
      );
      await ownerService.owner.setRequestLifetime(const Duration(minutes: 45));
      final child = await ownerService.owner.createDirectory('Earlier child');
      final parent = await ownerService.owner.createDirectory('Later parent');
      await ownerService.owner.updateDirectory(
        child.id,
        child.name,
        parentId: parent.id,
      );
      final tag = await ownerService.owner.createTag('Fictional tag');
      await ownerService.owner.organizeInformation(
        item.id,
        directoryId: child.id,
        tagIds: [tag.id],
      );
      final template = await ownerService.owner.createTemplate(
        'Fictional template',
        'Public form aid',
        [
          const TemplateFieldInput(
            'Notes',
            'Controlled',
            kind: FieldKind.textNote,
          ),
        ],
      );
      final session = ownerService.agent.openSession('old chat');
      final ref = FieldRef(item.id, item.fields.single.id);
      final request = ownerService.agent.request(session, 'test', [ref]);
      ownerService.owner.approve(request.id, [ref]);
      final token = ownerService.agent.claim(session, request.id).token;
      await ownerService.agent.submitImport(session, [
        ImportItemInput('Unconfirmed', '', [
          const FieldInput('Private', '', 'FICTIONAL-PENDING-EXCLUDED'),
        ]),
      ]);
      ownerService.agent.request(session, 'still pending', [ref]);
      final recovery = await source.backups.enable();
      expect(
        base64Url.decode(recovery.substring('aim-recovery-v1:'.length)),
        isNot(sourceKeys.key),
      );
      final backup = '${root.path}/fictional.aimbackup';
      await source.backups.exportTo(backup);
      await source.close();
      source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        sourceKeys,
      );
      expect(await source.backups.recoveryKey(), recovery);
      await source.close();

      final recipientKeys = _Keys();
      var recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      expect(recipientKeys.key, isNot(sourceKeys.key));
      final summary = await recipient.backups.restoreFrom(backup, recovery);
      expect(summary.informationCount, 1);
      var restored = InformationService(repository: recipient);
      expect(restored.owner.information.single.id, item.id);
      expect(restored.owner.information.single.version, 3);
      expect(
        restored.owner.information.single.fields.single.value,
        'BACKUP-FICTIONAL-CORRECTED-12921',
      );
      expect(
        restored.owner.information.single.fields.single.kind,
        FieldKind.textNote,
      );
      expect(restored.owner.requestLifetime, const Duration(minutes: 45));
      expect(restored.owner.directories.first.parentId, parent.id);
      expect(restored.owner.directories.first.version, 2);
      expect(restored.owner.information.single.directoryId, child.id);
      expect(restored.owner.information.single.tagIds, [tag.id]);
      expect(restored.owner.templates.single.id, template.id);
      expect(
        restored.owner.templates.single.fields.single.kind,
        FieldKind.textNote,
      );
      expect(restored.owner.requests, isEmpty);
      expect(restored.owner.importProposals, isEmpty);
      await expectLater(
        () async => restored.agent.read(token, ref),
        throwsA(isA<AccessFailure>()),
      );
      expect(await recipient.backups.recoveryKey(), isNull);
      restored.close();
      await recipient.close();
      recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        recipientKeys,
      );
      restored = InformationService(repository: recipient);
      expect(restored.owner.information.single.fields.single.version, 2);
      restored.close();
      await recipient.close();
      for (final file in root.listSync(recursive: true).whereType<File>()) {
        final content = String.fromCharCodes(file.readAsBytesSync());
        expect(content, isNot(contains('BACKUP-FICTIONAL-CORRECTED-12921')));
        expect(content, isNot(contains(recovery)));
        expect(content, isNot(contains(token)));
      }
    },
  );

  test(
    'wrong key and nonempty recipient preserve all existing information',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'info-backup-preserve-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      await InformationService(repository: source).owner.createInformation(
        'Backup source',
        '',
        [const FieldInput('Value', '', 'fictional source')],
      );
      final recovery = await source.backups.enable();
      final backup = '${root.path}/source.aimbackup';
      await source.backups.exportTo(backup);
      final before = File(backup).readAsBytesSync();
      await expectLater(
        source.backups.exportTo(backup),
        throwsA(
          isA<StorageFailure>().having((e) => e.code, 'code', 'output_exists'),
        ),
      );
      expect(File(backup).readAsBytesSync(), before);
      await source.close();
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        _Keys(),
      );
      addTearDown(recipient.close);
      final targetOwner = InformationService(repository: recipient).owner;
      await targetOwner.createInformation('Existing recipient', '', [
        const FieldInput('Value', '', 'fictional original'),
      ]);
      await targetOwner.setRequestLifetime(const Duration(minutes: 15));
      await expectLater(
        recipient.backups.restoreFrom(
          backup,
          'aim-recovery-v1:${base64Url.encode(List.filled(32, 7))}',
        ),
        throwsA(isA<StorageFailure>()),
      );
      await expectLater(
        recipient.backups.restoreFrom(backup, recovery),
        throwsA(
          isA<StorageFailure>().having(
            (e) => e.code,
            'code',
            'recipient_not_empty',
          ),
        ),
      );
      expect(
        targetOwner.information.single.fields.single.value,
        'fictional original',
      );
      expect(targetOwner.requestLifetime, const Duration(minutes: 15));
      expect(File(backup).readAsBytesSync(), before);
    },
  );

  test(
    'owner saves recovery key separately without overwriting an existing file',
    () async {
      final root = await Directory.systemTemp.createTemp('info-backup-key-');
      addTearDown(() => root.delete(recursive: true));
      final store = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      addTearDown(store.close);
      final recovery = await store.backups.enable();
      final path = '${root.path}/separate-recovery-key.txt';
      await store.backups.saveRecoveryKeyTo(path);
      expect(await File(path).readAsString(), '$recovery\n');
      await expectLater(
        store.backups.saveRecoveryKeyTo(path),
        throwsA(
          isA<StorageFailure>().having((e) => e.code, 'code', 'output_exists'),
        ),
      );
      expect(await File(path).readAsString(), '$recovery\n');
    },
  );

  test(
    'damaged, truncated and incompatible backups are rejected before recipient changes',
    () async {
      final root = await Directory.systemTemp.createTemp('info-backup-reject-');
      addTearDown(() => root.delete(recursive: true));
      final source = await EncryptedInformationRepository.open(
        '${root.path}/source',
        _Keys(),
      );
      await InformationService(repository: source).owner.createInformation(
        'Example',
        '',
        [const FieldInput('Value', '', 'fictional')],
      );
      final recovery = await source.backups.enable();
      final path = '${root.path}/good.aimbackup';
      await source.backups.exportTo(path);
      await source.close();
      final recipient = await EncryptedInformationRepository.open(
        '${root.path}/recipient',
        _Keys(),
      );
      addTearDown(recipient.close);
      final owner = InformationService(repository: recipient).owner;
      await owner.setRequestLifetime(const Duration(minutes: 15));
      final bytes = File(path).readAsBytesSync();
      final damaged = List<int>.of(bytes);
      damaged[damaged.length - 128] ^= 1;
      await File('${root.path}/damaged.aimbackup').writeAsBytes(damaged);
      await File(
        '${root.path}/truncated.aimbackup',
      ).writeAsBytes(bytes.sublist(0, bytes.length - 1));
      final unknown = '${root.path}/unknown.aimbackup';
      await File(path).copy(unknown);
      final db = sqlite3.open(unknown);
      final hex = base64Url
          .decode(recovery.substring('aim-recovery-v1:'.length))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      final payload =
          jsonDecode(
                db
                        .select('SELECT payload FROM backup_snapshot')
                        .single['payload']
                    as String,
              )
              as Map<String, dynamic>;
      payload['version'] = 99;
      db.execute('UPDATE backup_snapshot SET payload=?', [jsonEncode(payload)]);
      db.close();
      final malformed = '${root.path}/malformed.aimbackup';
      await File(path).copy(malformed);
      final malformedDb = sqlite3.open(malformed);
      malformedDb.execute('PRAGMA key = "x\'$hex\'"');
      payload['version'] = 1;
      (payload['tables']['information_fields'] as List).single['kind'] =
          'unknown';
      malformedDb.execute('UPDATE backup_snapshot SET payload=?', [
        jsonEncode(payload),
      ]);
      malformedDb.close();
      for (final file in ['damaged', 'truncated', 'unknown', 'malformed']) {
        await expectLater(
          recipient.backups.restoreFrom(
            '${root.path}/$file.aimbackup',
            recovery,
          ),
          throwsA(isA<StorageFailure>()),
        );
        expect(owner.information, isEmpty);
        expect(owner.requestLifetime, const Duration(minutes: 15));
      }
      expect(File(path).readAsBytesSync(), bytes);
    },
  );

  test('restore refuses a recipient with unconfirmed proposals', () async {
    final root = await Directory.systemTemp.createTemp(
      'backup-proposal-preserve-',
    );
    addTearDown(() => root.delete(recursive: true));
    final source = await EncryptedInformationRepository.open(
      '${root.path}/source',
      _Keys(),
    );
    final key = await source.backups.enable();
    final backup = '${root.path}/empty.aimbackup';
    await source.backups.exportTo(backup);
    await source.close();
    final target = await EncryptedInformationRepository.open(
      '${root.path}/recipient',
      _Keys(),
    );
    addTearDown(target.close);
    final service = InformationService(repository: target);
    final session = service.agent.openSession('fictional import');
    await service.agent.submitImport(session, [
      ImportItemInput('Unconfirmed', '', [
        const FieldInput('Value', '', 'fictional proposal'),
      ]),
    ]);
    await expectLater(
      target.backups.restoreFrom(backup, key),
      throwsA(
        isA<StorageFailure>().having(
          (e) => e.code,
          'code',
          'recipient_not_empty',
        ),
      ),
    );
    expect(
      service.owner.importProposals.single.items.single.name,
      'Unconfirmed',
    );
    expect(service.owner.information, isEmpty);
  });
}
