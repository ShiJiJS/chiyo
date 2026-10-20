import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'audit retention removes ended organization facts without ending new tasks',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final service = InformationService.fictional(clock: () => now);
      addTearDown(service.close);
      final session = service.agent.openSession('Organization chat');
      final old = await service.agent.requestOrganization(
        session,
        'Old result',
        ['demo-server'],
      );
      await service.owner.approveOrganization(old.id, ['demo-server']);
      await service.agent.submitOrganization(session, old.id, []);
      now = now.add(const Duration(days: 31));
      final recent = await service.agent.requestOrganization(
        session,
        'Current work',
        ['demo-server'],
      );
      await service.owner.approveOrganization(recent.id, ['demo-server']);
      expect(
        (await service.owner.history()).toJson()['organizations'],
        hasLength(2),
      );
      final preview = await service.owner.previewAuditRetention(30);
      expect(preview.organizations, 1);
      await expectLater(
        service.owner.setAuditRetention(30),
        throwsA(isA<AccessFailure>()),
      );
      await service.owner.setAuditRetention(30, confirmation: preview);
      expect((await service.owner.history()).organizations.map((t) => t.id), [
        recent.id,
      ]);
      expect(
        service.owner.organizationState(service.owner.organizationTasks.single),
        OrganizationTaskState.active,
      );
      await service.owner.setAuditRetention(365);
      expect((await service.owner.history()).organizations.map((t) => t.id), [
        recent.id,
      ]);
      expect(
        await service.agent.organizationMetadata(session, recent.id),
        isNotEmpty,
      );
    },
  );
  test('deleting a template preserves information created with it', () async {
    final service = InformationService(
      repository: MemoryInformationRepository(),
    );
    final template = await service.owner.createTemplate(
      'Server',
      'Structure only',
      [const TemplateFieldInput('Host', 'Address')],
    );
    final item = await service.owner.createInformationFromTemplate(
      template.id,
      template.version,
      'Actual server',
      '',
      {template.fields.single.id: 'private.invalid'},
    );
    await service.owner.deleteTemplate(template.id, template.version);
    expect(service.owner.templates, isEmpty);
    expect(service.owner.information.single.id, item.id);
    expect(
      service.owner.information.single.fields.single.value,
      'private.invalid',
    );
    await service.close();
  });
  test(
    'organization history retains the approved names and actual submit time',
    () async {
      final service = InformationService.fictional();
      final session = service.agent.openSession('Organization chat');
      final request = await service.agent.requestOrganization(
        session,
        'Organize services',
        ['demo-server'],
      );
      await service.owner.approveOrganization(request.id, ['demo-server']);
      await service.agent.organizationMetadata(session, request.id);
      await service.agent.submitOrganization(session, request.id, []);
      await service.owner.updateCatalogMetadata(
        'demo-server',
        name: 'Renamed',
        description: '',
        fieldDescriptions: {'host': 'Host', 'username': 'Login'},
      );
      final fact = service.owner.organizationTasks.single;
      expect(fact.itemNames['demo-server'], 'Fictional demo server');
      expect(fact.completedAt, isNotNull);
      await service.close();
    },
  );
}
