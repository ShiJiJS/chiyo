import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
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
    'organization proposals reopen, preserve content, and are excluded from recovery',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'organization-storage-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = _Keys();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      final item = await service.owner.createInformation('Notebook', '', [
        const FieldInput('Address', '', 'PRIVATE-ORGANIZATION-CONTENT-47'),
      ]);
      final session = service.agent.openSession('Organizer');
      final task = await service.owner.startOrganizationTask(
        service.owner.organizationAgents.single.id,
        [item.id],
      );
      await service.agent.submitOrganization(session, task.id, [
        OrganizationChange(
          itemId: item.id,
          baseVersion: 1,
          directoryName: 'Services',
          tagNames: ['Notes'],
        ),
      ]);
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(
        service.owner.organizationTasks.single.state,
        OrganizationTaskState.proposed,
      );
      final fresh = service.agent.openSession('Organizer');
      expect(service.agent.organizationTasks(fresh), isEmpty);
      await expectLater(
        service.agent.organizationMetadata(fresh, task.id),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.confirmOrganization(task.id);
      expect(
        service.owner.information.single.fields.single.value,
        'PRIVATE-ORGANIZATION-CONTENT-47',
      );
      expect(service.owner.directories.single.name, 'Services');
      expect(service.owner.tags.single.name, 'Notes');
      final recovery = await store.backups.enable();
      await store.backups.exportTo('${folder.path}/snapshot.aimbackup');
      final recipient = await EncryptedInformationRepository.open(
        '${folder.path}/recipient',
        _Keys(),
      );
      await recipient.backups.restoreFrom(
        '${folder.path}/snapshot.aimbackup',
        recovery,
      );
      expect(recipient.organizationTasks, isEmpty);
      expect(
        recipient.items.single.directoryId,
        store.items.single.directoryId,
      );
      await recipient.close();
      await service.close();
      await store.close();
      final bytes = File('${folder.path}/library.db').readAsBytesSync();
      expect(
        String.fromCharCodes(bytes),
        isNot(contains('PRIVATE-ORGANIZATION-CONTENT-47')),
      );
    },
  );
  test(
    'schema eleven upgrades additively without changing saved information',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'organization-upgrade-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = _Keys();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      final service = InformationService(repository: store);
      final item = await service.owner.createInformation('Existing', '', [
        const FieldInput('Value', '', 'unchanged'),
      ]);
      await service.close();
      await store.close();
      final db = sqlite3.open('${folder.path}/library.db');
      final hex = keys.key!
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute('DROP TABLE organization_tasks');
      db.execute('PRAGMA user_version = 11');
      db.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      expect(store.items.single.id, item.id);
      expect(store.items.single.fields.single.value, 'unchanged');
      final upgraded = InformationService(repository: store);
      upgraded.agent.openSession('A');
      await upgraded.owner.startOrganizationTask(
        upgraded.owner.organizationAgents.single.id,
        [item.id],
      );
      expect(store.organizationTasks, hasLength(1));
      await upgraded.close();
      await store.close();
    },
  );
  test(
    'failed batch rolls back labels, content, revisions and proposal state on disk',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'organization-rollback-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final keys = _Keys();
      var store = await EncryptedInformationRepository.open(folder.path, keys);
      var service = InformationService(repository: store);
      final session = service.agent.openSession('Import and organize');
      final proposal = await service.agent.submitImport(session, [
        ImportItemInput(
          'Notebook',
          '',
          [const FieldInput('Address', '', 'private.invalid')],
          suggestedDirectory: 'Services',
          suggestedTags: ['Notes'],
        ),
      ]);
      void failWrites(bool fail) {
        final db = sqlite3.open('${folder.path}/library.db');
        final hex = keys.key!
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join();
        db.execute('PRAGMA key = "x\'$hex\'"');
        if (fail) {
          db.execute(
            "CREATE TRIGGER synthetic_failure BEFORE INSERT ON information_fields BEGIN SELECT RAISE(ABORT,'synthetic write failure'); END",
          );
        } else {
          db.execute('DROP TRIGGER synthetic_failure');
        }
        db.close();
      }

      failWrites(true);
      await expectLater(
        service.owner.confirmImport(
          proposal,
          1,
          service.owner.importProposals.single.items,
        ),
        throwsA(isA<StorageFailure>()),
      );
      expect(store.items, isEmpty);
      expect(store.directories, isEmpty);
      expect(store.tags, isEmpty);
      expect(store.importProposals.single.state, ImportProposalState.pending);
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(store.items, isEmpty);
      expect(store.directories, isEmpty);
      expect(store.tags, isEmpty);
      failWrites(false);
      final receipt = (await service.owner.confirmImport(
        proposal,
        1,
        store.importProposals.single.items,
      )).single;
      final agent = service.agent.openSession('Organizer');
      final task = await service.owner.startOrganizationTask(
        service.owner.organizationAgents.single.id,
        [receipt.id],
      );
      await service.agent.submitOrganization(agent, task.id, [
        OrganizationChange(
          itemId: receipt.id,
          baseVersion: 1,
          directoryName: 'New category',
          tagNames: ['New tag'],
        ),
      ]);
      failWrites(true);
      await expectLater(
        service.owner.confirmOrganization(task.id),
        throwsA(isA<StorageFailure>()),
      );
      expect(store.directories.map((d) => d.name), ['Services']);
      expect(store.tags.map((t) => t.name), ['Notes']);
      expect(store.items.single.version, 1);
      expect(store.informationRevisions, isEmpty);
      expect(
        store.organizationTasks.single.state,
        OrganizationTaskState.proposed,
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(folder.path, keys);
      service = InformationService(repository: store);
      expect(store.directories.map((d) => d.name), ['Services']);
      expect(store.tags.map((t) => t.name), ['Notes']);
      expect(store.items.single.version, 1);
      expect(store.informationRevisions, isEmpty);
      expect(
        store.organizationTasks.single.state,
        OrganizationTaskState.proposed,
      );
      failWrites(false);
      await service.owner.confirmOrganization(task.id);
      expect(store.items.single.version, 2);
      expect(
        store.organizationTasks.single.state,
        OrganizationTaskState.confirmed,
      );
      await service.close();
      await store.close();
    },
  );
}
