import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'revoke immediately denies already claimed tokens and further claims',
    () {
      final service = InformationService.fictional();
      final session = service.agent.openSession('chat');
      final request = service.agent.request(session, 'demo', [
        const FieldRef('demo-server', 'host'),
      ]);
      service.owner.approve(request.id, [
        const FieldRef('demo-server', 'host'),
      ]);
      final grant = service.agent.claim(session, request.id);
      service.owner.revoke(request.id);
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
      expect(service.agent.status(session, request.id)['status'], 'revoked');
    },
  );
}
