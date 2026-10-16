import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

class FailingSettings extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> writeSetting(String key, int value) async {
    if (fail) throw StateError('synthetic setting failure');
    await super.writeSetting(key, value);
  }
}

void main() {
  test('handled inbox snapshot exposes the actual decided lifetime', () async {
    final service = InformationService.fictional(
      clock: () => DateTime.utc(2026, 10, 17),
    );
    addTearDown(service.close);
    final session = service.agent.openSession('Lifetime');
    final request = service.agent.request(session, 'Read', [
      const FieldRef('demo-server', 'host'),
    ]);
    expect(service.owner.requests.single.grantLifetime, isNull);
    service.owner.approve(request.id, [
      const FieldRef('demo-server', 'host'),
    ], lifetime: const Duration(minutes: 15));
    expect(
      service.owner.requests.single.grantLifetime,
      const Duration(minutes: 15),
    );
    service.owner.revoke(request.id);
    expect(
      service.owner.requests.single.grantLifetime,
      const Duration(minutes: 15),
    );
  });
  test(
    'theme survives reopening and failed changes keep the saved preference',
    () async {
      final repository = FailingSettings();
      final service = InformationService(repository: repository);
      expect(service.owner.colorTheme, DesktopColorTheme.purple);
      await service.owner.setColorTheme(DesktopColorTheme.green);
      repository.fail = true;
      await expectLater(
        service.owner.setColorTheme(DesktopColorTheme.mono),
        throwsStateError,
      );
      expect(service.owner.colorTheme, DesktopColorTheme.green);
      await service.close();
      final reopened = InformationService(repository: repository);
      expect(reopened.owner.colorTheme, DesktopColorTheme.green);
      repository.fail = false;
      await reopened.owner.setColorTheme(DesktopColorTheme.blue);
      expect(reopened.owner.colorTheme, DesktopColorTheme.blue);
      await reopened.close();
    },
  );
  test(
    'owner searches and pages a stable mixed inbox without losing request identity',
    () async {
      var now = DateTime.utc(2026, 10, 17);
      final service = InformationService.fictional(clock: () => now);
      final session = service.agent.openSession('Deployment chat');
      final ids = <String>[];
      for (var i = 0; i < 240; i++) {
        ids.add(
          service.agent.request(session, 'Deployment $i', [
            const FieldRef('demo-server', 'host'),
          ]).id,
        );
        now = now.add(const Duration(seconds: 1));
      }
      final first = service.owner.queryInbox(limit: 20);
      expect(first.total, 240);
      expect(first.entries.map((e) => e.id), ids.reversed.take(20));
      final second = service.owner.queryInbox(offset: 20, limit: 20);
      expect(second.entries.map((e) => e.id), ids.reversed.skip(20).take(20));
      expect(
        service.owner.queryInbox(search: 'deployment 239').entries.single.id,
        ids.last,
      );
      expect(service.owner.queryInbox(search: 'missing').entries, isEmpty);
      expect(
        service.owner.queryInbox(focusRequestId: ids.first, limit: 20).offset,
        220,
      );
      service.owner.deny(ids.last);
      expect(
        service.owner.queryInbox(filter: InboxFilter.handled).entries.single.id,
        ids.last,
      );
      expect(service.owner.queryInbox(filter: InboxFilter.pending).total, 239);
      final organization = await service.agent.requestOrganization(
        session,
        'Organization plan',
        ['demo-server'],
      );
      expect(
        service.owner
            .queryInbox(search: 'Organization plan')
            .entries
            .single
            .organization!
            .id,
        organization.id,
      );
      await service.owner.approveOrganization(organization.id, ['demo-server']);
      await service.agent.submitOrganization(session, organization.id, []);
      expect(
        service.owner
            .queryInbox(
              search: 'Organization plan',
              filter: InboxFilter.handled,
            )
            .entries
            .single
            .organizationState,
        OrganizationTaskState.confirmed,
      );
      expect(
        () => service.owner.queryInbox(limit: 101),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.owner.queryInbox(offset: -1),
        throwsA(isA<AccessFailure>()),
      );
      await service.close();
      expect(() => service.owner.queryInbox(), throwsA(isA<AccessFailure>()));
    },
  );
}
