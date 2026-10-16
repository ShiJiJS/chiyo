import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'terminal imports retain value-free receipts and retry after deletion never recreates content',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final session = service.agent.openSession('importer');
      final input = [
        ImportItemInput('new', '', [
          const FieldInput('secret', '', 'TERMINAL-SECRET'),
        ]),
      ];
      final id = await service.agent.submitImport(session, input);
      final receipt = (await service.owner.confirmImport(id, 1, input)).single;
      expect(
        service.owner.importProposals.single.toJson().toString(),
        isNot(contains('TERMINAL-SECRET')),
      );
      expect(service.owner.importProposals.single.itemCount, 1);
      await service.owner.deleteInformation(receipt.id, receipt.version);
      final retry = (await service.owner.confirmImport(id, 1, input)).single;
      expect(retry.id, receipt.id);
      expect(retry.version, 1);
      expect(service.owner.information, isEmpty);
      final rejected = await service.agent.submitImport(session, input);
      await service.owner.rejectImport(rejected, 1);
      expect(
        service.owner.importProposals.last.toJson().toString(),
        isNot(contains('TERMINAL-SECRET')),
      );
    },
  );
  test(
    'confirmed update removals enter the same thirty day recycle lifecycle and cannot revive after purge',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      final session = service.agent.openSession('writer');
      final id = await service.agent.submitUpdate(
        session,
        UpdateInput('demo-server', 1, const [FieldChange.remove('host')]),
      );
      await service.owner.confirmUpdate(id, 1);
      final entry = service.owner.recycleEntries.single;
      expect(entry.snapshot!.fields.single.value, 'demo.example.invalid');
      now = now.add(const Duration(days: 30));
      await service.owner.purgeRecycle();
      now = now.subtract(const Duration(days: 1));
      await expectLater(
        service.owner.restoreRecycled(entry.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.recycleEntries, isEmpty);
      expect(service.owner.recycleFacts.last.kind, RecycleFactKind.purged);
    },
  );
  test(
    'agent deletion is a private versioned proposal until owner confirmation',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('proposer');
      final other = service.agent.openSession('other');
      final id = await service.agent.submitDelete(session, 'demo-server', 1);
      expect(service.agent.catalog(), hasLength(1));
      expect(service.agent.deleteStatus(session, id), {
        'status': 'pending',
        'proposalId': id,
      });
      expect(
        () => service.agent.deleteStatus(other, id),
        throwsA(isA<AccessFailure>()),
      );
      final preview = service.owner.previewDelete(id);
      expect(preview.fields, hasLength(2));
      final entry = await service.owner.confirmDelete(id, 1);
      expect(service.agent.catalog(), isEmpty);
      expect(
        service.agent.deleteStatus(session, id).toString(),
        isNot(contains('demo.example.invalid')),
      );
      expect((await service.owner.confirmDelete(id, 1)).id, entry.id);
      final restored = await service.owner.restoreRecycled(entry.id);
      expect(restored.version, 3);
      final second = await service.owner.deleteInformation(restored.id, 3);
      expect((await service.owner.restoreRecycled(second.id)).version, 5);
      final stale = await service.agent.submitDelete(session, 'demo-server', 3);
      await expectLater(
        service.owner.confirmDelete(stale, 1),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.deleteStatus(session, stale)['status'],
        'conflicted',
      );
    },
  );
  test(
    'owner field deletion and restoration require a fresh grant only for the deleted field',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('chat');
      const host = FieldRef('demo-server', 'host');
      const user = FieldRef('demo-server', 'username');
      final request = service.agent.request(session, 'connect', [host, user]);
      service.owner.approve(request.id, [host, user]);
      final token = service.agent.claim(session, request.id).token;
      final deleted = await service.owner.deleteInformation(
        'demo-server',
        1,
        fieldId: 'host',
      );
      await expectLater(
        Future.sync(() => service.agent.read(token, host)),
        throwsA(isA<AccessFailure>()),
      );
      expect(await Future.value(service.agent.read(token, user)), 'demo-user');
      expect(
        service.agent.catalog().single['fields'].toString(),
        isNot(contains('host')),
      );
      final restored = await service.owner.restoreRecycled(deleted.id);
      expect(restored.version, 3);
      expect(restored.fields.any((f) => f.id == 'host'), isTrue);
      await expectLater(
        Future.sync(() => service.agent.read(token, host)),
        throwsA(isA<AccessFailure>()),
      );
      expect(await Future.value(service.agent.read(token, user)), 'demo-user');
      final fresh = service.agent.request(session, 'restored', [host]);
      service.owner.approve(fresh.id, [host]);
      expect(
        await Future.value(
          service.agent.read(
            service.agent.claim(session, fresh.id).token,
            host,
          ),
        ),
        'demo.example.invalid',
      );
      expect(service.owner.recycleFacts.map((f) => f.kind), [
        RecycleFactKind.deleted,
        RecycleFactKind.restored,
      ]);
    },
  );
}
