import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'extending and replacing template definitions leaves existing information and grants unchanged',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final original = await service.owner.createTemplate('Server', '', [
        const TemplateFieldInput('Address', 'Host'),
      ]);
      final item = await service.owner.createInformationFromTemplate(
        original.id,
        1,
        'First',
        '',
        {original.fields.single.id: 'first.invalid'},
      );
      final ref = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('templates');
      final request = service.agent.request(session, 'connect', [ref]);
      service.owner.approve(request.id, [ref]);
      final grant = service.agent.claim(session, request.id);
      final expanded = await service.owner
          .updateTemplate(original.id, 1, 'Server', 'Extended form', [
            TemplateFieldInput(
              'Address',
              'Host',
              definitionId: original.fields.single.id,
            ),
            const TemplateFieldInput(
              'Notes',
              'Operations',
              kind: FieldKind.textNote,
            ),
          ]);
      expect(expanded.fields.first.id, original.fields.single.id);
      expect(service.owner.information.single.fields, hasLength(1));
      expect(service.agent.read(grant.token, ref), 'first.invalid');
      final next = await service.owner
          .createInformationFromTemplate(expanded.id, 2, 'Second', '', {
            expanded.fields.first.id: 'second.invalid',
            expanded.fields.last.id: 'private new note',
          });
      expect(
        () => service.agent.read(
          grant.token,
          FieldRef(next.id, next.fields.last.id),
        ),
        throwsA(isA<AccessFailure>()),
      );
      final replaced = await service.owner
          .updateTemplate(expanded.id, 2, 'Server', '', [
            TemplateFieldInput(
              'Password',
              'Different meaning',
              definitionId: expanded.fields.first.id,
            ),
          ]);
      expect(replaced.fields.single.id, isNot(original.fields.single.id));
      expect(service.owner.information.first.fields.single.name, 'Address');
      expect(service.agent.read(grant.token, ref), 'first.invalid');
      await expectLater(
        service.owner.createInformationFromTemplate(
          original.id,
          1,
          'Stale draft',
          '',
          {original.fields.single.id: 'old'},
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'template_changed',
          ),
        ),
      );
      expect(service.owner.information, hasLength(2));
    },
  );
  test(
    'owner saves template input explicitly as independent information fields',
    () async {
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      addTearDown(service.close);
      final template = await service.owner
          .createTemplate('Server', 'Connection structure', [
            const TemplateFieldInput('Address', 'Server host'),
            const TemplateFieldInput(
              'Notes',
              'Operational notes',
              kind: FieldKind.textNote,
            ),
          ]);
      expect(service.owner.information, isEmpty);
      expect(service.agent.catalog(), isEmpty);
      final item = await service.owner.createInformationFromTemplate(
        template.id,
        template.version,
        'Fictional server',
        'Public description',
        {
          template.fields.first.id: 'fictional.invalid',
          template.fields.last.id: 'private fictional notes',
        },
      );
      expect(item.fields.map((f) => f.name), ['Address', 'Notes']);
      expect(item.fields.last.kind, FieldKind.textNote);
      expect(
        item.fields
            .map((f) => f.id)
            .toSet()
            .intersection(template.fields.map((f) => f.id).toSet()),
        isEmpty,
      );
      expect(
        service.agent.catalog().toString(),
        isNot(contains('private fictional notes')),
      );
    },
  );
}
