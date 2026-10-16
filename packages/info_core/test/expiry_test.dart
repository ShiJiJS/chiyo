import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('repeat reads never extend the absolute eight hour expiry', () {
    var now = DateTime.utc(2026, 10, 16);
    final service = InformationService.fictional(clock: () => now);
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session, 'demo', [
      const FieldRef('demo-server', 'host'),
    ]);
    service.owner.approve(request.id, [const FieldRef('demo-server', 'host')]);
    final grant = service.agent.claim(session, request.id);
    expect(grant.expiresAt, DateTime.utc(2026, 10, 16, 8));
    now = DateTime.utc(2026, 10, 16, 7, 59);
    expect(
      service.agent.read(grant.token, const FieldRef('demo-server', 'host')),
      'demo.example.invalid',
    );
    now = DateTime.utc(2026, 10, 16, 8);
    expect(
      () => service.agent.read(
        grant.token,
        const FieldRef('demo-server', 'host'),
      ),
      throwsA(isA<AccessFailure>()),
    );
    expect(
      () => service.agent.claim(session, request.id),
      throwsA(isA<AccessFailure>()),
    );
    expect(service.agent.status(session, request.id)['status'], 'expired');
  });
}
