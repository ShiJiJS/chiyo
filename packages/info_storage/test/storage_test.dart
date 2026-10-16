import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';

class TestKeyStore implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

void main() {
  test(
    'encrypted catalog organization and reviewed descriptions survive reopening',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'info-organization-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      final directory = await service.owner.createDirectory(
        'PRIVATE-ORGANIZATION-34982',
      );
      final child = await service.owner.createDirectory(
        'Child',
        parentId: directory.id,
      );
      final tag = await service.owner.createTag('PRIVATE-TAG-34982');
      final item = await service.owner.createInformation('Original', 'Public', [
        const FieldInput('Host', 'Address', 'fictional.invalid'),
      ]);
      await service.owner.organizeInformation(
        item.id,
        directoryId: child.id,
        tagIds: [tag.id],
      );
      await service.owner.updateCatalogMetadata(
        item.id,
        name: 'Reviewed',
        description: 'New public description',
        fieldDescriptions: {item.fields.single.id: 'Reviewed host'},
      );
      await service.owner.updateDirectory(
        directory.id,
        'PRIVATE-RENAMED-34982',
      );
      await service.owner.updateTag(tag.id, 'PRIVATE-RENAMED-TAG-34982');
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store);
      addTearDown(service.close);
      expect(service.owner.directories.first.id, directory.id);
      expect(service.owner.directories.first.version, 2);
      expect(service.owner.directories.last.parentId, directory.id);
      expect(service.owner.tags.single.id, tag.id);
      expect(service.owner.tags.single.version, 2);
      expect(service.owner.information.single.directoryId, child.id);
      expect(service.owner.information.single.tagIds, [tag.id]);
      expect(service.owner.information.single.version, 3);
      expect(
        service.agent
            .searchCatalog(
              query: 'Reviewed host',
              directoryId: directory.id,
              tagId: tag.id,
            )
            .items
            .single['name'],
        'Reviewed',
      );
      for (final file in folder.listSync().whereType<File>().where(
        (file) => !file.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('PRIVATE-')),
        );
      }
    },
  );
  test('encrypted schema v1 migrates once and settings survive reopening', () async {
    final directory = await Directory.systemTemp.createTemp(
      'info-migration-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final keys = TestKeyStore()..key = List.filled(32, 17);
    final fixture = sqlite3.open('${directory.path}/library.db');
    fixture.execute('PRAGMA key = "x\'${'11' * 32}\'"');
    fixture.execute(
      'CREATE TABLE information_items(id TEXT PRIMARY KEY,name TEXT NOT NULL,description TEXT NOT NULL)',
    );
    fixture.execute(
      'CREATE TABLE information_fields(id TEXT PRIMARY KEY,item_id TEXT NOT NULL,name TEXT NOT NULL,description TEXT NOT NULL,value TEXT NOT NULL)',
    );
    fixture.execute(
      "INSERT INTO information_items VALUES('item-1','Old item','description')",
    );
    fixture.execute(
      "INSERT INTO information_fields VALUES('field-1','item-1','Old field','description','fictional old content')",
    );
    fixture.execute('PRAGMA user_version = 1');
    fixture.close();
    var store = await EncryptedInformationRepository.open(directory.path, keys);
    final service = InformationService(repository: store);
    expect(service.owner.information.single.version, 1);
    await service.owner.correctValue(
      const FieldRef('item-1', 'field-1'),
      'fictional corrected',
    );
    await service.owner.setRequestLifetime(const Duration(minutes: 45));
    await store.close();
    store = await EncryptedInformationRepository.open(directory.path, keys);
    expect(
      InformationService(
        repository: store,
      ).owner.information.single.fields.single.version,
      2,
    );
    expect(
      InformationService(repository: store).owner.requestLifetime,
      const Duration(minutes: 45),
    );
    await store.close();
  });
  test(
    'encrypted owner information reopens but previous grants do not',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'info-storage-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final keys = TestKeyStore();
      var store = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      var service = InformationService(repository: store);
      final item = await service.owner.createInformation(
        'Example',
        'Public metadata',
        [
          const FieldInput(
            'Notes',
            'Private notes',
            'UNIQUE-FICTIONAL-SECRET-7395',
          ),
        ],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('test');
      final request = service.agent.request(session, 'test', [field]);
      service.owner.approve(request.id, [field]);
      final token = service.agent.claim(session, request.id).token;
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(directory.path, keys);
      addTearDown(store.close);
      service = InformationService(repository: store);
      expect(
        service.owner.information.single.fields.single.value,
        'UNIQUE-FICTIONAL-SECRET-7395',
      );
      expect(
        () => service.agent.read(token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(store.cipherVersion, startsWith('4.'));
      for (final file in directory.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.lock'),
      )) {
        expect(
          String.fromCharCodes(file.readAsBytesSync()),
          isNot(contains('UNIQUE-FICTIONAL-SECRET-7395')),
        );
      }
    },
  );
  test('wrong or missing key preserves the encrypted library', () async {
    final directory = await Directory.systemTemp.createTemp(
      'info-storage-fail-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final keys = TestKeyStore();
    final store = await EncryptedInformationRepository.open(
      directory.path,
      keys,
    );
    final service = InformationService(repository: store);
    await service.owner.createInformation('Example', '', [
      const FieldInput('Value', '', 'fictional-only'),
    ]);
    await store.close();
    final before = File('${directory.path}/library.db').readAsBytesSync();
    final original = keys.key;
    keys.key = List.filled(32, 7);
    await expectLater(
      EncryptedInformationRepository.open(directory.path, keys),
      throwsA(isA<StorageFailure>()),
    );
    expect(File('${directory.path}/library.db').readAsBytesSync(), before);
    keys.key = null;
    await expectLater(
      EncryptedInformationRepository.open(directory.path, keys),
      throwsA(isA<StorageFailure>()),
    );
    expect(File('${directory.path}/library.db').readAsBytesSync(), before);
    keys.key = original;
    final reopened = await EncryptedInformationRepository.open(
      directory.path,
      keys,
    );
    expect(
      InformationService(
        repository: reopened,
      ).owner.information.single.fields.single.value,
      'fictional-only',
    );
    await reopened.close();
  });
}
