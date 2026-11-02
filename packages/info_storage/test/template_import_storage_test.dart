import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'storage_test.dart' show TestKeyStore;

void main() {
  test(
    'typed pending snapshots promote the durable format before older readers can flatten them',
    () async {
      final directory = await Directory.systemTemp.createTemp('typed-pending-');
      final keys = TestKeyStore();
      var repo = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      var service = InformationService(repository: repo);
      void configure() => service.owner.configureInformationTemplates(
        () => InformationTemplateCatalog(
          version: 1,
          plugins: [],
          templates: [
            InformationTemplateDescription(
              id: 'notes',
              name: '说明',
              version: '1',
              digest: 'a' * 64,
              enabled: true,
              definition: {
                'id': 'notes',
                'name': '说明',
                'fields': [
                  {'key': 'body', 'label': '正文', 'type': 'text'},
                ],
                'sections': [],
                'relations': [],
                'instructions': '填写说明正文。',
                'example': {
                  'name': '示例',
                  'values': {'body': '虚构说明'},
                },
              },
            ),
          ],
        ),
      );
      configure();
      final session = service.agent.openSession('合成测试');
      await service.agent.submitImport(session, [
        ImportItemInput(
          '合成说明',
          '',
          [],
          templateId: 'notes',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-TYPED-VALUE'},
        ),
      ]);
      await service.close();
      await repo.close();
      final db = sqlite3.open('${directory.path}/library.db');
      try {
        final hex = keys.key!
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        expect(db.select('PRAGMA user_version').single.values.single, 42);
        expect(
          db.select('SELECT version FROM library_format').single['version'],
          42,
        );
      } finally {
        db.close();
      }
      repo = await EncryptedInformationRepository.open(directory.path, keys);
      service = InformationService(repository: repo);
      configure();
      final proposal = service.owner.importProposals.single;
      expect(proposal.items.single.layout!.typeId, 'notes');
      await service.owner.confirmImport(
        proposal.id,
        proposal.version,
        proposal.items,
      );
      expect(
        service.owner.information.single.fields.single.value,
        'PRIVATE-TYPED-VALUE',
      );
      await service.close();
      await repo.close();
      for (final file in directory.listSync().whereType<File>()) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('PRIVATE-TYPED-VALUE')),
        );
      }
      await directory.delete(recursive: true);
    },
  );
}
