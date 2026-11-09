import 'package:info_core/info_core.dart' as core;
import 'workspace_records.dart';

/// Only metadata and current definitions are required for classification.
abstract interface class WorkspaceClassificationInformation {
  Map<String, Map<String, Object?>> get templates;
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  );
}

/// Owner classification operations share the core transaction and original
/// receipts. The adapter never acknowledges an operation from cached UI state.
class OwnerWorkspaceClassification {
  OwnerWorkspaceClassification({
    required this.owner,
    required this.information,
    this.onChanged,
    this.fileCreationEnabled = true,
    this.credentialCreationEnabled = true,
  });
  final core.OwnerAccess owner;
  final WorkspaceClassificationInformation information;
  final void Function()? onChanged;
  // Composition declares which creation transports are connected. Storage
  // support alone does not mean the current client can provide their material.
  final bool fileCreationEnabled, credentialCreationEnabled;

  Future<WorkspaceCatalog> loadCatalog() async {
    final snapshot = await owner.informationClassificationSnapshot();
    final records = await information.readSummaries([
      for (final item in owner.information)
        WorkspaceRecordRef(WorkspaceRecordKind.information, item.id),
      for (final credential in owner.credentials)
        WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
    ]);
    final parents = {for (final d in snapshot.directories) d.id: d.parentId};
    final counts = <String, int>{
      'all': records.length,
      'unfiled': 0,
      for (final d in snapshot.directories) d.id: 0,
    };
    final tagCounts = <String, int>{for (final tag in snapshot.tags) tag.id: 0};
    for (final record in records) {
      if (record.directoryId == null ||
          !parents.containsKey(record.directoryId)) {
        counts['unfiled'] = counts['unfiled']! + 1;
      } else {
        var parent = record.directoryId;
        final visited = <String>{};
        while (parent != null &&
            parents.containsKey(parent) &&
            visited.add(parent)) {
          counts[parent] = (counts[parent] ?? 0) + 1;
          parent = parents[parent];
        }
      }
      for (final tag in record.tags) {
        if (tagCounts.containsKey(tag.id)) {
          tagCounts[tag.id] = tagCounts[tag.id]! + 1;
        }
      }
    }
    final creatable = [
      if (fileCreationEnabled && owner.informationFileManagementSupported)
        const WorkspaceType('file', '普通文件', 'file'),
      if (credentialCreationEnabled &&
          owner.credentialRecordOperationsSupported)
        const WorkspaceType('credential', '凭据', 'key'),
      for (final entry in information.templates.entries)
        if (!workspaceFileTypeIds.contains(entry.key) &&
            entry.key != 'credential')
          WorkspaceType(
            entry.key,
            entry.value['name'] as String? ?? entry.key,
            entry.value['icon'] as String? ?? 'file',
          ),
    ];
    final types = <String, WorkspaceType>{for (final t in creatable) t.id: t};
    for (final record in records) {
      types.putIfAbsent(record.type.id, () => record.type);
    }
    final batches = owner.libraryRecycleSupported
        ? owner.libraryRecycleBatches
        : <core.LibraryRecycleBatch>[];
    final groupedEntries = {
          for (final b in batches) ...b.informationEntries.values,
        },
        groupedCredentials = {
          for (final b in batches) ...b.credentialRevisions.keys,
        };
    return WorkspaceCatalog(
      directories: [
        for (final d in snapshot.directories)
          WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
      ],
      tags: [for (final t in snapshot.tags) WorkspaceTag(t.id, t.name)],
      types: types.values,
      creatableTypes: creatable,
      directoryCounts: counts,
      tagCounts: tagCounts,
      version: snapshot.version,
      recycledCount:
          batches.length +
          owner.recycleEntries
              .where((e) => !groupedEntries.contains(e.id))
              .length +
          owner.recycledCredentials
              .where((c) => !groupedCredentials.contains(c.id))
              .length,
    );
  }

