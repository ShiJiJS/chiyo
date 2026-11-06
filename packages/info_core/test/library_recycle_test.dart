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
}
