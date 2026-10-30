import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

Matcher failure(String status) =>
    throwsA(isA<AccessFailure>().having((e) => e.status, 'status', status));

void main() {
  late DateTime now;
  late InformationService service;
  late String session;
  const host = FieldRef('demo-server', 'host');
  const user = FieldRef('demo-server', 'username');
  setUp(() {
    now = DateTime.utc(2026, 10, 30);
    service = InformationService.fictional(clock: () => now);
    session = service.agent.openSession('synthetic');
  });
  tearDown(() => service.close());

  test('same operation preserves request, deadline and single event', () async {
    final events = <String>[];
    final sub = service.owner.requestSubmitted.listen(events.add);
    addTearDown(sub.cancel);
    final first = service.agent.request(session, 'inspect', [
      host,
      user,
    ], operationId: 'inspect-1');
    final original = service.agent.status(session, first.id);
    now = now.add(const Duration(minutes: 2));
    await service.owner.setRequestLifetime(const Duration(minutes: 5));
    final repeat = service.agent.request(session, 'inspect', [
      user,
      host,
      host,
    ], operationId: 'inspect-1');
    expect(repeat.id, first.id);
    expect(service.agent.status(session, repeat.id), original);
    await Future<void>.delayed(Duration.zero);
    expect(events, [first.id]);
    expect(service.agent.requestOperationStatus(session, 'inspect-1'), {
      ...original,
      'operationId': 'inspect-1',
    });
    expect(
      () => service.agent.request(session, 'changed', [
        host,
        user,
      ], operationId: 'inspect-1'),
      failure('operation_conflict'),
    );
    expect(
      () => service.agent.request(session, 'inspect', [
        host,
      ], operationId: 'inspect-1'),
      failure('operation_conflict'),
    );
    final different = service.agent.request(session, 'inspect', [
      host,
      user,
    ], operationId: 'inspect-2');
    expect(different.id, isNot(first.id));
  });

  test(
    'retry after denial or expiry never creates or renews pending request',
    () {
      final denied = service.agent.request(session, 'inspect', [
        host,
      ], operationId: 'deny-1');
      service.owner.deny(denied.id);
      expect(
        service.agent.request(session, 'inspect', [
          host,
        ], operationId: 'deny-1').id,
        denied.id,
      );
      expect(
        service.agent.requestOperationStatus(session, 'deny-1')['status'],
        'denied',
      );
      service.agent.request(session, 'inspect', [
        host,
      ], operationId: 'expire-1');
      now = now.add(const Duration(hours: 1));
      service.agent.request(session, 'inspect', [
        host,
      ], operationId: 'expire-1');
      expect(
        service.agent.requestOperationStatus(session, 'expire-1')['status'],
        'expired',
      );
      expect(service.owner.requests, hasLength(2));
    },
  );

  test(
    'lookup is session scoped and cannot recover ended or reopened capability',
    () async {
      final receipt = service.agent.request(session, 'inspect', [
        host,
      ], operationId: 'op-1');
      final other = service.agent.openSession('same label is not identity');
      expect(
        service.agent.requestOperationStatus(other, 'op-1')['status'],
        'not_found',
      );
      expect(
        () => service.agent.requestOperationStatus(receipt.id, 'op-1'),
        failure('unauthorized'),
      );
      service.agent.endSession(session);
      expect(
        () => service.agent.requestOperationStatus(session, 'op-1'),
        failure('unauthorized'),
      );
      expect(
        () => service.agent.request(session, 'inspect', [
          host,
        ], operationId: 'op-1'),
        failure('unauthorized'),
      );
      await service.close();
      expect(
        () => service.agent.requestOperationStatus(other, 'op-1'),
        failure('unauthorized'),
      );
    },
  );

  test(
    'legacy callers remain independent and operation identifiers are validated',
    () {
      final a = service.agent.request(session, 'inspect', [host]);
      final b = service.agent.request(session, 'inspect', [host]);
      expect(a.id, isNot(b.id));
      for (final id in ['', 'bad id', 'x' * 129, 'line\nbreak']) {
        expect(
          () => service.agent.request(session, 'inspect', [
            host,
          ], operationId: id),
          failure('invalid_request'),
        );
        expect(
          () => service.agent.requestOperationStatus(session, id),
          failure('invalid_request'),
        );
      }
      expect(service.owner.requests, hasLength(2));
    },
  );
}
