import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../../info_core/test/fixtures/legacy_attachment_fixture.dart';
import 'storage_test.dart' show TestKeyStore;
import 'backup_setup.dart';

void main() {
  test(
    'separation rolls back as a whole and preserves original versions across reopen and backup',
    () async {
      final root = await Directory.systemTemp.createTemp('separate-sql-');
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      var service = InformationService(repository: repo);
      addTearDown(() async {
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
      final original = await createLegacyAttachment(service, repo);
      final originalField = original.fields.first;
      void sql(String query) {
        final db = sqlite3.open('${root.path}/data/library.db');
        try {
          final hex = keys.key!
              .map((v) => v.toRadixString(16).padLeft(2, '0'))
              .join();
          db.execute('PRAGMA key = "x\'$hex\'"');
          db.execute(query);
        } finally {
          db.close();
        }
      }

      Future<InformationRecordReceipt> separate() =>
          service.owner.separateInformationAttachment(
            operationId: 'separate-sql',
            itemId: original.id,
            expectedVersion: original.version,
            fieldId: originalField.id,
            name: '独立原件',
            templateId: 'file',
          );
      sql(
        "CREATE TRIGGER fail_separation BEFORE INSERT ON information_record_operations BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END",
      );
      await expectLater(separate(), throwsA(anything));
      expect(repo.items.length, 1);
      expect(repo.items.single.fields.length, 2);
      expect(await repo.informationRecordReceipt('separate-sql'), isNull);
      sql('DROP TRIGGER fail_separation');
      final receipt = await separate();
      expect(repo.items.length, 2);
      await service.close();
      await repo.close();
      repo = await EncryptedInformationRepository.open(
        '${root.path}/data',
        keys,
      );
      service = InformationService(repository: repo);
      // A retry after restart reconciles without a current template or old field.
      expect((await separate()).toJson(), receipt.toJson());
      final file = repo.items.singleWhere((i) => i.id == receipt.itemId);
      expect(file.fields.single.attachment, originalField.attachment);
      expect(
        repo.items.singleWhere((i) => i.id == original.id).fields.single.value,
        '重要事实',
      );
      final versions = await repo.informationAttachmentVersions(
        originalField.attachment!.attachmentId,
      );
      expect(versions.length, 2);
      final key = await enableTestBackups(repo.backups);
      final path = '${root.path}/complete.aim';
      await repo.backups.exportTo(path);
      final restored = await EncryptedInformationRepository.open(
        '${root.path}/restored',
        TestKeyStore(),
      );
      try {
        await restored.backups.restore(
          await restored.backups.inspect(path, key),
        );
        expect(restored.items.length, 2);
        expect(
          (await restored.informationAttachmentVersions(
            originalField.attachment!.attachmentId,
          )).length,
          2,
        );
        for (var n = 0; n < 2; n++) {
          expect(
            await restored.readInformationAttachmentChunk(
              versions[n].reference,
              0,
              versions[n].byteLength,
            ),
            utf8.encode('原文$n'),
          );
        }
        expect(
          restored.items
              .singleWhere((i) => i.id == receipt.itemId)
              .layout!
              .relations['related']!
              .single
              .id,
          original.id,
        );
      } finally {
        await restored.close();
      }
    },
  );
}
