import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/workspace/sample_workspace_fixture.dart';
import 'package:info_desktop/workspace/sample_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

const profile = WorkspaceRecordRef(WorkspaceRecordKind.information, 'profile');
void main() {
  late SampleWorkspaceSource source;
  setUp(() => source = SampleWorkspaceSource());
  tearDown(() => source.dispose());
  List<WorkspaceRepeatedEntry> education(WorkspaceDetail d) =>
      WorkspaceRepeatedEntry.read(d.values['education']);
  Future<WorkspaceSaveResult> save(
    WorkspaceDetail d,
    List<WorkspaceRepeatedEntry> entries,
    String op,
  ) => source.saveRecord(
    WorkspaceEdit(
      operationId: op,
      expectedVersion: d.version,
      record: d.record,
      values: {'education': entries.map((e) => e.toJson()).toList()},
    ),
  );

  test(
    'entry and leaf identities survive editing, reorder, failure and reset; history stays immutable',
    () async {
      final before = await source.readDetail(profile),
          entries = education(await source.readDetail(profile));
      expect(entries.map((e) => e.id).toSet(), hasLength(2));
      expect(entries.expand((e) => e.fieldIds.values).toSet(), hasLength(6));
      final fresh = WorkspaceRepeatedEntry.empty().withText('title', '虚构研究经历');
      final changed = [
        fresh,
        entries.last.withText('detail', '更新说明'),
        entries.first,
      ];
      source.nextSaveFailure = const WorkspaceFailure('offline', '暂时离线');
      expect(await save(before, changed, 'failure'), isA<WorkspaceRejected>());
      expect((await source.readDetail(profile)).values, before.values);
      expect(await source.loadRevisions(profile), isEmpty);
      final result = await save(before, changed, 'success') as WorkspaceSaved;
      final after = education(await source.readDetail(profile));
      expect(after.map((e) => e.id), changed.map((e) => e.id));
      expect(after[1].fieldIds, entries.last.fieldIds);
      expect(after[1].detail, '更新说明');
      expect(result.detail.version, 2);
      final preview = await source.previewRevision(
        profile,
        1,
        expectedVersion: 2,
      );
      expect(preview.archive.detail.values, before.values);
      source.reset();
      expect((await source.readDetail(profile)).values, before.values);
    },
  );

  test(
    'source rejects duplicate identities, swapped leaf identities, malformed content and limits atomically',
    () async {
      final before = await source.readDetail(profile),
          entries = education(await source.readDetail(profile));
      final other = entries.last;
      final cases = <String, Object?>{
        'duplicates': [entries.first.toJson(), entries.first.toJson()],
        'changed-leaf': [
          {...entries.first.toJson(), 'fieldIds': other.fieldIds},
        ],
        'blank-title': [entries.first.withText('title', '').toJson()],
        'not-list': 'cannot replace structured content',
        'not-text': [
          {...entries.first.toJson(), 'period': 123},
        ],
        'invalid-id': [
          {...entries.first.toJson(), 'entryId': '../escape'},
        ],
        'over100': [
          for (var i = 0; i < 101; i++)
            WorkspaceRepeatedEntry.empty().withText('title', '经历$i').toJson(),
        ],
        'too-long': [
          entries.first
              .withText('detail', List.filled(2001, '文').join())
              .toJson(),
        ],
      };
      for (final item in cases.entries) {
        final result =
            await source.saveRecord(
                  WorkspaceEdit(
                    operationId: item.key,
                    expectedVersion: 1,
                    record: before.record,
                    values: {'education': item.value},
                  ),
                )
                as WorkspaceRejected;
        expect(result.failure.code, 'validation', reason: item.key);
        expect(result.failure.fieldErrors, isNotEmpty, reason: item.key);
        expect(
          (await source.readDetail(profile)).values,
          before.values,
          reason: item.key,
        );
      }
      final oversized =
          await source.saveRecord(
                WorkspaceEdit(
                  operationId: 'over200',
                  expectedVersion: 1,
                  record: before.record,
                  values: {
                    'education': [
                      for (var i = 0; i < 100; i++)
                        WorkspaceRepeatedEntry.empty()
                            .withText('title', '教育$i')
                            .toJson(),
                    ],
                    'experience': [
                      for (var i = 0; i < 67; i++)
                        WorkspaceRepeatedEntry.empty()
                            .withText('title', '工作$i')
                            .toJson(),
                    ],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(oversized.failure.fieldErrors['experience'], contains('200'));
    },
  );

  test(
    'new profiles receive distinct identities, reject copying another profile identities and preserve unknown entry metadata',
    () async {
      final original = await source.readDetail(profile),
          entry = education(await source.readDetail(profile)).first;
      final rejected =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'copied',
                  typeId: 'profile',
                  name: '另一档案',
                  values: {
                    'education': [entry.toJson()],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(rejected.failure.code, 'validation');
      final fresh = WorkspaceRepeatedEntry.fromJson({
        ...WorkspaceRepeatedEntry.empty().withText('title', '另一经历').toJson(),
        'legacyExtra': {
          'note': ['keep'],
        },
      });
      final result =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'created',
                  typeId: 'profile',
                  name: '另一档案',
                  values: {
                    'education': [fresh.toJson()],
                  },
                ),
              )
              as WorkspaceSaved;
      expect(result.detail.record.ref, isNot(profile));
      expect(education(result.detail).single.id, fresh.id);
      expect(education(result.detail).single.toJson()['legacyExtra'], {
        'note': ['keep'],
      });
      expect((await source.readDetail(profile)).values, original.values);
    },
  );

  test(
    'removed identities cannot be reused by ordinary saves; explicit restore renews removed leaves',
    () async {
      final before = await source.readDetail(profile),
          entries = education(await source.readDetail(profile));
      final saved =
          await save(before, [entries.last], 'remove') as WorkspaceSaved;
      final reused =
          await save(saved.detail, entries, 'reuse') as WorkspaceRejected;
      expect(reused.failure.fieldErrors['education'], contains('重复使用'));
      final preview = await source.previewRevision(
        profile,
        1,
        expectedVersion: 2,
      );
      final again = await source.previewRevision(
        profile,
        1,
        expectedVersion: 2,
      );
      expect(preview.restored.values, again.restored.values);
      final revived = education(preview.restored);
      expect(revived.first.id, isNot(entries.first.id));
      expect(
        revived.first.fieldIds.values.toSet().intersection(
          entries.first.fieldIds.values.toSet(),
        ),
        isEmpty,
      );
      expect(revived.last.id, entries.last.id);
      expect(revived.last.fieldIds, entries.last.fieldIds);
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'restore',
          action: WorkspaceRecordAction.restoreRevision,
          ref: profile,
          expectedVersion: 2,
          expectedCatalogVersion: (await source.loadCatalog()).version,
          revisionVersion: 1,
        ),
      );
      expect(
        (await source.readDetail(profile)).values,
        preview.restored.values,
      );
      expect(preview.archive.detail.values, before.values);
    },
  );

  test(
    'purge removes entry content but cannot recycle its identities into another record',
    () async {
      final entry = WorkspaceRepeatedEntry.empty().withText('title', '清理测试经历');
      final created =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'purge-create',
                  typeId: 'profile',
                  name: '清理档案',
                  values: {
                    'education': [entry.toJson()],
                  },
                ),
              )
              as WorkspaceSaved;
      final ref = created.detail.record.ref;
      final receipt = await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-recycle',
          action: WorkspaceRecordAction.recycle,
          ref: ref,
          expectedVersion: 1,
        ),
      );
      await source.changeRecord(
        WorkspaceRecordChange(
          operationId: 'purge-delete',
          action: WorkspaceRecordAction.purge,
          ref: ref,
          expectedVersion: receipt.version,
          entryId: receipt.entryId,
        ),
      );
      expect(
        (await source.queryRecycled()).items.any((e) => e.record.ref == ref),
        isFalse,
      );
      final reused =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'purge-reused',
                  typeId: 'profile',
                  name: '另一个档案',
                  values: {
                    'education': [entry.toJson()],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(reused.failure.fieldErrors['education'], contains('重复使用'));
    },
  );

  test(
    'owner/backup 200-field budget accepts 199 leaves and rejects 202',
    () async {
      final accepted = await source.createRecord(
        WorkspaceCreate(
          operationId: 'budget-199',
          typeId: 'profile',
          name: '字段预算内',
          values: {
            'education': [
              for (var i = 0; i < 65; i++)
                WorkspaceRepeatedEntry.empty()
                    .withText('title', '经历$i')
                    .toJson(),
            ],
          },
        ),
      );
      expect(accepted, isA<WorkspaceSaved>());
      final rejected =
          await source.createRecord(
                WorkspaceCreate(
                  operationId: 'budget-202',
                  typeId: 'profile',
                  name: '字段超预算',
                  values: {
                    'education': [
                      for (var i = 0; i < 66; i++)
                        WorkspaceRepeatedEntry.empty()
                            .withText('title', '经历$i')
                            .toJson(),
                    ],
                  },
                ),
              )
              as WorkspaceRejected;
      expect(rejected.failure.fieldErrors['education'], contains('200'));
      expect(
        (await source.queryRecords(
          const WorkspaceQuery(keyword: '字段超预算'),
        )).total,
        0,
      );
    },
  );

  test(
    'legacy over-budget collections remain complete on read rather than truncating',
    () async {
      final json = jsonDecode(sampleWorkspaceJson) as Map<String, dynamic>;
      final row = (json['records'] as List).singleWhere(
        (r) => r['id'] == 'profile',
      );
      row['values']['education'] = [
        for (var i = 0; i < 101; i++)
          {'title': '旧经历$i', 'period': '', 'detail': ''},
      ];
      final legacy = SampleWorkspaceSource(fixtureJson: jsonEncode(json));
      addTearDown(legacy.dispose);
      final detail = await legacy.readDetail(profile);
      expect(education(detail), hasLength(101));
      expect(education(detail).last.title, '旧经历100');
    },
  );
}
