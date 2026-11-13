import 'dart:io';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'backup_setup.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'delete submission identity is encrypted, upgrades only when used, survives reopen and stays out of portable chat recovery',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'delete-submit-storage-',
      );
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/source',
        keys,
      );
      var runtime = await OnlineInformationRuntime.open(repository: repo);
      addTearDown(() async {
        await runtime.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      int format() {
        final db = sqlite.sqlite3.open('${root.path}/source/library.db');
        try {
          final hex = keys.key!
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          return db.select('PRAGMA user_version').single.values.single as int;
        } finally {
          db.close();
        }
      }

      final item = await runtime.run(
        () => runtime.service.owner.createInformation('Synthetic item', '', [
          const FieldInput('Value', '', 'PRIVATE-EXISTING'),
        ]),
      );
      final session = await runtime.run(
        () => runtime.service.agent.openSession('Synthetic delete storage'),
      );
      final initialFormat = format();
      await runtime.run(
        () => runtime.service.agent.submitDelete(session, item.id, 1),
      );
      expect(format(), initialFormat);
      Future<String> submit() => runtime.run(
        () => runtime.service.agent.submitDelete(
          session,
          item.id,
          1,
          title: 'Remove synthetic item',
          purpose: 'Storage test',
          operationId: 'delete-stored-once',
        ),
      );
      final id = await submit();
      expect(format(), 68);
      await runtime.close();
      await repo.close();
      repo = await EncryptedInformationRepository.openOnline(
        '${root.path}/source',
        keys,
      );
      runtime = await OnlineInformationRuntime.open(repository: repo);
      expect(
        runtime.service.agent.deleteStatusByOperation(
          session,
          'delete-stored-once',
        )['proposalId'],
        id,
      );
      expect(await submit(), id);
      expect(repo.deleteProposals, hasLength(2));
      await runtime.run(() => runtime.service.owner.confirmDelete(id, 1));
      expect(await submit(), id);
      expect(repo.recycleEntries, hasLength(1));
      expect(
        repo.deleteProposals
            .singleWhere((p) => p.id == id)
            .hasValidSubmissionIdentity,
        true,
      );
      final backupKey = await enableTestBackups(repo.backups);
      final archive = '${root.path}/backup.aimbackup';
      await runtime.run(
        () => runtime.service.owner.exportLibrary(
          () => repo.backups.exportTo(archive),
        ),
      );
      final target = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      final restored = InformationService(repository: target);
      try {
        await restored.owner.restoreLibrary(
          () => target.backups.restoreFrom(archive, backupKey),
        );
        expect(restored.owner.deleteProposals, isEmpty);
        expect(
          () => restored.agent.deleteStatusByOperation(
            session,
            'delete-stored-once',
          ),
          throwsA(isA<AccessFailure>()),
        );
      } finally {
        await restored.close();
        await target.close();
      }
      expect(
        latin1.decode(
          await File('${root.path}/source/library.db').readAsBytes(),
        ),
        isNot(contains('PRIVATE-EXISTING')),
      );
    },
  );
}
