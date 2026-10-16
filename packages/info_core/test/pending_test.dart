import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'polling original request never adds pending notification events',
    () async {
      final core = InformationService.fictional();
      final events = <String>[];
      final subscription = core.owner.requestSubmitted.listen(events.add);
      final session = core.agent.openSession('chat');
      final request = core.agent.request(session, 'host', [
        const FieldRef('demo-server', 'host'),
      ]);
      for (var i = 0; i < 5; i++) {
        core.agent.status(session, request.id);
        core.owner.requests;
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, [request.id]);
      expect(core.owner.requests, hasLength(1));
      await subscription.cancel();
      core.close();
    },
  );
  test(
    'first terminal decision wins including simultaneous approve and cancel',
    () async {
      final core = InformationService.fictional();
      final session = core.agent.openSession('chat');
      const fields = [FieldRef('demo-server', 'host')];
      final denied = core.agent.request(session, 'deny', fields);
      core.owner.deny(denied.id);
      expect(core.agent.status(session, denied.id)['status'], 'denied');
      expect(
        () => core.agent.claim(session, denied.id),
        throwsA(
          isA<AccessFailure>().having((e) => e.status, 'status', 'denied'),
        ),
      );
      expect(
        () => core.owner.approve(denied.id, fields),
        throwsA(isA<AccessFailure>()),
      );
      final request = core.agent.request(session, 'race', fields);
      final results = await Future.wait([
        Future(() {
          core.agent.cancel(session, request.id);
          return 'cancelled';
        }),
        Future(() {
          core.owner.approve(request.id, fields);
          return 'approved';
        }).catchError((_) => 'lost'),
      ]);
      expect(results, ['cancelled', 'lost']);
      expect(core.agent.status(session, request.id)['status'], 'cancelled');
      final approved = core.agent.request(session, 'approve first', fields);
      core.owner.approve(approved.id, fields);
      expect(
        () => core.agent.cancel(session, approved.id),
        throwsA(isA<AccessFailure>()),
      );
      expect(() => core.owner.deny(approved.id), throwsA(isA<AccessFailure>()));
      expect(core.agent.status(session, approved.id)['status'], 'approved');
    },
  );
  test(
    'owner sets lifetime for new requests without extending old requests',
    () {
      var now = DateTime.utc(2026, 10, 16);
      final core = InformationService.fictional(clock: () => now);
      final session = core.agent.openSession('chat');
      final old = core.agent.request(session, 'old', [
        const FieldRef('demo-server', 'host'),
      ]);
      core.owner.setRequestLifetime(const Duration(minutes: 5));
      final recent = core.agent.request(session, 'new', [
        const FieldRef('demo-server', 'host'),
      ]);
      now = now.add(const Duration(minutes: 5));
      expect(core.agent.status(session, recent.id)['status'], 'expired');
      expect(core.agent.status(session, old.id)['status'], 'pending');
      expect(
        () => core.owner.setRequestLifetime(Duration.zero),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'pending request expires at thirty minutes and can never be approved',
    () {
      var now = DateTime.utc(2026, 10, 16);
      final core = InformationService.fictional(clock: () => now);
      final session = core.agent.openSession('chat');
      final request = core.agent.request(session, 'Need host', [
        const FieldRef('demo-server', 'host'),
      ]);
      now = now.add(const Duration(minutes: 30));
      expect(core.agent.status(session, request.id)['status'], 'expired');
      expect(
        () => core.owner.approve(request.id, [
          const FieldRef('demo-server', 'host'),
        ]),
        throwsA(isA<AccessFailure>()),
      );
      now = now.subtract(const Duration(minutes: 10));
      expect(core.agent.status(session, request.id)['status'], 'expired');
    },
  );
}
