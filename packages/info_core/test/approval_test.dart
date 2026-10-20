import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() async {
  test('owner approves one fixed field and only that field can be read', () async {
    final service = InformationService.fictional();
    final session = service.agent.openSession('chat-a');
    final receipt = service.agent.request(session, 'Need connection details', [
      const FieldRef('demo-server', 'host'),
      const FieldRef('demo-server', 'username'),
    ]);
    service.owner.approve(receipt.id, [const FieldRef('demo-server', 'host')]);
    final grant = service.agent.claim(session, receipt.id);
    expect(
      await service.agent.read(grant.token, const FieldRef('demo-server', 'host')),
      'demo.example.invalid',
    );
    expect(
      () => service.agent.read(
        grant.token,
        const FieldRef('demo-server', 'username'),
      ),
      throwsA(isA<AccessFailure>()),
    );
    expect(grant.fields, [const FieldRef('demo-server', 'host')]);
    expect(
      service.agent.status(session, receipt.id).toString(),
      isNot(contains(grant.token)),
    );
    final impostor = service.agent.openSession('chat-a');
    expect(
      () => service.agent.claim(impostor, receipt.id),
      throwsA(isA<AccessFailure>()),
    );
  });
}
