import 'dart:async';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  for (final transition in ['expiry', 'delete', 'delete and restore']) {
    test(
      '$transition during durable recording blocks cached delivery and records denial',
      () async {
        var now = DateTime.utc(2026, 10, 16);
        final repository = WaitingAuditRepository();
        final service = InformationService(
          repository: repository,
          clock: () => now,
        );
        final item = await service.owner.createInformation(
          'Server',
          'Description',
          [const FieldInput('Address', 'Host', 'private.invalid')],
        );
        final field = FieldRef(item.id, item.fields.single.id);
        final session = service.agent.openSession('chat');
        final receipt = service.agent.request(session, 'Address', [field]);
        service.owner.approve(receipt.id, [
          field,
        ], lifetime: const Duration(minutes: 1));
        final grant = service.agent.claim(session, receipt.id);
        final denied = expectLater(
          service.agent.read(grant.token, field),
          throwsA(isA<AccessFailure>()),
        );
        await repository.started.future;
        if (transition == 'expiry') {
          now = now.add(const Duration(minutes: 2));
        } else {
          final entry = await service.owner.deleteInformation(
            item.id,
            item.version,
          );
          if (transition == 'delete and restore') {
            await service.owner.restoreRecycled(entry.id);
          }
        }
        repository.ready.complete();
        await denied;
        expect(
          (await service.owner.history()).accesses.single.outcome,
          AccessOutcome.unauthorized,
        );
        await service.close();
      },
    );
  }
  test(
    'ended sessions cannot submit or query deletion proposals after integration',
    () async {
      final service = InformationService.fictional();
      addTearDown(service.close);
      final session = service.agent.openSession('chat');
      final id = await service.agent.submitDelete(session, 'demo-server', 1);
      service.agent.endSession(session);
      expect(
        () => service.agent.deleteStatus(session, id),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.submitDelete(session, 'demo-server', 1),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'end capability only terminates its own session and leaves prior terminal facts intact',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      const field = FieldRef('demo-server', 'host');
      final root = service.agent.openSessionWithEndCapability('known-root');
      final other = service.agent.openSession('other chat');
      final expired = service.agent.request(root.sessionSecret, 'Address', [
        field,
      ]);
      service.owner.approve(expired.id, [
        field,
      ], lifetime: const Duration(minutes: 1));
      final token = service.agent.claim(root.sessionSecret, expired.id).token;
      now = now.add(const Duration(minutes: 2));
      final pending = service.agent.request(root.sessionSecret, 'Next', [
        field,
      ]);
      expect(
        () => service.agent.request(root.endCapability, 'Read', [field]),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.endSessionWithCapability('known-root'),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.endSessionWithCapability(root.sessionSecret),
        throwsA(isA<AccessFailure>()),
      );
      service.agent.endSessionWithCapability(root.endCapability);
      service.agent.endSessionWithCapability(root.endCapability);
      expect(service.owner.requests.map((r) => r.state), [
        AccessRequestState.expired,
        AccessRequestState.cancelled,
      ]);
      expect(
        () => service.owner.approve(pending.id, [field]),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        service.agent.request(other, 'Still active', [field]),
        isA<RequestReceipt>(),
      );
      now = now.subtract(const Duration(hours: 1));
      await expectLater(
        service.agent.read(token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        (await service.owner.history()).grants.single.events.last.kind,
        GrantEventKind.expired,
      );
      final replacement = InformationService.fictional();
      addTearDown(replacement.close);
      expect(
        () => replacement.agent.validateSession(root.sessionSecret),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => replacement.agent.endSessionWithCapability(root.endCapability),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'ending during audit persistence prevents delivery and records the denied read',
    () async {
      final repository = WaitingAuditRepository();
      final service = InformationService(repository: repository);
      final item = await service.owner.createInformation(
        'Server',
        'Description',
        [const FieldInput('Address', 'Host', 'private.invalid')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('chat');
      final receipt = service.agent.request(session, 'Address', [field]);
      service.owner.approve(receipt.id, [field]);
      final grant = service.agent.claim(session, receipt.id);
      final reading = service.agent.read(grant.token, field);
      final denied = expectLater(reading, throwsA(isA<AccessFailure>()));
      await repository.started.future;
      service.agent.endSession(session);
      repository.ready.complete();
      await denied;
      final history = await service.owner.history();
      expect(history.grants.single.events.last.kind, GrantEventKind.ended);
      expect(history.accesses.single.outcome, AccessOutcome.unauthorized);
      await service.close();
    },
  );
  test(
    'ending a chat irreversibly cancels pending work and revokes approved reads',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('root and children');
      final approved = service.agent.request(session, 'Address', [field]);
      service.owner.approve(approved.id, [field]);
      final grant = service.agent.claim(session, approved.id);
      final pending = service.agent.request(session, 'More work', [field]);
      final denied = service.agent.request(session, 'Denied', [field]);
      service.owner.deny(denied.id);
      service.agent.endSession(session);
      service.agent.endSession(session);
      now = now.subtract(const Duration(hours: 1));
      expect(service.owner.requests.map((r) => r.state), [
        AccessRequestState.revoked,
        AccessRequestState.cancelled,
        AccessRequestState.denied,
      ]);
      expect(service.owner.requests.first.chatLabel, 'root and children');
      expect(
        () => service.owner.approve(pending.id, [field]),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.request(session, 'Again', [field]),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.claim(session, approved.id),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        (await service.owner.history()).grants.single.events.map((e) => e.kind),
        [GrantEventKind.approved, GrantEventKind.ended],
      );
    },
  );
}

class WaitingAuditRepository extends MemoryInformationRepository {
  final started = Completer<void>();
  final ready = Completer<void>();
  @override
  Future<void> saveAccessRecord(AccessRecord record) async {
    if (!started.isCompleted) started.complete();
    await ready.future;
    return super.saveAccessRecord(record);
  }
}
