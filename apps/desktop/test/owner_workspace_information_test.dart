import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_information.dart';
import 'package:info_desktop/workspace/workspace_history.dart';
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
  late OwnerWorkspaceInformation source;
  var now = DateTime.utc(2026, 10, 30);
  const definition = <String, Object?>{
    'id': 'document',
    'name': '文档',
    'templateVersion': '1',
    'packageDigest': 'synthetic-definition',
    'fields': [
      {'key': 'body', 'label': '正文', 'type': 'multiline'},
    ],
    'relations': [
      {
        'key': 'related',
        'targetTemplates': ['document'],
      },
    ],
  };
  WorkspaceCreate create({
    String id = 'create',
    String body = 'synthetic-body',
    String? templateVersion = '1',
    Map<String, List<WorkspaceRecordRef>> relations = const {},
  }) => WorkspaceCreate(
    operationId: id,
    typeId: 'document',
    name: '合成文档',
    values: {'body': body},
    expectedTemplateVersion: templateVersion,
    expectedTemplateDigest: 'synthetic-definition',
    relations: relations,
  );
  void connect({void Function(WorkspaceRecordRef)? onChanged}) {
    source = OwnerWorkspaceInformation(
      owner: service.owner,
      templates: {'document': definition},
      onChanged: onChanged,
    );
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo, clock: () => now);
    connect();
  }

  Matcher rejected(String code) =>
      isA<WorkspaceRejected>().having((r) => r.failure.code, 'failure', code);
  setUp(() async {
    now = DateTime.utc(2026, 10, 30);
    root = await Directory.systemTemp.createTemp('owner-workspace-');
    keys = _Keys();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo, clock: () => now);
    connect();
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'production information adapter creates edits and reads real persisted values',
    () async {
      expect(repo.items, isEmpty);
      final created =
          (await source.createRecord(create()) as WorkspaceSaved).detail;
      expect(created.values['body'], 'synthetic-body');
      final edited = await source.saveRecord(
        WorkspaceEdit(
          operationId: 'edit',
          expectedVersion: created.version,
          record: created.record.copyWith(name: '改名'),
          values: {'body': 'updated'},
        ),
      );
      expect(edited, isA<WorkspaceSaved>());
      await reopen();
      final detail = await source.readDetail(created.record.ref);
      expect(detail.record.name, '改名');
      expect(detail.values['body'], 'updated');
      expect(detail.fieldIds, created.fieldIds);
      final receipt = (await source.recordOperationReceipt('edit'))!;
      expect(
        receipt.intent.matches(
          WorkspaceOperationIntent(
            kind: WorkspaceOperationKind.edit,
            ref: created.record.ref,
            typeId: 'document',
            expectedVersion: 1,
          ),
        ),
        isTrue,
      );
      expect(receipt.result.version, 2);
    },
  );

  test(
    'real metadata queries honor descendant directories tags grouping and off-page selection',
    () async {
      final parent = await service.owner.createDirectory('父目录');
      final child = await service.owner.createDirectory(
        '子目录',
        parentId: parent.id,
      );
      final tag = await service.owner.createTag('合成分类');
      final created = <WorkspaceDetail>[];
      for (var i = 0; i < 3; i++) {
        final item =
            (await source.createRecord(create(id: 'item-$i')) as WorkspaceSaved)
                .detail;
        await service.owner.organizeInformation(
          item.record.ref.id,
          expectedVersion: item.version,
          directoryId: child.id,
          tagIds: [tag.id],
        );
        created.add(await source.readDetail(item.record.ref));
      }
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: 'synthetic-body'),
        )).total,
        0,
      );
      final all = await source.queryRecords(
        WorkspaceQuery(
          directoryId: parent.id,
          tagId: tag.id,
          keyword: '合成分类',
          limit: 1,
          grouping: WorkspaceGrouping.type,
        ),
      );
      expect(all.total, 3);
      expect(all.items, hasLength(1));
      expect(all.groupCounts['document'], 3);
      final offPage = created
          .firstWhere((d) => d.record.ref != all.items.single.ref)
          .record
          .ref;
      final retained = await source.queryRecords(
        WorkspaceQuery(directoryId: parent.id, limit: 1),
        keepSelection: offPage,
      );
      expect(retained.selection, offPage);
      expect(retained.selectionIndex, greaterThan(0));
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(offset: 999, limit: 2),
        )).offset,
        2,
      );
      final candidates = await source.queryRelationCandidates(
        WorkspaceRelationQuery(
          typeId: 'document',
          key: 'related',
          source: created.first.record.ref,
          limit: 1,
        ),
      );
      expect(candidates.total, 2);
      expect(candidates.items.single.ref, isNot(created.first.record.ref));
      expect((await source.readSummaries([offPage])).single.ref, offPage);
      await expectLater(
        source.queryRecords(const WorkspaceQuery(limit: 0)),
        throwsA(isA<WorkspaceFailure>()),
      );
    },
  );

  test(
    'reordered map keys preserve a command but changed content conflicts',
    () async {
      source = OwnerWorkspaceInformation(
        owner: service.owner,
        templates: {
          'document': {
            ...definition,
            'fields': [
              ...definition['fields'] as List,
              {'key': 'extra', 'label': '补充', 'type': 'text'},
            ],
          },
        },
      );
      WorkspaceCreate command(Map<String, Object?> values) => WorkspaceCreate(
        operationId: 'canonical',
        typeId: 'document',
        name: '合成文档',
        expectedTemplateVersion: '1',
        expectedTemplateDigest: 'synthetic-definition',
        values: values,
        relations: const {'related': []},
      );
      final first = command({'body': 'same', 'extra': 'also same'});
      expect(await source.createRecord(first), isA<WorkspaceSaved>());
      await reopen();
      expect(
        await source.createRecord(
          command({'extra': 'also same', 'body': 'same'}),
        ),
        rejected('unknown_outcome'),
      );
      expect(
        await source.createRecord(
          command({'extra': 'also same', 'body': 'different'}),
        ),
        rejected('conflict'),
      );
      expect(repo.items, hasLength(1));
    },
  );

  test(
    'response loss is reconciled from original receipt after purge and reopen',
    () async {
      connect(onChanged: (_) => throw StateError('synthetic lost response'));
      final command = create();
      expect(await source.createRecord(command), rejected('unknown_outcome'));
      final original = repo.items.single;
      await service.owner.correctValue(
        core.FieldRef(original.id, original.fields.single.id),
        'later-value',
      );
      await service.owner.deleteInformation(
        original.id,
        repo.items.single.version,
      );
      now = now.add(const Duration(days: 400));
      await service.owner.purgeRecycle();
      await service.owner.purgeRevisions();
      await reopen();
      final receipt = (await source.recordOperationReceipt('create'))!;
      expect(
        receipt.intent.matches(
          const WorkspaceOperationIntent(
            kind: WorkspaceOperationKind.create,
            typeId: 'document',
          ),
        ),
        isTrue,
      );
      expect(receipt.result.version, 1);
      expect(receipt.result.ref.id, original.id);
      expect(await source.createRecord(command), rejected('unknown_outcome'));
      expect(
        await source.createRecord(create(body: 'different')),
        rejected('conflict'),
      );
      expect(repo.items, isEmpty);
    },
  );

  test(
    'stale edit and template mismatch reject without changing the database',
    () async {
      expect(
        await source.createRecord(create(templateVersion: 'old')),
        rejected('conflict'),
      );
      expect(repo.items, isEmpty);
      final detail =
          (await source.createRecord(create()) as WorkspaceSaved).detail;
      await service.owner.correctValue(
        core.FieldRef(detail.record.ref.id, detail.fieldIds['body']!),
        'newer',
      );
      expect(
        await source.saveRecord(
          WorkspaceEdit(
            operationId: 'stale',
            expectedVersion: detail.version,
            record: detail.record,
            values: {'body': 'overwrite'},
          ),
        ),
        rejected('conflict'),
      );
      expect(repo.items.single.fields.single.value, 'newer');
      expect(await source.recordOperationReceipt('stale'), isNull);
    },
  );

  test(
    'new relationships require a live eligible target; existing dangling references remain',
    () async {
      const missing = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        'missing',
      );
      expect(
        await source.createRecord(
          create(
            relations: {
              'related': [missing],
            },
          ),
        ),
        rejected('validation'),
      );
      final target =
          (await source.createRecord(create(id: 'target')) as WorkspaceSaved)
              .detail;
      final related =
          (await source.createRecord(
                    create(
                      id: 'related',
                      relations: {
                        'related': [target.record.ref],
                      },
                    ),
                  )
                  as WorkspaceSaved)
              .detail;
      await service.owner.deleteInformation(
        target.record.ref.id,
        target.version,
      );
      final saved = await source.saveRecord(
        WorkspaceEdit(
          operationId: 'unrelated-edit',
          expectedVersion: related.version,
          record: related.record,
          values: {'body': 'changed'},
        ),
      );
      expect(saved, isA<WorkspaceSaved>());
      expect((saved as WorkspaceSaved).detail.relations['related'], [
        target.record.ref,
      ]);
    },
  );

  test(
    'old core receipts and failed receipt queries never masquerade as absence',
    () async {
      await service.owner.saveInformationRecord(
        'old-command',
        core.InformationDraftInput(
          name: 'old',
          description: '',
          fields: const [core.InformationDraftField.text('body', '', 'value')],
        ),
      );
      await expectLater(
        source.recordOperationReceipt('old-command'),
        throwsA(isA<WorkspaceFailure>()),
      );
      expect(await source.recordOperationReceipt('never'), isNull);
      await repo.close();
      await expectLater(
        source.recordOperationReceipt('old-command'),
        throwsA(isA<StorageFailure>()),
      );
    },
  );

  test(
    'foreign legacy definitions and expired file leases cannot silently become ordinary saves',
    () async {
      expect(
        await source.createRecord(
          WorkspaceCreate(
            operationId: 'credential',
            typeId: 'credential',
            name: '凭据',
          ),
        ),
        rejected('unsupported'),
      );
      expect(
        await source.createRecord(
          WorkspaceCreate(
            operationId: 'legacy',
            typeId: 'document',
            name: 'legacy',
            legacyTemplateId: 'old',
            expectedLegacyVersion: 1,
          ),
        ),
        rejected('conflict'),
      );
      expect(
        await source.createRecord(
          WorkspaceCreate(
            operationId: 'file',
            typeId: 'document',
            name: 'file',
            expectedTemplateVersion: '1',
            expectedTemplateDigest: 'synthetic-definition',
            fileSelections: {'body': 'stage'},
          ),
        ),
        rejected('selection_expired'),
      );
      expect(repo.items, isEmpty);
    },
  );
}