  Future<WorkspaceTagRemovalPreview> previewTagRemoval(String tagId) async {
    try {
      final preview = await owner.previewInformationTagRemoval(tagId);
      return WorkspaceTagRemovalPreview(
        token: preview.token,
        tagId: preview.tagId,
        catalogVersion: preview.version,
        affectedCount: preview.affectedCount,
      );
    } on core.AccessFailure catch (error) {
      throw _failure(error);
    }
  }

  Future<WorkspaceDirectory?> changeDirectory(
    WorkspaceDirectoryChange change,
  ) async => (await changeClassification(change)).directory;

  Future<WorkspaceClassificationReceipt> changeClassification(
    WorkspaceClassificationChange change,
  ) async {
    try {
      final receipt = await owner.changeInformationClassification(
        core.InformationClassificationCommand(
          operationId: change.operationId,
          expectedVersion: change.expectedVersion,
          kind: core.InformationClassificationKind.values.byName(
            change.kind.name,
          ),
          action: core.InformationClassificationAction.values.byName(
            change.actionName,
          ),
          targetId: change.targetId,
          name: change.name,
          parentId: change.parentId,
          removalToken: change.removalToken,
        ),
      );
      // If invalidation delivery fails after commit, keep the original result
      // unknown until the dedicated receipt query confirms it.
      try {
        onChanged?.call();
      } on Object {
        throw const WorkspaceFailure('unknown_outcome', '分类已提交，刷新失败，请核对原操作。');
      }
      return _receipt(receipt);
    } on core.AccessFailure catch (error) {
      throw _failure(error);
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '分类操作结果暂时无法确认，请核对原操作。');
    }
  }

  Future<WorkspaceClassificationReceipt?> classificationOperationReceipt(
    String operationId,
  ) async {
    final receipt = await owner.informationClassificationReceipt(operationId);
    return receipt == null ? null : _receipt(receipt);
  }

  WorkspaceClassificationReceipt _receipt(
    core.InformationClassificationReceipt receipt,
  ) => WorkspaceClassificationReceipt(
    operationId: receipt.operationId,
    commandDigest: receipt.commandDigest,
    expectedVersion: receipt.expectedVersion,
    version: receipt.version,
    targetId: receipt.targetId,
    directory: receipt.directory == null
        ? null
        : WorkspaceDirectory(
            receipt.directory!.id,
            receipt.directory!.name,
            parentId: receipt.directory!.parentId,
          ),
    tag: receipt.tag == null
        ? null
        : WorkspaceTag(receipt.tag!.id, receipt.tag!.name),
  );

  WorkspaceFailure _failure(core.AccessFailure error) => switch (error.status) {
    'organization_conflict' => const WorkspaceFailure(
      'conflict',
      '分类或影响范围已变化，请重新读取并核对。',
    ),
    'operation_conflict' => const WorkspaceFailure(
      'operation_conflict',
      '原操作编号不能用于另一份分类修改。',
    ),
    'directory_not_empty' => const WorkspaceFailure(
      'directory_not_empty',
      '目录含有资料或子目录，请先移出。',
    ),
    'duplicate_directory' || 'duplicate_tag' => const WorkspaceFailure(
      'validation',
      '此位置已有同名分类。',
      fieldErrors: {'name': '请使用不同名称。'},
    ),
    'invalid_directory_name' => const WorkspaceFailure(
      'validation',
      '目录名不能包含斜线。',
      fieldErrors: {'name': '请检查目录名称。'},
    ),
    'invalid_information' => const WorkspaceFailure(
      'validation',
      '分类内容无效，请核对名称和上级目录。',
    ),
    'service_unavailable' => const WorkspaceFailure('unavailable', '资料服务尚未就绪。'),
    'library_changed' => const WorkspaceFailure(
      'unknown_outcome',
      '资料库已替换，不能重放旧操作。',
    ),
    _ => const WorkspaceFailure('unknown_outcome', '操作结果无法确认，请核对原操作。'),
  };
}
