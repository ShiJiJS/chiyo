import 'package:info_core/info_core.dart' as core;
import 'owner_workspace_classification.dart';
import 'owner_workspace_credentials.dart';
import 'workspace_history.dart';
import 'workspace_information_codec.dart';
import 'workspace_records.dart';
import 'owner_workspace_library_recycle.dart';

/// Owner-only history projection over the same library as ordinary information.
/// The composition root owns both modules and their change stream.
class OwnerWorkspaceHistory {
  OwnerWorkspaceHistory({
    required this.owner,
    required this.information,
    this.onChanged,
  });
  final WorkspaceClassificationInformation information;
  final void Function(WorkspaceRecordRef)? onChanged;
  final core.OwnerAccess owner;
  final _codec = WorkspaceInformationCodec();
  Map<String, String> get _tagNames => {
    for (final tag in owner.tags) tag.id: tag.name,
  };
  void _available() {
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务尚未就绪。');
    }
  }

  void _ordinary(WorkspaceRecordRef ref) {
    _available();
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '凭据通过专用生命周期流程管理。');
    }
  }

  String? _directory(core.InformationItem item) {
    final directories = {for (final d in owner.directories) d.id: d};
    var current = item.directoryId;
    if (!directories.containsKey(current)) return null;
    final names = <String>[], seen = <String>{};
    while (current != null && seen.add(current)) {
      final directory = directories[current];
      if (directory == null) break;
      names.add(directory.name);
      current = directory.parentId;
    }
    return names.reversed.join(' / ');
  }

  Future<WorkspaceArchive> _archive(
    core.InformationItem item,
    DateTime at, {
    bool wholeItem = true,
    String? directoryName,
  }) async {
    final detail = _codec.decode(item, tagNames: _tagNames);
    final targets = await information.readSummaries(
      detail.relations.values.expand((refs) => refs),
    );
    return WorkspaceArchive(
      detail: detail,
      archivedAt: at,
      wholeItem: wholeItem,
      directoryName: directoryName ?? _directory(item),
      targets: {for (final target in targets) target.ref: target},
    );
  }

  Future<List<WorkspaceRevision>> loadRevisions(WorkspaceRecordRef ref) async {
    _ordinary(ref);
    try {
      final revisions = await owner.revisionsFor(ref.id);
      return [
        for (final revision in revisions)
          WorkspaceRevision(
            _codec.summary(revision.item, tagNames: _tagNames),
            revision.item.version,
            revision.replacedAt,
          ),
      ];
    } on core.AccessFailure catch (e) {
      throw _failure(e);
    }
  }

  Future<WorkspaceRevisionPreview> previewRevision(
    WorkspaceRecordRef ref,
    int version, {
    required int expectedVersion,
  }) async {
    _ordinary(ref);
    try {
      // Enforce retention before looking up the historical body.
      await owner.revisionsFor(ref.id);
      final catalog = await owner.informationClassificationSnapshot();
      final preview = owner.previewRevision(ref.id, version, expectedVersion);
      return WorkspaceRevisionPreview(
        current: _codec.decode(preview.current, tagNames: _tagNames),
        archive: await _archive(
          preview.revision.item,
          preview.revision.replacedAt,
        ),
        restored: _codec.decode(preview.restored, tagNames: _tagNames),
        catalogVersion: catalog.version,
        notices: [
          if (preview.revision.item.directoryId != preview.restored.directoryId)
            '原目录已删除，恢复后将归入未分类。',
          if (preview.revision.item.tagIds.any(
            (id) => !preview.restored.tagIds.contains(id),
          ))
            '已删除的标签不会恢复。',
          if ((preview.revision.item.layout?.relations.values
                      .expand((refs) => refs)
                      .length ??
                  0) !=
              (preview.restored.layout?.relations.values
                      .expand((refs) => refs)
                      .length ??
                  0))
            '已删除的关联目标不会恢复。',
        ],
        missingFields: preview.missingFields.map((f) => f.name),
      );
    } on core.AccessFailure catch (e) {
      throw _failure(e);
    }
  }

  Future<WorkspaceRecycleResults> queryRecycled({
    String keyword = '',
    int offset = 0,
    int limit = 25,
  }) async {
    _available();
    if (offset < 0 || limit < 1 || limit > 500 || keyword.length > 2000) {
      throw const WorkspaceFailure('invalid_query', '无效的回收站查询范围。');
    }
    final words = keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty);
    final batches = owner.libraryRecycleSupported
        ? owner.libraryRecycleBatches
        : <core.LibraryRecycleBatch>[];
    final groupedEntries = {
          for (final b in batches) ...b.informationEntries.values,
        },
        groupedCredentials = {
          for (final b in batches) ...b.credentialRevisions.keys,
        };
    final entries = <WorkspaceRecycleEntry>[];
    for (final entry in owner.recycleEntries) {
      if (groupedEntries.contains(entry.id)) continue;
      final item = entry.snapshot;
      if (item == null) continue;
      final summary = _codec.summary(item, tagNames: _tagNames);
      final metadata =
          '${summary.name} ${summary.description} ${summary.type.name} ${summary.tags.map((t) => t.name).join(' ')}'
              .toLowerCase();
      if (!words.every(metadata.contains)) continue;
      entries.add(
        WorkspaceRecycleEntry(
          id: entry.id,
          record: summary,
          version: entry.version,
          deletedAt: entry.deletedAt,
          expiresAt: entry.expiresAt,
          directoryName: _directory(item),
          wholeItem: entry.wholeItem,
        ),
      );
    }
    for (final credential in owner.recycledCredentials) {
      if (groupedCredentials.contains(credential.id)) continue;
      final entry = ownerCredentialRecycleEntry(owner, credential);
      final metadata =
          '${entry.record.name} ${entry.record.description} 凭据 ${entry.record.tags.map((t) => t.name).join(' ')}'
              .toLowerCase();
      if (words.every(metadata.contains)) entries.add(entry);
    }
    final rows = <WorkspaceRecycleRow>[
      ...entries.map(WorkspaceRecycleRow.entry),
    ];
    for (final batch in batches) {
      final metadata = [
        if (batch.directories.isNotEmpty) '目录',
        if (batch.informationEntries.isNotEmpty) '资料',
        if (batch.credentialRevisions.isNotEmpty) '凭据',
        ...batch.directories.map((d) => d.name),
        ...batch.directoryPaths.values.map((p) => p.join('/')),
        ...batch.records.expand((r) => [r.name, r.typeId, ...r.directoryPath]),
      ].join(' ').toLowerCase();
      if (words.every(metadata.contains)) {
        rows.add(
          WorkspaceRecycleRow.batch(workspaceDirectoryRecycleBatch(batch)),
        );
      }
    }
    rows.sort((a, b) {
      final time = b.deletedAt.compareTo(a.deletedAt);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
    final start = rows.isEmpty
        ? 0
        : offset.clamp(0, (rows.length - 1) ~/ limit * limit);
    return WorkspaceRecycleResults(
      rows: rows.skip(start).take(limit),
      total: rows.length,
      offset: start,
    );
  }

  Future<WorkspaceArchive> readRecycled(String entryId) async {
    _available();
    final entry = owner.recycleEntries
        .where((e) => e.id == entryId)
        .firstOrNull;
    if (entry?.snapshot == null) {
      throw const WorkspaceFailure('not_found', '回收内容已恢复、清理或到期。');
    }
    return _archive(
      entry!.snapshot!,
      entry.deletedAt,
      wholeItem: entry.wholeItem,
      directoryName: owner.libraryRecycleSupported
          ? owner.libraryRecycleBatches
                .where((b) => b.informationEntries.containsValue(entryId))
                .firstOrNull
                ?.directoryPaths[entry.snapshot!.directoryId]
                ?.join(' / ')
          : null,
    );
  }

  Future<core.InformationAttachmentRef> resolveRecycledFile(
    String entryId,
    String fieldKey,
  ) async {
    final archive = await readRecycled(entryId);
    final fieldId = archive.detail.fieldIds[fieldKey];
    final entry = owner.recycleEntries
        .where((e) => e.id == entryId)
        .firstOrNull;
    final field = entry?.snapshot?.fields
        .where((f) => f.id == fieldId)
        .firstOrNull;
    if (field == null ||
        field.kind != core.FieldKind.file ||
        field.attachment == null) {
      throw const WorkspaceFailure('not_found', '此回收资料的附件已不可用。');
    }
    return field.attachment!;
  }

  Future<WorkspaceRecordReceipt> changeRecord(
    WorkspaceRecordChange change,
  ) async {
    _ordinary(change.ref);
    try {
      final receipt = await owner.changeInformationLifecycle(
        core.InformationLifecycleCommand(
          operationId: change.operationId,
          itemId: change.ref.id,
          action: core.InformationLifecycleAction.values.byName(
            change.action.name,
          ),
          expectedVersion: change.expectedVersion,
          revisionVersion: change.revisionVersion,
          entryId: change.entryId,
          expectedCatalogVersion: change.expectedCatalogVersion,
          expectedCurrentVersion: change.expectedCurrentVersion,
        ),
      );
      try {
        onChanged?.call(change.ref);
      } on Object {
        throw const WorkspaceFailure('unknown_outcome', '操作已提交，刷新失败，请核对原操作。');
      }
      return _receipt(receipt).result;
    } on core.AccessFailure catch (e) {
      throw _failure(e);
    } on WorkspaceFailure {
      rethrow;
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '操作结果暂时无法确认，请核对原操作。');
    }
  }

  Future<WorkspaceOperationReceipt?> lifecycleOperationReceipt(
    String id,
  ) async {
    // Query failures must propagate; null is reserved for confirmed absence.
    final receipt = await owner.informationLifecycleReceipt(id);
    return receipt == null ? null : _receipt(receipt);
  }

  WorkspaceOperationReceipt _receipt(core.InformationLifecycleReceipt receipt) {
    final command = receipt.command;
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      command.itemId,
    );
    return WorkspaceOperationReceipt(
      operationId: command.operationId,
      intent: WorkspaceOperationIntent(
        kind: WorkspaceOperationKind.values.byName(command.action.name),
        ref: ref,
        expectedVersion: command.expectedVersion,
        revisionVersion: command.revisionVersion,
        entryId: command.entryId,
        expectedCatalogVersion: command.expectedCatalogVersion,
        expectedCurrentVersion: command.expectedCurrentVersion,
      ),
      result: WorkspaceRecordReceipt(
        ref: ref,
        version: receipt.version,
        entryId: receipt.entryId,
      ),
    );
  }

  WorkspaceFailure _failure(core.AccessFailure error) => switch (error.status) {
    'proposal_conflict' ||
    'revision_conflict' ||
    'recycle_conflict' ||
    'organization_conflict' => const WorkspaceFailure(
      'conflict',
      '资料、回收内容或分类已变化，请重新读取并核对。',
    ),
    'revision_unavailable' || 'recycle_unavailable' => const WorkspaceFailure(
      'not_found',
      '历史或回收内容已到期或不可用。',
    ),
    'recycle_restore_required' => const WorkspaceFailure(
      'recycle_restore_required',
      '请先恢复回收内容，再恢复历史版本。',
    ),
    'operation_conflict' => const WorkspaceFailure(
      'operation_conflict',
      '原操作编号不能用于另一份修改。',
    ),
    'invalid_information' => const WorkspaceFailure(
      'validation',
      '操作范围或版本无效，请重新核对。',
    ),
    'service_unavailable' => const WorkspaceFailure('unavailable', '资料服务尚未就绪。'),
    _ => const WorkspaceFailure('unknown_outcome', '操作结果无法确认，请核对原操作。'),
  };
}
