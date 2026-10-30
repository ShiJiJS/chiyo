import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_information_codec.dart';
import 'package:info_desktop/workspace/workspace_records.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  final codec = WorkspaceInformationCodec();
  const definition = <String, Object?>{
    'id': 'synthetic-profile',
    'name': '合成档案',
    'fields': [
      {'key': 'name', 'label': '姓名', 'type': 'text', 'required': true},
      {'key': 'education', 'label': '教育经历', 'type': 'entries'},
      {'key': 'bodyFormat', 'label': '格式', 'type': 'text'},
      {'key': 'body', 'label': '正文', 'type': 'multiline'},
    ],
    'sections': [
      {'kind': 'text', 'key': 'body', 'formatKey': 'bodyFormat'},
    ],
    'relations': [
      {'key': 'related', 'label': '关联资料'},
    ],
  };
  WorkspaceRepeatedEntry entry(String title) => WorkspaceRepeatedEntry.empty()
      .withText('title', title)
      .withText('period', '2020–2024')
      .withText('detail', 'synthetic-private-experience');
  WorkspaceCreate draft({List<WorkspaceRepeatedEntry> entries = const []}) =>
      WorkspaceCreate(
        operationId: 'create',
        typeId: 'synthetic-profile',
        name: '合成资料',
        values: {
          'name': 'synthetic-private-name',
          'education': [for (final e in entries) e.toJson()],
          'bodyFormat': 'markdown',
          'body': '# synthetic-private-body',
        },
      );
  Future<core.InformationItem> create({
    List<WorkspaceRepeatedEntry> entries = const [],
  }) async {
    await service.owner.saveInformationRecord(
      'create',
      codec.create(draft(entries: entries), definition),
    );
    return repo.items.single;
  }

  core.InformationDraftInput edit(
    core.InformationItem item,
    Map<String, Object?> values,
  ) => codec.edit(
    WorkspaceEdit(
      operationId: 'edit',
      expectedVersion: item.version,
      record: codec.decode(item).record,
      values: values,
    ),
    item,
  );
  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('workspace-codec-');
    keys = _Keys();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'real store retains document and independent fields across reopen',
    () async {
      final original = await create(entries: [entry('合成大学')]);
      final before = codec.decode(original);
      final input = edit(original, {'body': '# updated-private-body'});
      final saved = await service.owner.saveInformationRecord('edit', input);
      await reopen();
      final after = codec.decode(repo.items.single);
      expect(after.version, saved.version);
      expect(after.values['body'], '# updated-private-body');
      expect(after.values['name'], before.values['name']);
      expect(after.fieldIds, before.fieldIds);
      expect(after.values['education'], before.values['education']);
      expect(
        jsonEncode(repo.items.single.layout!.snapshot),
        isNot(contains('private')),
      );
      expect(jsonEncode(service.agent.catalog()), isNot(contains('private')));
      expect(
        (await service.owner.informationRecordReceipt('edit'))!.version,
        saved.version,
      );
      await service.owner.saveInformationRecord('edit', input);
      expect(repo.items.single.version, saved.version);
    },
  );

  test(
    'entry reorder and new leaves cannot expand an existing grant',
    () async {
      final temporary = entry('第一段');
      final original = await create(entries: [temporary]);
      final existing = WorkspaceRepeatedEntry.read(
        codec.decode(original).values['education'],
      ).single;
      expect(
        existing.fieldIds.values.toSet().intersection(
          temporary.fieldIds.values.toSet(),
        ),
        isEmpty,
      );
      final session = service.agent.openSession('合成聊天');
      final ref = core.FieldRef(original.id, existing.fieldIds['title']!);
      final request = service.agent.request(session, '读取经历名称', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      await service.owner.saveInformationRecord(
        'edit',
        edit(original, {
          'education': [
            entry('新增经历').toJson(),
            existing.withText('title', '修正名称').toJson(),
          ],
        }),
      );
      final entries = WorkspaceRepeatedEntry.read(
        codec.decode(repo.items.single).values['education'],
      );
      expect(entries.last.fieldIds, existing.fieldIds);
      expect(await service.agent.read(token, ref), '修正名称');
      await expectLater(
        service.agent.read(
          token,
          core.FieldRef(original.id, entries.first.fieldIds['title']!),
        ),
        throwsA(isA<core.AccessFailure>()),
      );
      final receipt = await service.owner.deleteInformation(
        original.id,
        repo.items.single.version,
        fieldId: ref.fieldId,
      );
      final restored = await service.owner.restoreRecycled(receipt.id);
      final restoredEntry = WorkspaceRepeatedEntry.read(
        codec.decode(restored).values['education'],
      ).last;
      expect(restoredEntry.fieldIds['title'], isNot(ref.fieldId));
      expect(restoredEntry.fieldIds['period'], existing.fieldIds['period']);
      await expectLater(
        service.agent.read(
          token,
          core.FieldRef(original.id, restoredEntry.fieldIds['title']!),
        ),
        throwsA(isA<core.AccessFailure>()),
      );
    },
  );

  test(
    'deleted entries cannot be revived by resubmitting stale UI identities',
    () async {
      final original = await create(entries: [entry('删除经历')]);
      final entries = codec.decode(original).values['education'];
      await service.owner.saveInformationRecord(
        'remove',
        edit(original, {'education': []}),
      );
      expect(
        () => edit(repo.items.single, {'education': entries}),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(codec.decode(repo.items.single).values['education'], isEmpty);
    },
  );

  test('metadata errors and a field named name remain distinct', () {
    final input = WorkspaceCreate(
      operationId: 'invalid',
      typeId: 'synthetic-profile',
      name: '',
      values: {'name': '', 'bodyFormat': 'html'},
    );
    expect(
      () => codec.create(input, definition),
      throwsA(
        isA<WorkspaceFailure>().having(
          (e) => e.fieldErrors.keys,
          'independent errors',
          containsAll(['name', 'value:name', 'bodyFormat']),
        ),
      ),
    );
  });

  test(
    'ordinary legacy attachment is retained without importing or replacing bytes',
    () async {
      final source = File('${root.path}/synthetic.bin');
      await source.writeAsBytes([0, 1, 255, 7]);
      final form = await service.owner.beginInformationFileDraft();
      final stage = await service.owner.stageInformationFile(form, source.path);
      final original = await service.owner.commitInformationDraft(
        form,
        'file-create',
        core.InformationDraftInput(
          name: '旧附件资料',
          description: '',
          fields: [
            const core.InformationDraftField.text('说明', '', 'old text'),
            core.InformationDraftField.stagedFile('附件', '', stage.id),
          ],
        ),
      );
      await service.owner.releaseInformationFileDraft(form);
      final detail = codec.decode(original);
      final textKey = detail.fieldIds.entries
          .singleWhere((e) => e.value == original.fields.first.id)
          .key;
      final fileKey = detail.fieldIds.entries
          .singleWhere((e) => e.value == original.fields.last.id)
          .key;
      expect(
        () => edit(original, {fileKey: 'cannot replace with path'}),
        throwsA(isA<WorkspaceFailure>()),
      );
      await service.owner.saveInformationRecord(
        'edit',
        edit(original, {textKey: 'updated text'}),
      );
      await reopen();
      final retained = repo.items.single.fields.last;
      expect(retained.id, original.fields.last.id);
      expect(
        retained.attachment!.attachmentId,
        original.fields.last.attachment!.attachmentId,
      );
      expect(
        retained.attachment!.attachmentVersion,
        original.fields.last.attachment!.attachmentVersion,
      );
      expect(
        await service.owner.informationAttachmentVersions(
          retained.attachment!.attachmentId,
        ),
        hasLength(1),
      );
      expect(
        await repo.readInformationAttachmentChunk(retained.attachment!, 0, 4),
        [0, 1, 255, 7],
      );
      expect(
        codec.decode(repo.items.single).values[fileKey],
        detail.values[fileKey],
      );
    },
  );

  test(
    'new entries cannot borrow another field identity or duplicate a leaf',
    () async {
      final original = await create(entries: [entry('原经历')]);
      final detail = codec.decode(original);
      final active = WorkspaceRepeatedEntry.read(
        detail.values['education'],
      ).single;
      final incoming = entry('新经历');
      final borrowed = {
        ...incoming.toJson(),
        'fieldIds': {...incoming.fieldIds, 'title': active.fieldIds['title']},
      };
      expect(
        () => edit(original, {
          'education': [active.toJson(), borrowed],
        }),
        throwsA(isA<WorkspaceFailure>()),
      );
      final duplicate = {
        ...incoming.toJson(),
        'fieldIds': {
          ...incoming.fieldIds,
          'period': incoming.fieldIds['title'],
        },
      };
      expect(
        () => edit(original, {
          'education': [duplicate],
        }),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(repo.items.single.version, original.version);
    },
  );

  test(
    'unmapped legacy fields survive repeated edits and partial restore',
    () async {
      final original = await create();
      await service.owner.editInformation(
        original.id,
        original.version,
        name: original.name,
        description: original.description,
        changes: const [
          core.FieldChange.add(
            core.FieldInput('旧字段', '', 'synthetic-legacy-body'),
          ),
        ],
      );
      final extra = repo.items.single.fields.last;
      final decoded = codec.decode(repo.items.single);
      final retainedKey = decoded.fieldIds.entries
          .singleWhere((e) => e.value == extra.id)
          .key;
      expect(decoded.values[retainedKey], 'synthetic-legacy-body');
      for (var i = 0; i < 2; i++) {
        await service.owner.saveInformationRecord(
          'edit-$i',
          edit(repo.items.single, {'body': 'change-$i'}),
        );
        await reopen();
        final detail = codec.decode(repo.items.single);
        expect(detail.fieldIds[retainedKey], extra.id);
        expect(
          workspaceFields(detail).where((f) => f['key'] == retainedKey),
          hasLength(1),
        );
        expect(detail.values[retainedKey], 'synthetic-legacy-body');
      }
      final removed = await service.owner.deleteInformation(
        original.id,
        repo.items.single.version,
        fieldId: extra.id,
      );
      await service.owner.saveInformationRecord(
        'while-deleted',
        edit(repo.items.single, {'body': 'other edit'}),
      );
      await service.owner.restoreRecycled(removed.id);
      final restored = codec.decode(repo.items.single);
      expect(restored.values.values, contains('synthetic-legacy-body'));
      expect(restored.fieldIds.values, isNot(contains(extra.id)));
      await service.owner.saveInformationRecord(
        'after-restore',
        edit(repo.items.single, {'body': 'last edit'}),
      );
      expect(
        codec.decode(repo.items.single).values.values,
        contains('synthetic-legacy-body'),
      );
    },
  );

  test(
    'unrecognized field types preserve values but cannot be rewritten',
    () async {
      final unknownDefinition = <String, Object?>{
        'id': 'legacy',
        'name': '旧格式',
        'fields': [
          {'key': 'old', 'type': 'future-widget', 'label': '旧字段'},
          {'key': 'text', 'type': 'text', 'label': '说明'},
        ],
      };
      await service.owner.saveInformationRecord(
        'legacy',
        core.InformationDraftInput(
          name: '旧资料',
          description: '',
          fields: const [
            core.InformationDraftField.text('旧字段', '', 'legacy-opaque-value'),
            core.InformationDraftField.text('说明', '', 'old text'),
          ],
          layout: core.InformationDraftLayout(
            core.InformationLayout(
              typeId: 'legacy',
              snapshot: {
                'codec': 'workspace-information-v1',
                'definition': unknownDefinition,
              },
              fieldIds: {},
            ),
            [
              jsonEncode(['field', 'old']),
              jsonEncode(['field', 'text']),
            ],
          ),
        ),
      );
      final original = repo.items.single;
      expect(
        () => edit(original, {
          'old': {'unexpected': 'data'},
        }),
        throwsA(isA<WorkspaceFailure>()),
      );
      await service.owner.saveInformationRecord(
        'edit',
        edit(original, {'text': 'new text'}),
      );
      await reopen();
      expect(
        codec.decode(repo.items.single).values['old'],
        'legacy-opaque-value',
      );
      expect(repo.items.single.fields.first.id, original.fields.first.id);
    },
  );

  test('unknown layout versions stay readable and reject editing', () async {
    await service.owner.saveInformationRecord(
      'future',
      core.InformationDraftInput(
        name: '未来格式',
        description: '',
        fields: const [core.InformationDraftField.text('正文', '', 'preserved')],
        layout: core.InformationDraftLayout(
          core.InformationLayout(
            typeId: 'future',
            snapshot: {'codec': 'future-version'},
            fieldIds: {},
          ),
          ['field'],
        ),
      ),
    );
    final item = repo.items.single;
    final detail = codec.decode(item);
    expect(detail.templateState, WorkspaceTemplateState.missing);
    expect(detail.values.values, contains('preserved'));
    expect(
      () => edit(item, {}),
      throwsA(
        isA<WorkspaceFailure>().having(
          (e) => e.code,
          'read only',
          'unsupported',
        ),
      ),
    );
    expect(repo.items.single.version, item.version);
  });

  test(
    'unknown input and stale versions are rejected before a write',
    () async {
      final original = await create();
      expect(
        () => edit(original, {
          'unrecognized': {'nested': 'body'},
        }),
        throwsA(isA<WorkspaceFailure>()),
      );
      final stale = WorkspaceEdit(
        operationId: 'edit',
        expectedVersion: original.version,
        record: codec.decode(original).record,
        values: {'body': 'stale'},
      );
      await service.owner.correctValue(
        core.FieldRef(original.id, original.fields.first.id),
        'new',
      );
      expect(
        () => codec.edit(stale, repo.items.single),
        throwsA(
          isA<WorkspaceFailure>().having((e) => e.code, 'conflict', 'conflict'),
        ),
      );
      expect(await service.owner.informationRecordReceipt('edit'), isNull);
    },
  );

  test(
    'an existing item with all fields removed can still save metadata',
    () async {
      final original = await create();
      for (final field in original.fields) {
        await service.owner.deleteInformation(
          original.id,
          repo.items.single.version,
          fieldId: field.id,
        );
      }
      final empty = repo.items.single;
      expect(empty.fields, isEmpty);
      final input = codec.edit(
        WorkspaceEdit(
          operationId: 'empty-edit',
          expectedVersion: empty.version,
          record: codec.decode(empty).record.copyWith(name: '保留空资料'),
          values: {},
        ),
        empty,
      );
      await service.owner.saveInformationRecord('empty-edit', input);
      await reopen();
      expect(repo.items.single.fields, isEmpty);
      expect(repo.items.single.name, '保留空资料');
      await service.owner.saveInformationRecord('empty-edit', input);
      await expectLater(
        service.owner.saveInformationRecord(
          'new-empty',
          core.InformationDraftInput(
            name: 'empty',
            description: '',
            fields: [],
          ),
        ),
        throwsA(isA<core.AccessFailure>()),
      );
    },
  );
}
