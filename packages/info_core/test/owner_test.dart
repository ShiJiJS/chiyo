import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'owner can inspect pending purpose and fixed approved scope without tokens',
    () {
      final service = InformationService.fictional();
      final secret = service.agent.openSession('chat-a');
      final request = service.agent.request(secret, 'Need address', [
        const FieldRef('demo-server', 'host'),
      ]);
      final pending = service.owner.requests.single;
      expect(pending.chatLabel, 'chat-a');
      expect(pending.purpose, 'Need address');
      expect(pending.state, AccessRequestState.pending);
      expect(pending.toString(), isNot(contains(secret)));
      service.owner.approve(request.id, [
        const FieldRef('demo-server', 'host'),
      ]);
      expect(service.owner.requests.single.state, AccessRequestState.approved);
      expect(service.owner.requests.single.approvedFields, [
        const FieldRef('demo-server', 'host'),
      ]);
    },
  );
}
