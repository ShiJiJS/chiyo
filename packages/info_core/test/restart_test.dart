import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('shutdown and a new service cannot revive old sessions or grants', () {
    final service = InformationService.fictional();
    final session = service.agent.openSession('chat');
    final request = service.agent.request(session, 'demo', [
      const FieldRef('demo-server', 'host'),
    ]);
    service.owner.approve(request.id, [const FieldRef('demo-server', 'host')]);
    final token = service.agent.claim(session, request.id).token;
    service.close();
    expect(
      () => service.agent.read(token, const FieldRef('demo-server', 'host')),
      throwsA(isA<AccessFailure>()),
    );
    expect(
      () => service.agent.openSession('chat'),
      throwsA(isA<AccessFailure>()),
    );
    final restarted = InformationService.fictional();
    expect(
      () => restarted.agent.read(token, const FieldRef('demo-server', 'host')),
      throwsA(isA<AccessFailure>()),
    );
    expect(
      () => restarted.agent.claim(session, request.id),
      throwsA(isA<AccessFailure>()),
    );
  });
}
