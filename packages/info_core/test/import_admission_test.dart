import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late InformationService service;
  late String session;
  var digest = 'a' * 64;
  void configure() => service.owner.configureInformationTemplates(
    () => InformationTemplateCatalog(
      version: 1,
      plugins: [],
      templates: [
        InformationTemplateDescription(
          id: 'note',
          name: '说明',
          version: '1',
          digest: digest,
          enabled: true,
          definition: {
            'id': 'note',
            'name': '说明',
            'instructions': '填写源资料中的事实。',
            'fields': [
              {'key': 'body', 'label': '正文', 'type': 'text'},
            ],
            'sections': [],
            'relations': [
              {'key': 'related', 'label': '相关资料'},
            ],
            'example': {
              'name': '示例',
              'values': {'body': '示例正文'},
            },
          },
        ),
      ],
    ),
  );
  ImportItemInput input(String key, {String? target, String? proposal}) =>
      ImportItemInput(
        key,
        '',
        [],
        key: key,
        templateId: 'note',
        templateVersion: '1',
        templateDigest: digest,
        values: {'body': 'PRIVATE-$key'},
        pendingRelations: {
          if (target != null)
            'related': [
              ImportPendingReference(
                'information',
                target,
                proposalId: proposal,
              ),
            ],
        },
      );
  ImportProposal proposal(String id) =>
      service.owner.importProposals.singleWhere((p) => p.id == id);
  setUp(() {
    digest = 'a' * 64;
    service = InformationService(repository: MemoryInformationRepository());
    configure();
    session = service.agent.openSession('合成录入');
  });
  tearDown(() => service.close());
  test(
    'unrelated approved item saves now; fully approved mutual references save together later',
    () async {
      final id = await service.agent.submitImport(session, [
        input('a', target: 'b'),
        input('b', target: 'a'),
        input('unrelated'),
      ]);
      final first = proposal(id);
      final receipts = await service.owner.confirmImport(id, first.version, [
        first.items[0],
        first.items[2],
      ]);
      expect(receipts.length, 1);
      expect(service.owner.information.single.name, 'unrelated');
      expect(proposal(id).approvedKeys, {'a'});
      expect(proposal(id).items.map((i) => i.key), ['a', 'b']);
      expect(
        service.owner
            .importAdmission(id)
            .singleWhere((s) => s.key == 'a')
            .state,
        'approved',
      );
      expect(
        service.agent.importStatus(session, id).toString(),
        isNot(contains('PRIVATE')),
      );
      final second = proposal(id);
      await service.owner.confirmImport(id, second.version, [
        second.items.singleWhere((i) => i.key == 'b'),
      ]);
      expect(service.owner.information.length, 3);
      final a = service.owner.information.singleWhere((i) => i.name == 'a'),
          b = service.owner.information.singleWhere((i) => i.name == 'b');
      expect(a.layout!.relations['related']!.single.id, b.id);
      expect(b.layout!.relations['related']!.single.id, a.id);
      expect(proposal(id).state, ImportProposalState.confirmed);
      expect(proposal(id).items, isEmpty);
      expect(
        service.owner.importAdmission(id).every((s) => s.state == 'admitted'),
        true,
      );
      expect(
        () => service.agent.read(id, FieldRef(a.id, a.fields.single.id)),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'cross-proposal rejection keeps the approved dependent for repair, and revision needs new approval',
    () async {
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final dependent = await service.agent.submitImport(session, [
        input('dependent', target: 'target', proposal: target),
      ]);
      await service.owner.confirmImport(
        dependent,
        1,
        proposal(dependent).items,
      );
      expect(proposal(dependent).awaitingAdmission, true);
      expect(service.owner.information, isEmpty);
      await service.owner.rejectImport(target, 1);
      final status = service.owner.importAdmission(dependent).single;
      expect(status.state, 'needs_attention');
      expect(status.reason, contains('已被拒绝'));
      expect(proposal(dependent).approvedKeys, {'dependent'});
      expect(
        proposal(dependent).items.single.values['body'],
        'PRIVATE-dependent',
      );
      await service.agent.reviseImport(
        session,
        dependent,
        proposal(dependent).version,
        [input('dependent')],
      );
      expect(proposal(dependent).approvedKeys, isEmpty);
      expect(service.owner.information, isEmpty);
      await service.owner.confirmImport(
        dependent,
        proposal(dependent).version,
        proposal(dependent).items,
      );
      expect(service.owner.information.single.name, 'dependent');
      expect(
        service.owner.information.single.layout!.relations.values.expand(
          (r) => r,
        ),
        isEmpty,
      );
    },
  );
  test(
    'approval in another proposal atomically admits a waiting dependent',
    () async {
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final dependent = await service.agent.submitImport(session, [
        input('dependent', target: 'target', proposal: target),
      ]);
      await service.owner.confirmImport(
        dependent,
        1,
        proposal(dependent).items,
      );
      await service.owner.confirmImport(target, 1, proposal(target).items);
      final saved = service.owner.information.singleWhere(
        (i) => i.name == 'target',
      );
      expect(
        service.owner.information
            .singleWhere((i) => i.name == 'dependent')
            .layout!
            .relations['related']!
            .single
            .id,
        saved.id,
      );
      expect(proposal(dependent).state, ImportProposalState.confirmed);
      expect(proposal(dependent).version, 3);
    },
  );
  test(
    'cycles across separately submitted proposals resolve after a reviewed revision',
    () async {
      final a = await service.agent.submitImport(session, [input('a')]);
      final b = await service.agent.submitImport(session, [
        input('b', target: 'a', proposal: a),
      ]);
      await service.agent.reviseImport(session, a, 1, [
        input('a', target: 'b', proposal: b),
      ]);
      await service.owner.confirmImport(
        a,
        proposal(a).version,
        proposal(a).items,
      );
      expect(service.owner.information, isEmpty);
      await service.owner.confirmImport(
        b,
        proposal(b).version,
        proposal(b).items,
      );
      expect(service.owner.information.length, 2);
      final one = service.owner.information.singleWhere((i) => i.name == 'a'),
          two = service.owner.information.singleWhere((i) => i.name == 'b');
      expect(one.layout!.relations['related']!.single.id, two.id);
      expect(two.layout!.relations['related']!.single.id, one.id);
    },
  );
  test(
    'a reviewed modification waits without touching original content and commits with its new referenced material',
    () async {
      final initial = await service.agent.submitImport(session, [
        input('existing'),
      ]);
      final created = await service.owner.confirmImport(
        initial,
        1,
        proposal(initial).items,
      );
      final old = service.owner.information.single;
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final update = await service.agent.submitUpdate(
        session,
        UpdateInput(
          created.single.id,
          1,
          [],
          templateId: 'note',
          templateVersion: '1',
          templateDigest: digest,
          values: {'body': 'NEW-REVIEWED'},
          pendingRelations: {
            'related': [
              ImportPendingReference(
                'information',
                'target',
                proposalId: target,
              ),
            ],
          },
        ),
      );
      expect(await service.owner.confirmUpdate(update, 1), isNull);
      expect(
        service.owner.information.single.fields.single.value,
        'PRIVATE-existing',
      );
      expect(service.owner.informationRevisions, isEmpty);
      expect(service.owner.updateAdmission(update).state, 'approved');
      expect(
        service.agent.updateStatus(session, update)['status'],
        'approved_awaiting_admission',
      );
      await service.owner.confirmImport(target, 1, proposal(target).items);
      final current = service.owner.information.singleWhere(
            (i) => i.id == old.id,
          ),
          linked = service.owner.information.singleWhere(
            (i) => i.name == 'target',
          );
      expect(current.version, 2);
      expect(current.fields.single.id, old.fields.single.id);
      expect(current.fields.single.value, 'NEW-REVIEWED');
      expect(current.layout!.relations['related']!.single.id, linked.id);
      expect(
        service.owner.informationRevisions.single.item.fields.single.value,
        'PRIVATE-existing',
      );
      expect(
        service.owner.updateProposals.single.state,
        UpdateProposalState.confirmed,
      );
      expect(service.owner.updateProposals.single.version, 3);
      expect(service.owner.updateProposals.single.input.values, isEmpty);
    },
  );
  test(
    'template updates require complete values and retain independent owner-added fields',
    () async {
      final seed = await service.agent.submitImport(session, [
        input('existing'),
      ]);
      await service.owner.confirmImport(seed, 1, proposal(seed).items);
      final original = service.owner.information.single;
      final extra = await service.agent.submitUpdate(
        session,
        UpdateInput(original.id, 1, [
          const FieldChange.add(FieldInput('主人补充字段', '', 'OWNER-EXTRA')),
        ]),
      );
      await service.owner.confirmUpdate(extra, 1);
      final current = service.owner.information.single;
      final bodyOnly = await service.agent.submitUpdate(
        session,
        UpdateInput(
          original.id,
          current.version,
          [],
          templateId: 'note',
          templateVersion: '1',
          templateDigest: digest,
          values: {'body': 'UPDATED-BODY'},
        ),
      );
      await service.owner.confirmUpdate(bodyOnly, 1);
      expect(
        service.owner.information.single.fields
            .singleWhere((f) => f.name == '主人补充字段')
            .value,
        'OWNER-EXTRA',
      );
      expect(
        service.owner.information.single.fields
            .singleWhere((f) => f.name == '正文')
            .value,
        'UPDATED-BODY',
      );
      await expectLater(
        service.agent.submitUpdate(
          session,
          UpdateInput(
            original.id,
            3,
            [],
            templateId: 'note',
            templateVersion: '1',
            templateDigest: digest,
            values: const {},
          ),
        ),
        throwsA(
          isA<InformationTemplateInputFailure>().having(
            (e) => e.fieldErrors.keys,
            'keys',
            contains('body'),
          ),
        ),
      );
    },
  );
  test('a deferred modification never overwrites later owner edits', () async {
    final initial = await service.agent.submitImport(session, [
      input('existing'),
    ]);
    await service.owner.confirmImport(initial, 1, proposal(initial).items);
    final old = service.owner.information.single;
    final target = await service.agent.submitImport(session, [input('target')]);
    final update = await service.agent.submitUpdate(
      session,
      UpdateInput(
        old.id,
        1,
        [],
        templateId: 'note',
        templateVersion: '1',
        templateDigest: digest,
        values: {'body': 'AI-REVIEWED'},
        pendingRelations: {
          'related': [
            ImportPendingReference('information', 'target', proposalId: target),
          ],
        },
      ),
    );
    await service.owner.confirmUpdate(update, 1);
    await service.owner.correctValue(
      FieldRef(old.id, old.fields.single.id),
      'OWNER-EDIT',
    );
    await service.owner.confirmImport(target, 1, proposal(target).items);
    expect(
      service.owner.information
          .singleWhere((i) => i.id == old.id)
          .fields
          .single
          .value,
      'OWNER-EDIT',
    );
    expect(service.owner.updateProposals.single.approved, true);
    expect(service.owner.updateAdmission(update).state, 'needs_attention');
    expect(
      service.owner.updateProposals.single.input.values['body'],
      'AI-REVIEWED',
    );
  });
  test(
    'another chat cannot address, observe or revise private pending candidates',
    () async {
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final other = service.agent.openSession('另一会话');
      await expectLater(
        service.agent.submitImport(other, [
          input('dependent', target: 'target', proposal: target),
        ]),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'invalid_reference',
          ),
        ),
      );
      await expectLater(
        service.agent.reviseImport(other, target, 1, [input('target')]),
        throwsA(isA<AccessFailure>()),
      );
      expect(
        () => service.agent.importStatus(other, target),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.submitImport(session, [input('a'), input('a')]),
        throwsA(isA<AccessFailure>()),
      );
    },
  );
  test(
    'changed plugin cannot release previously approved candidates using stale definitions',
    () async {
      final target = await service.agent.submitImport(session, [
        input('target'),
      ]);
      final dependent = await service.agent.submitImport(session, [
        input('dependent', target: 'target', proposal: target),
      ]);
      await service.owner.confirmImport(
        dependent,
        1,
        proposal(dependent).items,
      );
      digest = 'b' * 64;
      await service.agent.reviseImport(session, target, 1, [input('target')]);
      await service.owner.confirmImport(
        target,
        proposal(target).version,
        proposal(target).items,
      );
      expect(service.owner.information.single.name, 'target');
      expect(proposal(dependent).awaitingAdmission, true);
      expect(
        service.owner.importAdmission(dependent).single.state,
        'needs_attention',
      );
      await service.agent.reviseImport(
        session,
        dependent,
        proposal(dependent).version,
        [input('dependent', target: 'target', proposal: target)],
      );
      await service.owner.confirmImport(
        dependent,
        proposal(dependent).version,
        proposal(dependent).items,
      );
      expect(service.owner.information.length, 2);
    },
  );
}
