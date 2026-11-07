import 'dart:convert';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'fixtures/credential_import_fixture.dart';

void main() {
  late InformationService service;
  late MemoryInformationRepository repo;
  setUp(() {
    repo = MemoryInformationRepository();
    service = InformationService(repository: repo);
    configureCredentialImports(service);
  });
  tearDown(() => service.close());

  test(
    'directory review deduplicates mixed selection without following relations or exposing content',
    () async {
      final parent = await service.owner.createDirectory('服务');
      final child = await service.owner.createDirectory(
        '应用',
        parentId: parent.id,
      );
      final leaf = await service.owner.createDirectory(
        '配置',
        parentId: child.id,
      );
      final other = await service.owner.createDirectory('另一个位置');
      final outside = await service.owner.createInformation('外部资料', '', [
        const FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
      ], directoryId: other.id);
      final item = await service.owner.createInformation('应用说明', '', [
        const FieldInput('正文', '', 'PRIVATE-BODY'),
      ], directoryId: leaf.id);
      final session = service.agent.openSession('合成目录回收');
      final proposalId = await service.agent.submitImport(session, [
        ImportItemInput(
          '应用凭据',
          '',
          [],
          key: 'token',
          templateId: 'credential.token',
          templateVersion: '1',
          templateDigest: 'c' * 64,
          directoryId: child.id,
          credential: CredentialImportInput.agentString('PRIVATE-TOKEN'),
          relations: {
            'related': [InformationRelationRef('information', outside.id)],
          },
        ),
      ]);
      final proposal = service.owner.importProposals.single;
      await service.owner.confirmImport(
        proposalId,
        proposal.version,
        proposal.items,
      );
      final credential = service.owner.credentials.single;
      final before = jsonEncode([
        informationToJson(item),
        credential.toJson(),
        repo.credentialMaterials.single.toStorageJson(),
      ]);
      final selection = LibraryRecycleSelection(
        directoryIds: [parent.id, child.id, parent.id],
        informationIds: [item.id, item.id],
        credentialIds: [credential.id, credential.id],
      );
      final result = await service.owner.previewLibraryRecycle(selection);
      expect(result.directories.map((d) => d.id).toSet(), {
        parent.id,
        child.id,
        leaf.id,
      });
      expect(result.informationCount, 1);
      expect(result.credentialCount, 1);
      expect(result.records.map((r) => r.id).toSet(), {item.id, credential.id});
      expect(result.records.firstWhere((r) => r.id == item.id).directoryPath, [
        '服务',
        '应用',
        '配置',
      ]);
      expect(jsonEncode(result.toJson()), isNot(contains('PRIVATE-')));
      expect(result.token, hasLength(64));
      expect(
        (await service.owner.previewLibraryRecycle(
          LibraryRecycleSelection(
            directoryIds: [child.id, parent.id],
            informationIds: [item.id],
            credentialIds: [credential.id],
          ),
        )).token,
        result.token,
      );
      expect(
        jsonEncode([
          informationToJson(
            service.owner.information.singleWhere((i) => i.id == item.id),
          ),
          service.owner.credentials.single.toJson(),
          repo.credentialMaterials.single.toStorageJson(),
        ]),
        before,
      );
      expect(service.owner.information, hasLength(2));
      expect(service.owner.recycleEntries, isEmpty);
      expect(() => result.records.clear(), throwsUnsupportedError);
    },
  );

  test(
    'empty directories and unfiled single records are valid independent scopes',
    () async {
      final directory = await service.owner.createDirectory('空目录');
      final item = await service.owner.createInformation('未分类', '', [
        const FieldInput('正文', '', 'PRIVATE'),
      ]);
      final empty = await service.owner.previewLibraryRecycle(
        LibraryRecycleSelection(directoryIds: [directory.id]),
      );
      expect(empty.directories, hasLength(1));
      expect(empty.records, isEmpty);
      final single = await service.owner.previewLibraryRecycle(
        LibraryRecycleSelection(informationIds: [item.id]),
      );
      expect(single.directories, isEmpty);
      expect(single.records.single.directoryPath, isEmpty);
    },
  );

  test(
    'children added after review and directory moves or renames change the confirmation token',
    () async {
      final directory = await service.owner.createDirectory('原名称');
      final selection = LibraryRecycleSelection(directoryIds: [directory.id]);
      final original = await service.owner.previewLibraryRecycle(selection);
      final child = await service.owner.createDirectory(
        '新增子目录',
        parentId: directory.id,
      );
      final afterChild = await service.owner.previewLibraryRecycle(selection);
      expect(afterChild.token, isNot(original.token));
      await service.owner.createInformation('新增资料', '', [
        const FieldInput('正文', '', 'PRIVATE'),
      ], directoryId: child.id);
      final afterItem = await service.owner.previewLibraryRecycle(selection);
      expect(afterItem.token, isNot(afterChild.token));
      await service.owner.updateDirectory(directory.id, '新名称');
      final afterRename = await service.owner.previewLibraryRecycle(selection);
      expect(afterRename.token, isNot(afterItem.token));
      await service.owner.updateDirectory(child.id, child.name);
      final afterMove = await service.owner.previewLibraryRecycle(selection);
      expect(afterMove.token, isNot(afterRename.token));
      expect(afterMove.records, isEmpty);
    },
  );

  test(
    'missing and already recycled selections fail rather than shrink the scope',
    () async {
      final c = await service.owner.createStringCredential(
        name: '合成凭据',
        publicPurpose: '测试',
        secret: 'PRIVATE',
      );
      await service.owner.deleteCredential(c.id, c.revision);
      for (final selection in [
        LibraryRecycleSelection(),
        LibraryRecycleSelection(directoryIds: ['missing']),
        LibraryRecycleSelection(credentialIds: [c.id]),
        LibraryRecycleSelection(informationIds: ['missing']),
      ]) {
        await expectLater(
          service.owner.previewLibraryRecycle(selection),
          throwsA(isA<AccessFailure>()),
        );
      }
      await service.close();
      await expectLater(
        service.owner.previewLibraryRecycle(
          LibraryRecycleSelection(directoryIds: ['missing']),
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'service_unavailable',
          ),
        ),
      );
    },
  );
  test(
    'a whole directory batch deletes and restores information and credentials without reviving grants',
    () async {
      final root = await service.owner.createDirectory('服务');
      final child = await service.owner.createDirectory(
        '应用',
        parentId: root.id,
      );
      final outside = await service.owner.createInformation('外部资料', '', [
        const FieldInput('正文', '', 'PRIVATE-OUTSIDE'),
      ]);
      final session = service.agent.openSession('合成整批回收');
      final id = await service.agent.submitImport(session, [
        ImportItemInput(
          '说明A',
          '',
          [],
          key: 'a',
          directoryId: child.id,
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-A'},
          pendingRelations: {
            'related': [
              ImportPendingReference('information', 'b'),
              ImportPendingReference('credential', 'token'),
            ],
          },
        ),
        ImportItemInput(
          '说明B',
          '',
          [],
          key: 'b',
          directoryId: child.id,
          templateId: 'note',
          templateVersion: '1',
          templateDigest: 'a' * 64,
          values: {'body': 'PRIVATE-B'},
          relations: {
            'related': [InformationRelationRef('information', outside.id)],
          },
        ),
        ImportItemInput(
          '凭据',
          '',
          [],
          key: 'token',
          directoryId: root.id,
          templateId: 'credential.token',
          templateVersion: '1',
          templateDigest: 'c' * 64,
          credential: CredentialImportInput.agentString('PRIVATE-TOKEN'),
        ),
      ]);
      final p = service.owner.importProposals.single;
      await service.owner.confirmImport(id, p.version, p.items);
      final original = service.owner.information.singleWhere(
        (i) => i.name == '说明A',
      );
      final field = FieldRef(original.id, original.fields.single.id);
      final request = service.agent.request(session, '合成访问', [field]);
      service.owner.approve(request.id, [field]);
      final grant = service.agent.claim(session, request.id);
      expect(await service.agent.read(grant.token, field), 'PRIVATE-A');
      final c = service.owner.credentials.single;
      final selection = LibraryRecycleSelection(
        directoryIds: [root.id, child.id],
        informationIds: [original.id],
        credentialIds: [c.id],
      );
      final preview = await service.owner.previewLibraryRecycle(selection);
      final receipt = await service.owner.recycleLibrarySelection(
        'delete-group',
        selection,
        preview.token,
      );
      expect(service.owner.directories, isEmpty);
      expect(service.owner.information.single.id, outside.id);
      expect(service.owner.credentials, isEmpty);
      expect(service.owner.recycleEntries, hasLength(2));
      expect(service.owner.libraryRecycleBatches, hasLength(1));
      expect(
        await service.owner.recycleLibrarySelection(
          'delete-group',
          selection,
          preview.token,
        ),
        same(receipt),
      );
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      final stored = LibraryRecycleBatch.fromJson(
        jsonDecode(jsonEncode(repo.libraryRecycleBatches.single.toJson()))
            as Map<String, dynamic>,
      );
      expect(stored.informationEntries, hasLength(2));
      expect(jsonEncode(stored.toJson()), isNot(contains('PRIVATE-')));
      final restore = await service.owner.previewLibraryRecycleRestore(
        receipt.batchId,
      );
      expect(restore.conflicts, isEmpty);
      final restored = await service.owner.restoreLibraryRecycleBatch(
        'restore-group',
        receipt.batchId,
        restore.token,
      );
      expect(
        await service.owner.restoreLibraryRecycleBatch(
          'restore-group',
          receipt.batchId,
          restore.token,
        ),
        same(restored),
      );
      expect(service.owner.directories.map((d) => d.name), ['服务', '应用']);
      expect(service.owner.information, hasLength(3));
      final after = service.owner.information.singleWhere(
        (i) => i.id == original.id,
      );
      expect(after.directoryId, child.id);
      expect(after.fields.single.value, 'PRIVATE-A');
      expect(after.fields.single.id, isNot(original.fields.single.id));
      expect(
        after.layout!.relations['related']!.map((r) => r.id).toSet(),
        original.layout!.relations['related']!.map((r) => r.id).toSet(),
      );
      expect(service.owner.credentials.single.enabled, false);
      expect(service.owner.credentials.single.version, c.version + 1);
      expect(
        service.owner.credentials.single.useGeneration,
        greaterThan(c.useGeneration),
      );
      expect(
        utf8.decode(
          repo.credentialMaterials
              .singleWhere(
                (m) => m.credentialId == c.id && m.version == c.version + 1,
              )
              .bytes,
        ),
        'PRIVATE-TOKEN',
      );
      await expectLater(
        service.agent.read(grant.token, field),
        throwsA(isA<AccessFailure>()),
      );
      expect(service.owner.libraryRecycleBatches, isEmpty);
      expect(
        service.owner.informationRevisions
            .where((r) => r.item.id == original.id)
            .first
            .item
            .fields
            .single
            .id,
        original.fields.single.id,
      );
    },
  );

  test('a stale delete review never includes newly added contents', () async {
    final root = await service.owner.createDirectory('目录');
    final selection = LibraryRecycleSelection(directoryIds: [root.id]);
    final preview = await service.owner.previewLibraryRecycle(selection);
    await service.owner.createInformation('后来新增', '', [
      const FieldInput('正文', '', 'PRIVATE'),
    ], directoryId: root.id);
    await expectLater(
      service.owner.recycleLibrarySelection(
        'stale-delete',
        selection,
        preview.token,
      ),
      throwsA(
        isA<AccessFailure>().having(
          (e) => e.status,
          'status',
          'library_selection_changed',
        ),
      ),
    );
    expect(service.owner.information, hasLength(1));
    expect(service.owner.directories, hasLength(1));
    expect(repo.libraryRecycleBatches, isEmpty);
  });

  test(
    'restore conflicts are explicit and owner-selected names and parents resolve them',
    () async {
      final parent = await service.owner.createDirectory('原上级');
      final root = await service.owner.createDirectory(
        '应用',
        parentId: parent.id,
      );
      final selection = LibraryRecycleSelection(directoryIds: [root.id]);
      final preview = await service.owner.previewLibraryRecycle(selection);
      final deleted = await service.owner.recycleLibrarySelection(
        'delete-conflict',
        selection,
        preview.token,
      );
      await service.owner.deleteDirectory(parent.id, parent.version);
      final destination = await service.owner.createDirectory('新上级');
      await service.owner.createDirectory(root.name, parentId: destination.id);
      expect(
        (await service.owner.previewLibraryRecycleRestore(
          deleted.batchId,
        )).conflicts.single,
        contains('原上级已不存在'),
      );
      final target = LibraryRecycleRestoreOptions(
        parentOverrides: {root.id: destination.id},
      );
      final conflicting = await service.owner.previewLibraryRecycleRestore(
        deleted.batchId,
        options: target,
      );
      expect(conflicting.canRestore, false);
      expect(conflicting.conflicts.single, contains('同名目录'));
      await expectLater(
        service.owner.restoreLibraryRecycleBatch(
          'bad-restore',
          deleted.batchId,
          conflicting.token,
          options: target,
        ),
        throwsA(isA<AccessFailure>()),
      );
      final options = LibraryRecycleRestoreOptions(
        parentOverrides: {root.id: destination.id},
        directoryNames: {root.id: '恢复的应用'},
      );
      final ready = await service.owner.previewLibraryRecycleRestore(
        deleted.batchId,
        options: options,
      );
      expect(ready.canRestore, true);
      expect(ready.warnings, hasLength(1));
      await service.owner.restoreLibraryRecycleBatch(
        'good-restore',
        deleted.batchId,
        ready.token,
        options: options,
      );
      final saved = service.owner.directories.singleWhere(
        (d) => d.id == root.id,
      );
      expect(saved.parentId, destination.id);
      expect(saved.name, '恢复的应用');
      expect(service.owner.directories.any((d) => d.id == parent.id), false);
    },
  );

  test(
    'a changed restore review and a separately restored member cannot be silently reused',
    () async {
      final item = await service.owner.createInformation('说明', '', [
        const FieldInput('正文', '', 'PRIVATE'),
      ]);
      final selection = LibraryRecycleSelection(informationIds: [item.id]);
      final preview = await service.owner.previewLibraryRecycle(selection);
      final deleted = await service.owner.recycleLibrarySelection(
        'delete-single',
        selection,
        preview.token,
      );
      final restore = await service.owner.previewLibraryRecycleRestore(
        deleted.batchId,
      );
      await service.owner.createDirectory('后来新建');
      await expectLater(
        service.owner.restoreLibraryRecycleBatch(
          'stale-restore',
          deleted.batchId,
          restore.token,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'library_selection_changed',
          ),
        ),
      );
      await service.owner.restoreRecycled(
        service.owner.recycleEntries.single.id,
      );
      expect(
        (await service.owner.previewLibraryRecycleRestore(
          deleted.batchId,
        )).canRestore,
        false,
      );
      await expectLater(
        service.owner.recycleLibrarySelection(
          'delete-single',
          LibraryRecycleSelection(informationIds: ['another']),
          preview.token,
        ),
        throwsA(
          isA<AccessFailure>().having(
            (e) => e.status,
            'status',
            'operation_conflict',
          ),
        ),
      );
    },
  );
}
