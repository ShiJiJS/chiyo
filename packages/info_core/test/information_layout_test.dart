import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'layout copies nested descriptors and rejects invalid identity maps',
    () {
      final fields = <String, String>{'name': 'f1'};
      final snapshot = <String, Object?>{
        'definition': <String, Object?>{'id': 'profile'},
      };
      final layout = InformationLayout(
        typeId: 'profile',
        snapshot: snapshot,
        fieldIds: fields,
      );
      fields['name'] = 'different';
      (snapshot['definition'] as Map)['id'] = 'different';
      expect(layout.fieldIds['name'], 'f1');
      expect((layout.snapshot['definition'] as Map)['id'], 'profile');
      expect(
        () => (layout.snapshot['definition'] as Map)['id'] = 'mutable',
        throwsUnsupportedError,
      );
      expect(
        InformationLayout.fromJson(
          jsonDecode(jsonEncode(layout.toJson())) as Map<String, dynamic>,
        ).toJson(),
        layout.toJson(),
      );
      for (final invalid in [
        {...layout.toJson(), 'version': 1.0},
        {
          ...layout.toJson(),
          'fieldIds': {'name': 'f1', 'age': 'f1'},
        },
        {
          ...layout.toJson(),
          'fieldIds': {'name': ''},
        },
        {...layout.toJson(), 'extra': true},
        {
          ...layout.toJson(),
          'relations': {
            'related': [
              {'kind': 'grant', 'id': 'g1'},
            ],
          },
        },
      ]) {
        expect(
          () => InformationLayout.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'slot mapping never extends a grant when adding or replacing fields',
    () async {
      final repo = MemoryInformationRepository();
      final service = InformationService(repository: repo);
      addTearDown(service.close);
      await service.owner.saveInformationRecord(
        'create',
        InformationDraftInput(
          name: '档案',
          description: '',
          fields: const [InformationDraftField.text('姓名', '', '合成人物')],
          layout: InformationDraftLayout(
            InformationLayout(
              typeId: 'profile',
              snapshot: const {},
              fieldIds: const {},
            ),
            ['name'],
          ),
        ),
      );
      final original = repo.items.single;
      final oldRef = FieldRef(original.id, original.fields.single.id);
      final session = service.agent.openSession('合成聊天');
      final request = service.agent.request(session, '读取姓名', [oldRef]);
      service.owner.approve(request.id, [oldRef]);
      final token = service.agent.claim(session, request.id).token;
      final next = await service.owner.editInformation(
        original.id,
        original.version,
        name: original.name,
        description: original.description,
        changes: [
          FieldChange.replace(
            oldRef.fieldId,
            const FieldInput('账号', '', 'synthetic-account'),
          ),
        ],
      );
      final newId = next.fields.single.id;
      expect(next.layout!.fieldIds['name'], newId);
      expect(newId, isNot(oldRef.fieldId));
      await expectLater(
        service.agent.read(token, oldRef),
        throwsA(isA<AccessFailure>()),
      );
      await expectLater(
        service.agent.read(token, FieldRef(next.id, newId)),
        throwsA(isA<AccessFailure>()),
      );
      final withExtra = await service.owner.editInformation(
        next.id,
        next.version,
        name: next.name,
        description: next.description,
        changes: const [
          FieldChange.add(FieldInput('附加说明', '', 'synthetic-note')),
        ],
      );
      expect(withExtra.layout!.fieldIds, next.layout!.fieldIds);
      expect(withExtra.fields, hasLength(2));
      await expectLater(
        service.agent.read(token, FieldRef(next.id, withExtra.fields.last.id)),
        throwsA(isA<AccessFailure>()),
      );
    },
  );

  test(
    'recovery preserves repurposed slots and does not erase historical mappings',
    () {
      final old = InformationLayout(
        typeId: 'profile',
        snapshot: const {},
        fieldIds: const {'name': 'old-field', 'period': 'period'},
      );
      final current = old.withFieldIds({
        'name': 'new-meaning',
        'period': 'period',
      });
      final restored = current.restoreBindings(old, {
        'old-field': 'restored-field',
      });
      expect(restored.fieldIds, {'name': 'new-meaning', 'period': 'period'});
      expect(old.fieldIds['name'], 'old-field');
      final moved = old.withFieldIds({
        'new-slot': 'old-field',
        'period': 'period',
      });
      expect(
        moved.restoreBindings(old, {'old-field': 'restored-field'}).fieldIds,
        {'new-slot': 'restored-field', 'period': 'period'},
      );
    },
  );
}
