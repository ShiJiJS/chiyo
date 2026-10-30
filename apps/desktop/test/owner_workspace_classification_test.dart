import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_classification.dart';
import 'package:info_desktop/workspace/owner_workspace_information.dart';
import 'package:info_desktop/workspace/workspace_records.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> bytes) async => value = List.of(bytes);
}

void main() {
  late Directory root;
  late _Keys keys;
  late EncryptedInformationRepository repo;
  late core.InformationService service;
  late OwnerWorkspaceInformation information;
  late OwnerWorkspaceClassification classification;
  const definition = <String, Object?>{
    'id': 'generic',
    'name': '普通资料',
    'fields': [
      {'key': 'body', 'label': '正文', 'type': 'text'},
    ],
  };
  void connect({void Function()? onChanged}) {
    information = OwnerWorkspaceInformation(
      owner: service.owner,
      templates: {'generic': definition},
    );
    classification = OwnerWorkspaceClassification(
      owner: service.owner,
      information: information,
      onChanged: onChanged,
    );
  }

  Future<void> reopen() async {
    await service.close();
    await repo.close();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    connect();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('owner-classification-');
    keys = _Keys();
    repo = await EncryptedInformationRepository.open(root.path, keys);
    service = core.InformationService(repository: repo);
    connect();
  });
  tearDown(() async {
    await service.close();
    await repo.close();
    await root.delete(recursive: true);
  });

  test(
    'catalog and original directory receipt fit the UI contract across reopen',
    () async {
      final empty = await classification.loadCatalog();
      expect(empty.directoryCounts['all'], 0);
      expect(empty.creatableTypes.single.id, 'generic');
      final command = WorkspaceDirectoryChange(
        operationId: 'directory',
        expectedVersion: empty.version,
        action: WorkspaceDirectoryAction.create,
        name: ' 合成目录 ',
      );
      final created = await classification.changeClassification(command);
      expect(created.matches(command), isTrue);
      expect(created.directory!.name, '合成目录');
      await classification.changeClassification(
        WorkspaceDirectoryChange(
          operationId: 'rename',
          expectedVersion: created.version,
          action: WorkspaceDirectoryAction.update,
          directoryId: created.targetId,
          name: '已改名',
        ),
      );
      await reopen();
      final recovered = (await classification.classificationOperationReceipt(
        command.operationId,
      ))!;
      expect(recovered.matches(command), isTrue);
      expect(recovered.directory!.name, '合成目录');
      expect(
        (await classification.loadCatalog()).directories.single.name,
        '已改名',
      );
      expect(
        (await classification.changeClassification(command)).matches(command),
        isTrue,
      );
      expect(repo.directories, hasLength(1));
    },
  );

  test(
    'post-commit refresh failure remains unknown until exact metadata query',
    () async {
      connect(onChanged: () => throw StateError('synthetic refresh failure'));
      final catalog = await classification.loadCatalog();
      final command = WorkspaceTagChange(
        operationId: 'tag',
        expectedVersion: catalog.version,
        action: WorkspaceTagAction.create,
        name: '标签',
      );
      await expectLater(
        classification.changeClassification(command),
        throwsA(
          isA<WorkspaceFailure>().having(
            (f) => f.code,
            'unknown',
            'unknown_outcome',
          ),
        ),
      );
      await reopen();
      expect(
        (await classification.classificationOperationReceipt(
          'tag',
        ))!.matches(command),
        isTrue,
      );
      expect(repo.tags, hasLength(1));
      expect(
        await classification.classificationOperationReceipt('absent'),
        isNull,
      );
    },
  );

  test(
    'real counts include descendants and reviewed tag deletion is atomic',
    () async {
      final parent = await service.owner.createDirectory('父目录');
      final child = await service.owner.createDirectory(
        '子目录',
        parentId: parent.id,
      );
      final tag = await service.owner.createTag('标签');
      final created =
          (await information.createRecord(
                    WorkspaceCreate(
                      operationId: 'create',
                      typeId: 'generic',
                      name: '资料',
                      directoryId: child.id,
                      tagIds: [tag.id],
                      values: {'body': 'private'},
                    ),
                  )
                  as WorkspaceSaved)
              .detail;
      final catalog = await classification.loadCatalog();
      expect(catalog.directoryCounts[parent.id], 1);
      expect(catalog.directoryCounts[child.id], 1);
      expect(catalog.tagCounts[tag.id], 1);
      final preview = await classification.previewTagRemoval(tag.id);
      expect(preview.catalogVersion, catalog.version);
      expect(preview.affectedCount, 1);
      await expectLater(
        classification.changeDirectory(
          WorkspaceDirectoryChange(
            operationId: 'nonempty',
            expectedVersion: catalog.version,
            action: WorkspaceDirectoryAction.delete,
            directoryId: child.id,
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having(
            (f) => f.code,
            'nonempty',
            'directory_not_empty',
          ),
        ),
      );
      final removal = WorkspaceTagChange(
        operationId: 'remove',
        expectedVersion: catalog.version,
        action: WorkspaceTagAction.delete,
        tagId: tag.id,
        removalToken: preview.token,
      );
      expect(
        (await classification.changeClassification(removal)).matches(removal),
        isTrue,
      );
      await reopen();
      final detail = await information.readDetail(created.record.ref);
      expect(detail.record.tags, isEmpty);
      expect(detail.values, created.values);
      expect(detail.fieldIds, created.fieldIds);
      expect(repo.informationRevisions.last.item.tagIds, [tag.id]);
    },
  );

  test(
    'stale catalog and changed tag review reject without fake receipts',
    () async {
      final tag = await service.owner.createTag('标签');
      final catalog = await classification.loadCatalog();
      final preview = await classification.previewTagRemoval(tag.id);
      await service.owner.createInformation(
        '新关系',
        '',
        [const core.FieldInput('字段', '', 'private')],
        tagIds: [tag.id],
      );
      await expectLater(
        classification.changeClassification(
          WorkspaceTagChange(
            operationId: 'stale-review',
            expectedVersion: catalog.version,
            action: WorkspaceTagAction.delete,
            tagId: tag.id,
            removalToken: preview.token,
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having((f) => f.code, 'conflict', 'conflict'),
        ),
      );
      await service.owner.createDirectory('其它入口');
      await expectLater(
        classification.changeClassification(
          WorkspaceTagChange(
            operationId: 'stale-catalog',
            expectedVersion: catalog.version,
            action: WorkspaceTagAction.update,
            tagId: tag.id,
            name: '改名',
          ),
        ),
        throwsA(
          isA<WorkspaceFailure>().having((f) => f.code, 'conflict', 'conflict'),
        ),
      );
      expect(
        await classification.classificationOperationReceipt('stale-review'),
        isNull,
      );
      expect(
        await classification.classificationOperationReceipt('stale-catalog'),
        isNull,
      );
      expect(repo.tags.single.name, '标签');
    },
  );
}
