import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test('requests stay pending and session labels cannot claim credentials', () {
    final service = InformationService.fictional();
    final session = service.agent.openSession('chat-a');
    final receipt = service.agent.request(session, 'Need address', [
      const FieldRef('demo-server', 'host'),
    ]);
    expect(service.agent.status(session, receipt.id)['status'], 'pending');
    expect(
      () => service.agent.claim(session, receipt.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'pending'),
      ),
    );
    expect(
      () => service.agent.claim('chat-a', receipt.id),
      throwsA(
        isA<AccessFailure>().having((e) => e.status, 'status', 'unauthorized'),
      ),
    );
  });
}
