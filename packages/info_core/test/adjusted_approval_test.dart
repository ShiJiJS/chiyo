import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('owner substitutes and adds fields across information items', () async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    addTearDown(service.close);
    final requestedItem = await service.owner
        .createInformation('Server A', '', [
          const FieldInput('Address', '', 'a.example.invalid'),
          const FieldInput('Username', '', 'alice'),
        ]);
    final correctItem = await service.owner.createInformation('Server B', '', [
      const FieldInput('Address', '', 'b.example.invalid'),
      const FieldInput('Private notes', '', 'Connect through the test network'),
    ]);
    final requested = FieldRef(requestedItem.id, requestedItem.fields.first.id);
    final selected = correctItem.fields
        .map((f) => FieldRef(correctItem.id, f.id))
        .toList();
    final session = service.agent.openSession('chat');
    final receipt = service.agent.request(session, 'Need connection details', [
      requested,
    ]);

    service.owner.approve(receipt.id, selected);
    final grant = service.agent.claim(session, receipt.id);
    expect(grant.fields, selected);
    expect(service.owner.requests.single.fields, [requested]);
    expect(service.owner.requests.single.approvedFields, selected);
    expect(
      service.agent.read(grant.token, selected.first),
      'b.example.invalid',
    );
    expect(
      service.agent.read(grant.token, selected.last),
      'Connect through the test network',
    );
    expect(
      () => service.agent.read(grant.token, requested),
      throwsA(isA<AccessFailure>()),
    );
    // Mutating the caller's selection cannot mutate the approved identities.
    selected.clear();
    expect(grant.fields, hasLength(2));
  });

  test('selected duration starts at approval and reads do not extend it', () {
    var now = DateTime.utc(2026, 10, 16);
    final service = InformationService.fictional(clock: () => now);
    addTearDown(service.close);
    final session = service.agent.openSession('chat');
    final receipt = service.agent.request(session, 'Need address', [
      const FieldRef('demo-server', 'host'),
    ]);
    now = now.add(const Duration(minutes: 10));
    service.owner.approve(receipt.id, [
      const FieldRef('demo-server', 'host'),
    ], lifetime: const Duration(minutes: 15));
    final grant = service.agent.claim(session, receipt.id);
    expect(grant.expiresAt, DateTime.utc(2026, 10, 16, 0, 25));
    now = now.add(const Duration(minutes: 14));
    expect(
      service.agent.read(grant.token, const FieldRef('demo-server', 'host')),
      'demo.example.invalid',
    );
    expect(
      service.agent.claim(session, receipt.id).expiresAt,
      DateTime.utc(2026, 10, 16, 0, 25),
    );
    now = now.add(const Duration(minutes: 1));
    expect(
      () => service.agent.read(
        grant.token,
        const FieldRef('demo-server', 'host'),
      ),
      throwsA(isA<AccessFailure>()),
    );
    expect(service.agent.status(session, receipt.id)['status'], 'expired');
  });

  test(
    'invalid or stale final selection leaves the request pending and retryable',
    () async {
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Address', '', 'a.invalid'),
        const FieldInput('Notes', '', 'private text'),
      ]);
      final address = FieldRef(item.id, item.fields.first.id);
      final notes = FieldRef(item.id, item.fields.last.id);
      final session = service.agent.openSession('chat');
      final receipt = service.agent.request(session, 'Need address', [address]);
      // Repository boundary represents a field removed after it was displayed.
      await repository.save(
        InformationItem(item.id, item.name, '', 2, [item.fields.last]),
      );
      expect(
        () => service.owner.approve(receipt.id, [address, notes]),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'invalid_scope',
          ),
        ),
      );
      expect(service.agent.status(session, receipt.id)['status'], 'pending');
      expect(service.owner.requests.single.approvedFields, isNull);
      expect(
        () =>
            service.owner.approve(receipt.id, [notes], lifetime: Duration.zero),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'invalid_duration',
          ),
        ),
      );
      expect(
        () => service.owner.approve(receipt.id, [
          notes,
        ], lifetime: const Duration(days: 8)),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'invalid_duration',
          ),
        ),
      );
      expect(service.agent.status(session, receipt.id)['status'], 'pending');
      service.owner.approve(receipt.id, [notes]);
      final grant = service.agent.claim(session, receipt.id);
      expect(grant.fields, [notes]);
      expect(
        () => service.owner.approve(receipt.id, [
          notes,
        ], lifetime: const Duration(minutes: 1)),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.agent.claim(session, receipt.id).token, grant.token);
      expect(
        service.agent.claim(session, receipt.id).expiresAt,
        grant.expiresAt,
      );
    },
  );

  test(
    'new information and fields never expand a grant; corrections remain readable',
    () async {
      final repository = MemoryInformationRepository();
      final service = InformationService(repository: repository);
      addTearDown(service.close);
      final item = await service.owner.createInformation('Server', '', [
        const FieldInput('Address', '', 'a.invalid'),
      ]);
      final address = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final receipt = service.agent.request(session, 'Need address', [address]);
      service.owner.approve(receipt.id, [address]);
      final grant = service.agent.claim(session, receipt.id);
      final corrected = await service.owner.correctValue(
        address,
        'updated.invalid',
      );
      await repository.save(
        InformationItem(item.id, item.name, '', 3, [
          ...corrected.fields,
          const InformationField('new-field', 'New notes', '', 'new secret', 1),
        ]),
      );
      final another = await service.owner.createInformation(
        'Another server',
        '',
        [const FieldInput('Address', '', 'b.invalid')],
      );
      expect(service.agent.read(grant.token, address), 'updated.invalid');
      expect(grant.fields, [address]);
      expect(
        () => service.agent.read(grant.token, FieldRef(item.id, 'new-field')),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.read(
          grant.token,
          FieldRef(another.id, another.fields.single.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
}
