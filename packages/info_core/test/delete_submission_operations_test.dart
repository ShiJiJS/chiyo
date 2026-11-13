import 'dart:async';
import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

List<InformationItem> seed() => [
  InformationItem('item', 'Synthetic item', '', 1, [
    const InformationField('first', 'First', '', 'DO-NOT-RETURN-EXISTING', 1),
    const InformationField('second', 'Second', '', 'DO-NOT-RETURN-OTHER', 1),
  ]),
];
Matcher fails(String code) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', code));

class _SlowDelete extends MemoryInformationRepository {
  _SlowDelete() : super(seed());
  final reached = Completer<void>(), release = Completer<void>();
  @override
  Future<void> saveDeleteProposal(DeleteProposal proposal) async {
    reached.complete();
    await release.future;
    await super.saveDeleteProposal(proposal);
  }
}

void main() {
  test(
    'one deletion survives concurrent repeats and capacity, retains its identity after approval, and never deletes before approval',
    () async {
      final repo = MemoryInformationRepository(seed());
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final session = service.agent.openSession('Synthetic delete chat');
      Future<String> submit([String title = 'Remove synthetic item']) =>
          service.agent.submitDelete(
            session,
            'item',
            1,
            title: title,
            purpose: 'Test deletion',
            operationId: 'delete-once',
          );
      final ids = await Future.wait(List.generate(24, (_) => submit()));
      expect(ids.toSet(), hasLength(1));
      expect(repo.deleteProposals, hasLength(1));
      expect(service.owner.information.single.id, 'item');
      expect(await submit('  Remove synthetic item  '), ids.first);
      for (var i = 0; i < 19; i++) {
        await service.agent.submitDelete(
          session,
          'not-disclosed-$i',
          1,
          operationId: 'other-$i',
        );
      }
      expect(await submit(), ids.first);
      await expectLater(
        submit('Remove something else'),
        fails('operation_conflict'),
      );
      await service.owner.confirmDelete(ids.first, 1);
      expect(service.owner.information, isEmpty);
      expect(await submit(), ids.first);
      expect(
        service.agent.deleteStatusByOperation(session, 'delete-once')['status'],
        'confirmed',
      );
      expect(repo.recycleEntries, hasLength(1));
      expect(repo.deleteProposals.first.operationId, 'delete-once');
      expect(repo.deleteProposals.first.hasValidSubmissionIdentity, true);
      final record = service.agent.showOwnOperation(session, 'delete-once');
      expect(record['requestKind'], 'delete');
      expect(record['requestId'], ids.first);
      expect(jsonEncode(record), isNot(contains('DO-NOT-RETURN')));
    },
  );
  test(
    'field deletion, chat isolation, cross-command conflicts and closed chats keep their original rules',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(seed()),
      );
      addTearDown(service.close);
      final a = service.agent.openSession('Same label'),
          b = service.agent.openSession('Same label');
      final id = await service.agent.submitDelete(
        a,
        'item',
        1,
        fieldId: 'first',
        operationId: 'one',
      );
      expect(
        service.agent.deleteStatusByOperation(b, 'one')['status'],
        'not_found',
      );
      expect(() => service.agent.deleteStatus(b, id), fails('unauthorized'));
      await service.agent.submitDelete(
        b,
        'item',
        1,
        fieldId: 'second',
        operationId: 'one',
      );
      expect(
        () => service.agent.request(a, 'Read', [
          const FieldRef('item', 'first'),
        ], operationId: 'one'),
        fails('operation_conflict'),
      );
      service.agent.request(a, 'Read', [
        const FieldRef('item', 'first'),
      ], operationId: 'read-first');
      await expectLater(
        service.agent.submitDelete(a, 'item', 1, operationId: 'read-first'),
        fails('operation_conflict'),
      );
      await service.owner.confirmDelete(id, 1);
      expect(service.owner.information.single.fields.map((f) => f.id), [
        'second',
      ]);
      expect(
        await service.agent.submitDelete(
          a,
          'item',
          1,
          fieldId: 'first',
          operationId: 'one',
        ),
        id,
      );
        service.agent.endSession(a);
      expect(
        () => service.agent.deleteStatusByOperation(a, 'one'),
        fails('unauthorized'),
      );
    },
  );
  test(
    'an async deletion save reserves the number against a synchronous field request',
    () async {
      final repo = _SlowDelete();
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final session = service.agent.openSession('Concurrent synthetic chat');
      final pending = service.agent.submitDelete(
        session,
        'item',
        1,
        operationId: 'one',
      );
      await repo.reached.future;
      expect(
        () => service.agent.request(session, 'Read', [
          const FieldRef('item', 'first'),
        ], operationId: 'one'),
        fails('operation_conflict'),
      );
      repo.release.complete();
      await pending;
      expect(repo.deleteProposals, hasLength(1));
      expect(
        (service.agent.queryOwnRequests(session, kind: 'access')['records']
            as List),
        isEmpty,
      );
    },
  );
  test(
    'stored submission fields cannot be detached, malformed or silently reused for changed content',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(seed()),
      );
      addTearDown(service.close);
      final session = service.agent.openSession('Synthetic validation');
      await service.agent.submitDelete(session, 'item', 1, operationId: 'one');
      final proposal = service.owner.deleteProposals.single;
      for (final bad in [
        {...proposal.toJson()}..remove('submissionDigest'),
        {...proposal.toJson(), 'operationId': 'bad/id'},
        {...proposal.toJson(), 'baseVersion': 2},
        {...proposal.toJson(), 'submissionDigest': 'a' * 64},
      ]) {
        expect(() => DeleteProposal.fromJson(bad), throwsFormatException);
      }
      expect(
        DeleteProposal.fromJson(
          {...proposal.toJson()}
            ..remove('operationId')
            ..remove('submissionDigest'),
        ).operationId,
        null,
      );
    },
  );
}
