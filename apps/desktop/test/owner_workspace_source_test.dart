import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/builtin_workspace_definitions.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_app.dart';
import 'package:info_desktop/workspace/workspace_entries.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

Future<WorkspaceCreate> draft(
  OwnerWorkspaceSource source,
  String id,
  String type,
  Map<String, Object?> values,
) async {
  final template = await source.loadTemplate(type);
  return WorkspaceCreate(
    operationId: id,
    typeId: type,
    name: '合成$type',
    values: values,
    expectedTemplateVersion: template['templateVersion'] as String?,
    expectedTemplateDigest: template['packageDigest'] as String?,
  );
}

Matcher fails(String code) =>
    throwsA(isA<WorkspaceFailure>().having((e) => e.code, 'code', code));

void main() {
  group('SQLCipher composition', () {
    late Directory root;
    late _Keys keys;
    late EncryptedInformationRepository repo;
    late core.InformationService service;
    late OwnerWorkspaceSource source;
    Future<void> open() async {
      repo = await EncryptedInformationRepository.open(root.path, keys);
      service = core.InformationService(repository: repo);
      source = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
      );
    }

    Future<void> close() async {
      await source.dispose();
      await service.close();
      await repo.close();
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('owner-composition-');
      keys = _Keys();
      await open();
    });
    tearDown(() async {
      await close();
      await root.delete(recursive: true);
    });

    test(
      'built-in schemas create no seed, preserve five forms and original receipts across reopen',
      () async {
        expect((await source.loadSummary()).isEmpty, isTrue);
        final catalog = await source.loadCatalog();
        expect(catalog.directories, isEmpty);
        expect(
          catalog.creatableTypes.map((t) => t.id),
          unorderedEquals([
            'generic',
            'document',
            'server',
            'service',
            'profile',
          ]),
        );
        final values = <String, Map<String, Object?>>{
          'generic': {'body': 'synthetic note'},
          'document': {
            'bodyFormat': 'markdown',
            'body': '# synthetic document',
          },
          'server': {
            'host': 'synthetic.invalid',
            'port': '2222',
            'user': '',
            'purpose': '',
          },
          'service': {
            'url': 'https://synthetic.invalid',
            'purpose': 'synthetic',
            'auth': '',
          },
          'profile': {
            'name': '合成人物',
            'email': '',
            'city': '',
            'direction': '',
            'education': [
              WorkspaceRepeatedEntry.empty().withText('title', '合成学校').toJson(),
            ],
            'experience': [],
          },
        };
        final saved = <WorkspaceDetail>[];
        for (final entry in values.entries) {
          final result = await source.createRecord(
            await draft(source, 'new-${entry.key}', entry.key, entry.value),
          );
          expect(
            result,
            isA<WorkspaceSaved>(),
            reason: '${entry.key}: $result',
          );
          saved.add((result as WorkspaceSaved).detail);
        }
        final profile = saved.last;
        expect(
          WorkspaceRepeatedEntry.read(
            profile.values['education'],
          ).single.fieldIds.values.toSet(),
          hasLength(3),
        );
        final original = saved.first;
        await source.saveRecord(
          WorkspaceEdit(
            operationId: 'edit',
            record: original.record,
            expectedVersion: 1,
            values: {'body': 'corrected'},
          ),
        );
        final deleted = await source.changeRecord(
          WorkspaceRecordChange(
            operationId: 'recycle',
            ref: original.record.ref,
            expectedVersion: 2,
            action: WorkspaceRecordAction.recycle,
            expectedCatalogVersion: (await source.loadCatalog()).version,
          ),
        );
        expect(
          (await source.recordOperationReceipt('edit'))!.intent.kind,
          WorkspaceOperationKind.edit,
        );
        expect(
          (await source.recordOperationReceipt('recycle'))!.intent.kind,
          WorkspaceOperationKind.recycle,
        );
        expect(await source.recordOperationReceipt('never-submitted'), isNull);
        await close();
        await open();
        for (final previous in saved.skip(1)) {
          final current = await source.readDetail(previous.record.ref);
          expect(current.values, previous.values);
          expect(current.fieldIds, previous.fieldIds);
        }
        expect(
          (await source.readRecycled(deleted.entryId!)).detail.values['body'],
          'corrected',
        );
        expect(
          (await source.recordOperationReceipt('new-generic'))!.result.version,
          1,
        );
        expect(
          (await source.recordOperationReceipt('edit'))!.result.version,
          2,
        );
        expect(
          (await source.recordOperationReceipt('recycle'))!.result.entryId,
          deleted.entryId,
        );
      },
    );

    test(
      'ambiguous original operation is never guessed; unsupported receipts are not absence',
      () async {
        final created =
            (await source.createRecord(
                      await draft(source, 'shared-id', 'generic', {
                        'body': 'synthetic',
                      }),
                    )
                    as WorkspaceSaved)
                .detail;
        // Simulate a pre-existing collision from different owner operation stores.
        await service.owner.changeInformationLifecycle(
          core.InformationLifecycleCommand(
            operationId: 'shared-id',
            itemId: created.record.ref.id,
            action: core.InformationLifecycleAction.recycle,
            expectedVersion: 1,
          ),
        );
        await expectLater(
          source.recordOperationReceipt('shared-id'),
          fails('unknown_outcome'),
        );
        await expectLater(
          source.fileOperationReceipt('unknown'),
          fails('unsupported'),
        );
        await expectLater(
          source.approvals.receipt('unknown'),
          fails('unsupported'),
        );
        await expectLater(source.plugins.load(), fails('unsupported'));
        await expectLater(source.settings.read(), fails('unsupported'));
      },
    );

    test(
      'external writes invalidate projections and restore rejects every old ordinary form',
      () async {
        final events = <WorkspaceRecordRef?>[];
        final subscription = source.changes.listen(events.add);
        addTearDown(subscription.cancel);
        final pending = await draft(source, 'old-form', 'generic', {
          'body': 'must not write',
        });
        final item = await service.owner.createInformation('外部合成资料', '', [
          const core.FieldInput('字段', '', 'synthetic'),
        ]);
        source.refreshFromOwner();
        await Future<void>.delayed(Duration.zero);
        expect(events, isNotEmpty);
        expect((await source.loadSummary()).records, 1);
        final ref = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          item.id,
        );
        final detail = await source.readDetail(ref);
        await service.owner.restoreLibrary(() async {});
        expect(source.isCurrentLibrary, isFalse);
        await expectLater(
          source.createRecord(pending),
          fails('library_changed'),
        );
        await expectLater(
          source.saveRecord(
            WorkspaceEdit(
              operationId: 'old-edit',
              record: detail.record,
              expectedVersion: 1,
              values: detail.values,
            ),
          ),
          fails('library_changed'),
        );
        await expectLater(
          source.changeRecord(
            WorkspaceRecordChange(
              operationId: 'old-delete',
              ref: ref,
              expectedVersion: 1,
              action: WorkspaceRecordAction.recycle,
            ),
          ),
          fails('library_changed'),
        );
        await expectLater(source.loadCatalog(), fails('library_changed'));
        await expectLater(
          source.recordOperationReceipt('old-form'),
          fails('library_changed'),
        );
        expect(repo.items, hasLength(1));
        await source.dispose();
        source = OwnerWorkspaceSource(
          owner: service.owner,
          refreshInterval: Duration.zero,
        );
        expect((await source.loadSummary()).records, 1);
      },
    );
  });

  testWidgets(
    'shared UI creates a real owner record without sample providers',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final repo = core.MemoryInformationRepository([]);
      final service = (await t.runAsync(
        () async => core.InformationService(repository: repo),
      ))!;
      final source = (await t.runAsync(
        () async => OwnerWorkspaceSource(
          owner: service.owner,
          refreshInterval: Duration.zero,
        ),
      ))!;
      addTearDown(source.dispose);
      Future<void> settle() async {
        // Owner services use real asynchronous queues; widget frames use the
        // fake clock. Drain both schedulers before waiting for animations.
        for (var i = 0; i < 10; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
      }

      await t.pumpWidget(WorkspaceApp(source: source, windowTitle: '隔离真实来源'));
      await settle();
      expect(repo.items, isEmpty);
      await t.tap(find.byTooltip('添加资料').first);
      await settle();
      await t.tap(find.text('通用资料').last);
      await settle();
      await t.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('library-edit-name')),
          matching: find.byType(TextField),
        ),
        'UI合成资料',
      );
      await t.tap(find.text('保存').last);
      await settle();
      expect(repo.items.single.name, 'UI合成资料');
      expect(repo.items.single.layout!.typeId, 'generic');
      expect(find.text('Azure 日本服务器'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle();
      await t.runAsync(() async {
        await source.dispose();
        await service.close();
      });
    },
  );

  test('built-in catalog cannot be mutated by form consumers', () {
    expect(() => builtinWorkspaceDefinitions.clear(), throwsUnsupportedError);
    expect(
      () => (builtinWorkspaceDefinitions['server']!['fields'] as List).clear(),
      throwsUnsupportedError,
    );
  });
}
