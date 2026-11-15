import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

const device = 'AAAAAAAAAAAAAAAAAAAAAA';
const otherDevice = 'BBBBBBBBBBBBBBBBBBBBBB';

class FailingBatchRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitCredentialBatch(
    CredentialUseBatch request, {
    required int expectedRevision,
    required void Function() validate,
    CredentialBatchOperation? operation,
    int? expectedOperationRevision,
  }) async {
    if (fail) throw const AccessFailure('audit_unavailable');
    await super.commitCredentialBatch(
      request,
      expectedRevision: expectedRevision,
      validate: validate,
      operation: operation,
      expectedOperationRevision: expectedOperationRevision,
    );
  }
}

Matcher failure([String? code]) => throwsA(
  isA<CredentialUseFailure>().having((e) => e.code, 'code', code ?? anything),
);

Map<String, dynamic> destination(
  String page, {
  String form = '#login',
  String field = '#password',
}) => {
  'via': 'ego',
  'target': {
    'provider': 'ego',
    'instanceId': 'synthetic-browser',
    'space': 7,
    'pageId': page,
    'url': 'https://example.test/login',
    'form': form,
    'field': field,
    'structureDigest': 'a' * 64,
  },
};

void main() {
  late FailingBatchRepository repository;
  late InformationService service;
  late String session, stranger;
  late ManagedCredential a, b;
  late DateTime now;
  CredentialBatchInput plan({
    String purpose = 'Sign into two synthetic services',
    bool explicitVersions = true,
  }) => CredentialBatchInput.fromJson({
    'protocolVersion': 3,
    'purpose': purpose,
    'agentName': 'Trial Agent',
    'externalChatId': 'same-public-chat',
    'items': [
      {
        'credentialId': a.id,
        if (explicitVersions) 'version': a.version,
        'destination': destination('p1'),
      },
      {
        'credentialId': b.id,
        if (explicitVersions) 'version': b.version,
        'destination': destination('p2'),
      },
    ],
  });
  Future<CredentialUseBatch> request({
    String operation = 'submit-1',
    CredentialBatchInput? input,
  }) => service.agent.requestCredentialBatch(
    session,
    device,
    input ?? plan(),
    operationId: operation,
  );
  Future<CredentialUseBatch> approve(
    CredentialUseBatch r,
    List<String> ids, {
    String operation = 'approve-1',
  }) => service.owner.decideCredentialBatch(
    r.id,
    operationId: operation,
    revision: r.revision,
    approvedItems: ids,
  );
  Map<String, CredentialBatchDestination> observations(
    CredentialUseBatch r,
    Iterable<String> ids,
  ) => {
    for (final item in r.items.where((i) => ids.contains(i.id)))
      item.id: item.destination,
  };
  setUp(() async {
    repository = FailingBatchRepository();
    now = DateTime.utc(2026, 11, 13);
    service = InformationService(repository: repository, clock: () => now);
    session = service.agent.openSession('same public label');
    stranger = service.agent.openSession('same public label');
    Future<ManagedCredential> credential(String name, String secret) async {
      final c = await service.owner.createStringCredential(
        name: name,
        publicPurpose: 'Synthetic service',
        secret: secret,
      );
      return service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: '',
        suggestedBinding: c.suggestedBinding,
        discoverable: true,
      );
    }

    a = await credential('Service A', 'PRIVATE-PASSWORD-A');
    b = await credential('Service B', 'PRIVATE-PASSWORD-B');
  });
  tearDown(() => service.close());

  test(
    'title and summary survive decisions and belong to the immutable submission',
    () async {
      final input = CredentialBatchInput.fromJson({
        ...plan().toJson(),
        'title': '检查两个服务',
      });
      final r = await request(input: input);
      expect(r.title, '检查两个服务');
      expect(r.summary, input.purpose);
      final accepted = await approve(r, ['b1', 'b2']);
      expect(accepted.title, r.title);
      expect(
        CredentialUseBatch.fromJson(
          Map<String, dynamic>.from(accepted.toJson()),
        ).title,
        r.title,
      );
      expect(
        service.agent.credentialBatchStatus(session, device, r.id)['title'],
        r.title,
      );
      await expectLater(
        request(
          input: CredentialBatchInput.fromJson({
            ...plan().toJson(),
            'title': '换一个任务',
          }),
        ),
        failure('operation_conflict'),
      );
      expect(plan().toJson().containsKey('title'), false);
    },
  );

  test(
    'one request has multiple real destinations and stable versions without aliases',
    () async {
      final r = await request(input: plan(explicitVersions: false));
      expect(repository.credentialBatches, hasLength(1));
      expect(r.items.map((i) => i.credentialId), [a.id, b.id]);
      expect(r.items.map((i) => i.version), [a.version, b.version]);
      expect(r.items.map((i) => i.id), ['b1', 'b2']);
      expect(
        (service.agent.queryOwnRequests(
                  session,
                  kind: 'credential-use',
                )['records']
                as List)
            .single['id'],
        r.id,
      );
      expect(service.agent.showOwnRequest(session, r.id)['protocolVersion'], 3);
      expect(
        service.agent.showOwnOperation(session, 'submit-1')['requestId'],
        r.id,
      );
      expect(service.agent.queryOwnRequests(stranger)['records'], isEmpty);
      expect(
        CredentialUseBatch.fromJson(
          Map<String, dynamic>.from(r.toJson()),
        ).toJson(),
        r.toJson(),
      );
      final status = service.agent.credentialBatchStatus(session, device, r.id);
      expect(status['status'], 'pending');
      for (final value in [
        session,
        stranger,
        'PRIVATE-PASSWORD-A',
        'PRIVATE-PASSWORD-B',
      ]) {
        expect(jsonEncode(status), isNot(contains(value)));
      }
      expect(
        () => service.agent.credentialBatchStatus(stranger, device, r.id),
        failure('session_mismatch'),
      );
      expect(
        () => service.agent.credentialBatchStatus(session, otherDevice, r.id),
        failure('session_mismatch'),
      );
      final raw = plan().toJson();
      final bad = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
      (bad['items'] as List).first['alias'] = 'unnecessary-name';
      expect(
        () => CredentialBatchInput.fromJson(bad),
        failure('unknown_field'),
      );
    },
  );

  test(
    'partial approval allows A alone, never starts an operation that also needs B',
    () async {
      final r = await approve(await request(), ['b1']);
      expect(
        service.agent.credentialBatchStatus(session, device, r.id)['status'],
        'partially_approved',
      );
      await expectLater(
        service.agent.beginCredentialBatchOperation(
          session,
          device,
          r.id,
          operationId: 'both',
        ),
        failure('scope_not_approved'),
      );
      expect(repository.credentialBatchOperations, isEmpty);
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'only-a',
        itemIds: ['b1'],
      );
      expect(claim.privateProof, isNotNull);
      expect(claim.operation.itemIds, ['b1']);
      final private = await service.agent.claimCredentialBatchMaterials(
        device,
        claim.privateProof!,
        observations(r, ['b1']),
      );
      expect(utf8.decode(private.bytes['b1']!), 'PRIVATE-PASSWORD-A');
      expect(private.bytes.containsKey('b2'), false);
      expect(
        jsonEncode(claim.toPublicJson()),
        isNot(contains(claim.privateProof!)),
      );
    },
  );

  test(
    'duplicate submit or execution returns original records without renewal or another material proof',
    () async {
      final original = await request();
      now = now.add(const Duration(minutes: 5));
      expect((await request()).toJson(), original.toJson());
      await expectLater(
        request(input: plan(purpose: 'different intent')),
        failure('operation_conflict'),
      );
      final approved = await approve(original, ['b1', 'b2']);
      final expiry = approved.items.first.expiresAt;
      now = now.add(const Duration(minutes: 5));
      final replayDecision = await service.owner.decideCredentialBatch(
        original.id,
        operationId: 'approve-1',
        revision: original.revision,
        approvedItems: ['b2', 'b1'],
      );
      expect(replayDecision.items.first.expiresAt, expiry);
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        original.id,
        operationId: 'fill-1',
        itemIds: ['b2', 'b1'],
      );
      final duplicate = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        original.id,
        operationId: 'fill-1',
        itemIds: ['b1', 'b2'],
      );
      expect(duplicate.privateProof, isNull);
      expect(duplicate.operation.toJson(), claim.operation.toJson());
      await expectLater(
        service.agent.beginCredentialBatchOperation(
          session,
          device,
          original.id,
          operationId: 'fill-1',
          itemIds: ['b1'],
        ),
        failure('operation_conflict'),
      );
      await expectLater(
        request(operation: 'fill-1'),
        failure('operation_conflict'),
      );
      final independent = await service.agent.requestCredentialBatch(
        stranger,
        device,
        plan(),
        operationId: 'fill-1',
      );
      expect(independent.id, isNot(original.id));
    },
  );

  test(
    'wrong target prevents all material release; a corrected first claim consumes material exactly once',
    () async {
      final r = await approve(await request(), ['b1', 'b2']);
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'fill-1',
      );
      final wrong = observations(r, ['b1', 'b2']);
      wrong['b2'] = CredentialBatchDestination.fromJson(
        destination('p2', form: '#change-password'),
      );
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          claim.privateProof!,
          wrong,
        ),
        failure('destination_changed'),
      );
      expect(
        repository.credentialBatchOperations.single.materialClaimed,
        false,
      );
      final material = await service.agent.claimCredentialBatchMaterials(
        device,
        claim.privateProof!,
        observations(r, ['b1', 'b2']),
      );
      expect(material.bytes.keys.toSet(), {'b1', 'b2'});
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          claim.privateProof!,
          observations(r, ['b1', 'b2']),
        ),
        failure('execution_unknown'),
      );
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          otherDevice,
          claim.privateProof!,
          observations(r, ['b1', 'b2']),
        ),
        failure('session_mismatch'),
      );
    },
  );

  test(
    'revoking B does not revoke A, and revocation after claim still blocks input',
    () async {
      final r = await approve(await request(), ['b1', 'b2']);
      final both = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'both',
      );
      await service.agent.claimCredentialBatchMaterials(
        device,
        both.privateProof!,
        observations(r, ['b1', 'b2']),
      );
      final revoked = await service.owner.revokeCredentialBatch(
        r.id,
        operationId: 'revoke-b',
        revision: r.revision,
        itemIds: ['b2'],
      );
      final status = service.agent.credentialBatchStatus(session, device, r.id);
      expect((status['items'] as List).map((i) => i['grantState']), [
        'available',
        'revoked',
      ]);
      await expectLater(
        service.agent.authorizeCredentialBatchInput(device, both.privateProof!),
        failure('scope_not_approved'),
      );
      await service.agent.finishCredentialBatchOperation(
        device,
        both.privateProof!,
        CredentialBatchOperationState.refused,
        itemResults: {'b1': 'not_attempted', 'b2': 'refused'},
        errorCode: 'grant_revoked',
      );
      final aOnly = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'a-only',
        itemIds: ['b1'],
      );
      expect(aOnly.privateProof, isNotNull);
      await service.owner.revokeCredentialBatch(
        r.id,
        operationId: 'revoke-a',
        revision: revoked.revision,
        itemIds: ['b1'],
      );
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          aOnly.privateProof!,
          observations(r, ['b1']),
        ),
        failure('scope_not_approved'),
      );
    },
  );

  test(
    'unknown outcome is queryable and retry never releases another proof or changes the result',
    () async {
      final r = await approve(await request(), ['b1']);
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'fill-1',
        itemIds: ['b1'],
      );
      await service.agent.claimCredentialBatchMaterials(
        device,
        claim.privateProof!,
        observations(r, ['b1']),
      );
      await service.agent.authorizeCredentialBatchInput(
        device,
        claim.privateProof!,
      );
      final completed = await service.agent.finishCredentialBatchOperation(
        device,
        claim.privateProof!,
        CredentialBatchOperationState.unknown,
        itemResults: {'b1': 'unknown'},
        errorCode: 'fill_unknown',
      );
      expect(completed.state, CredentialBatchOperationState.unknown);
      final replay = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'fill-1',
        itemIds: ['b1'],
      );
      expect(replay.privateProof, isNull);
      expect(replay.operation.state, CredentialBatchOperationState.unknown);
      expect(
        service.agent.credentialBatchOperationStatus(
          session,
          device,
          'fill-1',
        )['executionState'],
        'unknown',
      );
      await expectLater(
        service.agent.authorizeCredentialBatchInput(
          device,
          claim.privateProof!,
        ),
        failure('execution_unknown'),
      );
      await expectLater(
        service.agent.finishCredentialBatchOperation(
          device,
          claim.privateProof!,
          CredentialBatchOperationState.filled,
          itemResults: {'b1': 'filled'},
        ),
        failure('operation_conflict'),
      );
    },
  );

  test(
    'no material or input is allowed after session end, credential disable or expiry',
    () async {
      final r = await approve(await request(), ['b1', 'b2']);
      await service.owner.setCredentialEnabled(
        b.id,
        service.owner.credential(b.id).revision,
        false,
      );
      final states =
          service.agent.credentialBatchStatus(session, device, r.id)['items']
              as List;
      expect(states.first['grantState'], 'available');
      expect(states.last['grantState'], 'revoked');
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'a-only',
        itemIds: ['b1'],
      );
      service.agent.endSession(session);
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          claim.privateProof!,
          observations(r, ['b1']),
        ),
        failure('grant_revoked'),
      );
      final newSession = service.agent.openSession('same public label');
      expect(
        () => service.agent.credentialBatchStatus(newSession, device, r.id),
        failure('session_mismatch'),
      );
    },
  );

  test(
    'failed audit cannot publish a request, a decision or a material claim',
    () async {
      repository.fail = true;
      await expectLater(request(), throwsA(isA<AccessFailure>()));
      expect(repository.credentialBatches, isEmpty);
      repository.fail = false;
      final r = await request();
      repository.fail = true;
      await expectLater(approve(r, ['b1']), throwsA(isA<AccessFailure>()));
      expect(repository.credentialBatches.single.decisions, isEmpty);
      repository.fail = false;
      final approved = await approve(r, ['b1']);
      final claim = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'a-only',
        itemIds: ['b1'],
      );
      repository.fail = true;
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          claim.privateProof!,
          observations(approved, ['b1']),
        ),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        repository.credentialBatchOperations.single.materialClaimed,
        false,
      );
    },
  );

  test(
    'active inputs to the same page are refused as busy, without queueing',
    () async {
      final r = await approve(await request(), ['b1', 'b2']);
      final aOnly = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'a-1',
        itemIds: ['b1'],
      );
      await expectLater(
        service.agent.beginCredentialBatchOperation(
          session,
          device,
          r.id,
          operationId: 'a-2',
          itemIds: ['b1'],
        ),
        failure('busy'),
      );
      final bOnly = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'b-1',
        itemIds: ['b2'],
      );
      expect(bOnly.privateProof, isNotNull);
      expect(repository.credentialBatchOperations, hasLength(2));
      expect(aOnly.privateProof, isNotNull);
      expect(
        service.agent.showOwnOperation(session, 'a-1')['state'],
        'checking',
      );
      now = now.add(const Duration(seconds: 31));
      expect(
        service.agent.credentialBatchOperationStatus(
          session,
          device,
          'a-1',
        )['executionState'],
        'unknown',
      );
      final repeat = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'a-1',
        itemIds: ['b1'],
      );
      expect(repeat.privateProof, isNull);
      expect(repeat.operation.state, CredentialBatchOperationState.unknown);
      await expectLater(
        service.agent.beginCredentialBatchOperation(
          session,
          device,
          r.id,
          operationId: 'new-id-cannot-hide-unknown',
          itemIds: ['b1'],
        ),
        failure('fill_needs_attention'),
      );
      final old = repository.credentialBatchOperations.singleWhere(
        (o) => o.operationId == 'a-1',
      );
      final acknowledged = await service.owner
          .acknowledgeCredentialBatchOperation(
            r.id,
            'a-1',
            ownerOperationId: 'checked-result',
            revision: old.revision,
          );
      expect(acknowledged.state, CredentialBatchOperationState.unknown);
      expect(acknowledged.attentionAcknowledgedAt, isNotNull);
      final newOperation = await service.agent.beginCredentialBatchOperation(
        session,
        device,
        r.id,
        operationId: 'explicit-new-input',
        itemIds: ['b1'],
      );
      expect(newOperation.privateProof, isNotNull);
      await expectLater(
        service.agent.claimCredentialBatchMaterials(
          device,
          aOnly.privateProof!,
          observations(r, ['b1']),
        ),
        failure('execution_unknown'),
      );
    },
  );

  test(
    'waiting and approval deadlines are fixed; changing defaults never renews them',
    () async {
      final r = await request();
      now = now.add(const Duration(hours: 2));
      expect(
        service.agent.credentialBatchStatus(session, device, r.id)['status'],
        'expired',
      );
      await expectLater(approve(r, ['b1']), failure('request_expired'));
      final next = await request(operation: 'submit-2');
      final approved = await approve(next, ['b1']);
      final expiry = approved.items.first.expiresAt;
      now = now.add(const Duration(hours: 2));
      final replay = await approve(next, ['b1']);
      expect(replay.items.first.expiresAt, expiry);
      await expectLater(
        service.agent.beginCredentialBatchOperation(
          session,
          device,
          next.id,
          operationId: 'too-late',
          itemIds: ['b1'],
        ),
        failure('grant_expired'),
      );
      expect(repository.credentialBatchOperations, isEmpty);
    },
  );
}
