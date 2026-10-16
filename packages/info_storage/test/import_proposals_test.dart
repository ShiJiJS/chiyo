import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:test/test.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = List.of(key);
  }
}

void main() {
  test(
    'encrypted proposal survives restart and commits one durable batch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'proposal-storage-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final keys = _Keys();
      var store = await EncryptedInformationRepository.open(
        directory.path,
        keys,
      );
      var service = InformationService(repository: store);
      final session = service.agent.openSession('Private importing chat');
      final id = await service.agent.submitImport(
        session,
        [
          ImportItemInput(
            'PENDING-PROPOSAL-MARKER-999',
            '',
            [const FieldInput('Host', '', 'PRIVATE-PROPOSAL-MARKER-999')],
            suggestedDirectory: 'Services',
            suggestedTags: ['Notes'],
          ),
          ImportItemInput('Second', '', [
            const FieldInput(
              'Notes',
              '',
              'Private note',
              kind: FieldKind.textNote,
            ),
          ]),
        ],
        agentName: 'Codex',
        purpose: '整理指定入口',
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(directory.path, keys);
      service = InformationService(repository: store);
      expect(service.agent.catalog(), isEmpty);
      expect(
        () => service.agent.importStatus(session, id),
        throwsA(isA<AccessFailure>()),
      );
      final pending = service.owner.importProposals.single;
      expect(pending.agentName, 'Codex');
      expect(pending.purpose, '整理指定入口');
      expect(
        pending.items.first.fields.single.value,
        'PRIVATE-PROPOSAL-MARKER-999',
      );
      final items = await service.owner.confirmImport(
        id,
        pending.version,
        pending.items,
      );
      await service.close();
      await store.close();
      store = await EncryptedInformationRepository.open(directory.path, keys);
      service = InformationService(repository: store);
      final retry = await service.owner.confirmImport(id, 1, pending.items);
      expect(retry.map((i) => i.id), items.map((i) => i.id));
      expect(service.owner.information, hasLength(2));
      expect(service.owner.directories.single.name, 'Services');
      expect(service.owner.tags.single.name, 'Notes');
      expect(service.owner.importProposals.single.items, isEmpty);
      expect(service.owner.importProposals.single.fieldCount, 2);
      expect(service.owner.importProposals.single.itemNames, [
        'PENDING-PROPOSAL-MARKER-999',
        'Second',
      ]);
      expect(
        service.owner.information.last.fields.single.kind,
        FieldKind.textNote,
      );
      await service.close();
      await store.close();
      for (final file in directory.listSync().whereType<File>()) {
        final bytes = String.fromCharCodes(file.readAsBytesSync());
        expect(bytes, isNot(contains('PRIVATE-PROPOSAL-MARKER-999')));
        expect(bytes, isNot(contains('PENDING-PROPOSAL-MARKER-999')));
      }
    },
  );
}
