import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() async {
  test('expiry observed by read cannot revive after clock rollback', () async {
    var now = DateTime.utc(2026, 10, 16);
    final service = InformationService.fictional(clock: () => now);
    addTearDown(service.close);
    const field = FieldRef('demo-server', 'host');
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session, 'demo', [field]);
    service.owner.approve(request.id, [field]);
    final grant = service.agent.claim(session, request.id);
    now = DateTime.utc(2026, 10, 16, 2);
    expect(
      () => service.agent.read(grant.token, field),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    now = DateTime.utc(2026, 10, 16, 1);
    expect(
      () => service.agent.read(grant.token, field),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(
      () => service.agent.claim(session, request.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(service.agent.status(session, request.id)['status'], 'expired');
  });

  test('expiry observed by claim cannot revive after clock rollback', () async {
    var now = DateTime.utc(2026, 10, 16);
    final service = InformationService.fictional(clock: () => now);
    addTearDown(service.close);
    const field = FieldRef('demo-server', 'host');
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session, 'demo', [field]);
    service.owner.approve(request.id, [field]);
    final grant = service.agent.claim(session, request.id);
    now = DateTime.utc(2026, 10, 16, 2);
    expect(
      () => service.agent.claim(session, request.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    now = DateTime.utc(2026, 10, 16, 1);
    expect(
      () => service.agent.claim(session, request.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(
      () => service.agent.read(grant.token, field),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(service.agent.status(session, request.id)['status'], 'expired');
  });

  test(
    'expiry observed by status cannot revive after clock rollback',
    () async {
      var now = DateTime.utc(2026, 10, 16);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      const field = FieldRef('demo-server', 'host');
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'demo', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      now = DateTime.utc(2026, 10, 16, 2);
      expect(service.agent.status(session, request.id)['status'], 'expired');
      now = DateTime.utc(2026, 10, 16, 1);
      expect(service.agent.status(session, request.id)['status'], 'expired');
      expect(
        () => service.agent.claim(session, request.id),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'unauthorized',
          ),
        ),
      );
      expect(
        () => service.agent.read(grant.token, field),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'unauthorized',
          ),
        ),
      );
    },
  );

  test('repeat reads never extend the absolute two hour expiry', () async {
    var now = DateTime.utc(2026, 10, 16);
    final service = InformationService.fictional(clock: () => now);
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session, 'demo', [
      const FieldRef('demo-server', 'host'),
    ]);
    service.owner.approve(request.id, [const FieldRef('demo-server', 'host')]);
    final grant = service.agent.claim(session, request.id);
    expect(grant.expiresAt, DateTime.utc(2026, 10, 16, 2));
    now = DateTime.utc(2026, 10, 16, 1, 59);
    expect(
      await service.agent.read(
        grant.token,
        const FieldRef('demo-server', 'host'),
      ),
      'demo.example.invalid',
    );
    now = DateTime.utc(2026, 10, 16, 2);
    expect(
      () => service.agent.read(
        grant.token,
        const FieldRef('demo-server', 'host'),
      ),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(
      () => service.agent.claim(session, request.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
    expect(service.agent.status(session, request.id)['status'], 'expired');
  });
}
