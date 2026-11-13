import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class _SlowImport extends MemoryInformationRepository {
  _SlowImport(super.items);
  final reached = Completer<void>(), release = Completer<void>();
  @override
  Future<void> saveImportProposal(ImportProposal proposal) async {
    reached.complete();
    await release.future;
    await super.saveImportProposal(proposal);
  }
}

List<InformationItem> seed() => [
  InformationItem('item', 'Synthetic item', '', 1, [
    const InformationField('field', 'Field', '', 'PRIVATE-SYNTHETIC', 1),
  ]),
];
List<ImportItemInput> intake() => [
  ImportItemInput('Synthetic new item', '', [
    const FieldInput('Value', '', 'PRIVATE-SYNTHETIC-INTAKE'),
  ]),
];
Matcher accessConflict = throwsA(
  isA<AccessFailure>().having((e) => e.status, 'status', 'operation_conflict'),
);
Matcher useConflict = throwsA(
  isA<CredentialUseFailure>().having(
    (e) => e.code,
    'code',
    'operation_conflict',
  ),
);
void main() {
  test(
    'synchronous field request cannot steal an id while a proposal write awaits storage',
    () async {
      final repo = _SlowImport(seed());
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      final session = service.agent.openSession('Synthetic concurrent chat');
      final first = service.agent.submitImport(
        session,
        intake(),
        operationId: 'one-intent',
      );
      await repo.reached.future;
      expect(
        () => service.agent.request(session, 'Read field', [
          const FieldRef('item', 'field'),
        ], operationId: 'one-intent'),
        accessConflict,
      );
      repo.release.complete();
      await first;
      expect(repo.importProposals, hasLength(1));
      expect(
        (service.agent.queryOwnRequests(session, kind: 'access')['records']
            as List),
        isEmpty,
      );
    },
  );
  test(
    'persisted request ids cannot become proposal ids and separate chats remain independent',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(seed()),
      );
      addTearDown(service.close);
      final a = service.agent.openSession('Same display label'),
          b = service.agent.openSession('Same display label');
      service.agent.request(a, 'Read synthetic field', [
        const FieldRef('item', 'field'),
      ], operationId: 'shared-name');
      await expectLater(
        service.agent.submitImport(a, intake(), operationId: 'shared-name'),
        accessConflict,
      );
      await expectLater(
        service.agent.submitUpdate(
          a,
          UpdateInput('item', 1, [], name: 'New title'),
          operationId: 'shared-name',
        ),
        accessConflict,
      );
      final other = await service.agent.submitImport(
        b,
        intake(),
        operationId: 'shared-name',
      );
      expect(
        service.agent.showOwnOperation(b, 'shared-name')['requestId'],
        other,
      );
      expect(
        service.agent.showOwnOperation(a, 'shared-name')['requestKind'],
        'access',
      );
    },
  );
  test(
    'credential reveal creation and reads cannot reuse an existing information submission id',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(seed()),
      );
      addTearDown(service.close);
      var c = await service.owner.createStringCredential(
        name: 'Synthetic',
        publicPurpose: '',
        secret: 'PRIVATE-SYNTHETIC',
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: '',
        privateNote: '',
        suggestedBinding: 'TOKEN',
        discoverable: true,
      );
      final chat = service.agent.openSession('Synthetic cross-kind');
      service.agent.request(chat, 'Read field', [
        const FieldRef('item', 'field'),
      ], operationId: 'existing-field');
      CredentialRevealInput input(String op) => CredentialRevealInput.fromJson({
        'protocolVersion': 2,
        'command': 'request-reveal',
        'credentialId': c.id,
        'version': 1,
        'purpose': 'Synthetic fallback',
        'fallbackReason': 'Synthetic unsupported input',
        'operationId': op,
      });
      await expectLater(
        service.agent.requestCredentialReveal(chat, input('existing-field')),
        useConflict,
      );
      final r = await service.agent.requestCredentialReveal(
        chat,
        input('reveal-submit'),
      );
      expect(
        () => service.agent.request(chat, 'Read field', [
          const FieldRef('item', 'field'),
        ], operationId: 'reveal-submit'),
        accessConflict,
      );
      await service.owner.decideCredentialUse(r.id, approveCredential: true);
      await expectLater(
        service.agent.readCredentialReveal(chat, r.id, 'existing-field'),
        useConflict,
      );
      expect(service.owner.credentialUseRequests.single.revealReads, isEmpty);
    },
  );
}
