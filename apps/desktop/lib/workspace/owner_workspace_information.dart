import 'package:info_core/info_core.dart' as core;
import 'workspace_history.dart';
import 'workspace_information_codec.dart';
import 'workspace_records.dart';
import 'workspace_order.dart';

/// Ordinary-information part of the production source. The composition root
/// owns OwnerAccess and supplies installed definitions; no sample data is used.
class OwnerWorkspaceInformation implements WorkspaceRelationSource {
  OwnerWorkspaceInformation({
    required this.owner,
    required Map<String, Map<String, Object?>> templates,
    this.onChanged,
  }) : templates = Map.unmodifiable(
         templates.map(
           (key, value) => MapEntry(key, workspaceImmutableMap(value)),
         ),
       );
  final core.OwnerAccess owner;
  final Map<String, Map<String, Object?>> templates;
  final void Function(WorkspaceRecordRef)? onChanged;
  final _codec = WorkspaceInformationCodec();

  List<WorkspaceRecordSummary> _summaries() {
    _available();
    final names = {for (final tag in owner.tags) tag.id: tag.name};
    return [
      for (final item in owner.information)
        _codec.summary(item, tagNames: names),
      for (final credential in owner.credentials)
        WorkspaceRecordSummary(
          ref: WorkspaceRecordRef(
            WorkspaceRecordKind.credential,
            credential.id,
          ),
          name: credential.name,
          description: credential.publicPurpose,
          type: const WorkspaceType('credential', '凭据', 'key'),
          updatedAt: credential.modifiedAt,
          directoryId: credential.directoryId,
          tags: [
            for (final id in credential.tagIds)
              if (names[id] != null) WorkspaceTag(id, names[id]!),
          ],
        ),
    ];
  }

  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) async {
    final requested = refs.toSet();
    return [
      for (final summary in _summaries())
        if (requested.contains(summary.ref)) summary,
    ];
  }

  bool _keyword(WorkspaceRecordSummary record, String keyword) {
    final text =
        '${record.name} ${record.description} ${record.type.name} ${record.tags.map((t) => t.name).join(' ')}'
            .toLowerCase();
    return keyword
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .every(text.contains);
  }

  int _offset(int offset, int limit, int total) {
    if (offset < 0 || limit < 1 || limit > 500) {
      throw const WorkspaceFailure('invalid_query', '无效的分页范围。');
    }
    final last = total == 0 ? 0 : (total - 1) ~/ limit * limit;
    return offset > last ? last : offset;
  }

  Future<WorkspaceResults> queryRecords(
    WorkspaceQuery query, {
    WorkspaceRecordRef? keepSelection,
  }) async {
    _available();
    final parents = {for (final d in owner.directories) d.id: d.parentId};
    bool inDirectory(String? id) {
      if (query.directoryId == null || query.directoryId == 'all') return true;
      if (query.directoryId == 'unfiled') return id == null;
      final visited = <String>{};
      while (id != null && visited.add(id)) {
        if (id == query.directoryId) return true;
        id = parents[id];
      }
      return false;
    }

    final items = _summaries()
        .where(
          (r) =>
              inDirectory(r.directoryId) &&
              (query.typeId == null ||
                  workspaceTypeMatches(r.type.id, query.typeId!)) &&
              (query.tagId == null || r.tags.any((t) => t.id == query.tagId)) &&
              _keyword(r, query.keyword),
        )
        .toList();
    sortWorkspaceSummaries(items, query.sort);
    final groups = <String, List<WorkspaceRecordSummary>>{};
    for (final item in items) {
      final key = switch (query.grouping) {
        WorkspaceGrouping.none => '',
        WorkspaceGrouping.type => item.type.id,
        WorkspaceGrouping.directory => item.directoryId ?? 'unfiled',
      };
      groups.putIfAbsent(key, () => []).add(item);
    }
    final ordered = groups.values.expand((items) => items).toList();
    final offset = _offset(query.offset, query.limit, ordered.length);
    final selected = ordered.any((r) => r.ref == keepSelection)
        ? keepSelection
        : ordered.skip(offset).firstOrNull?.ref;
    return WorkspaceResults(
      items: ordered.skip(offset).take(query.limit),
      total: ordered.length,
      offset: offset,
      selection: selected,
      selectionIndex: selected == null
          ? null
          : ordered.indexWhere((r) => r.ref == selected),
      groupCounts: {for (final e in groups.entries) e.key: e.value.length},
    );
  }

  @override
  Future<WorkspaceResults> queryRelationCandidates(
    WorkspaceRelationQuery query,
  ) async {
    if (query.typeId == 'credential') {
      _available();
      if (query.key != 'related' ||
          (query.source != null &&
              (query.source!.kind != WorkspaceRecordKind.credential ||
                  !owner.credentials.any((c) => c.id == query.source!.id)))) {
        throw const WorkspaceFailure('conflict', '凭据关联来源已变化，请重新打开。');
      }
      final items = _summaries()
          .where(
            (r) =>
                r.ref.kind == WorkspaceRecordKind.information &&
                _keyword(r, query.keyword),
          )
          .toList();
      sortWorkspaceSummaries(items, WorkspaceSort.name);
      final offset = _offset(query.offset, query.limit, items.length);
      return WorkspaceResults(
        items: items.skip(offset).take(query.limit),
        total: items.length,
        offset: offset,
      );
    }
    final item = query.source == null ? null : _item(query.source!);
    if (item != null && (item.layout?.typeId ?? 'generic') != query.typeId) {
      throw const WorkspaceFailure('conflict', '来源资料类型已变化。');
    }
    // Only the owner's relation descriptors are needed. Do not decode source
    // field values just to find eligible target metadata.
    final snapshot = item?.layout?.snapshot;
    if (item?.layout != null &&
        snapshot?['codec'] != 'workspace-information-v1') {
      throw const WorkspaceFailure('unsupported', '此资料布局尚不支持修改关联。');
    }
    final definition = item == null
        ? await loadTemplate(query.typeId)
        : {
            'relations': [
              ...((snapshot?['definition'] as Map?)?['relations'] as List? ??
                  []),
              ...(snapshot?['retainedRelations'] as List? ?? []),
            ],
          };
    final rule = (definition['relations'] as List? ?? [])
        .where((r) => r['key'] == query.key)
        .lastOrNull;
    if (rule == null) {
      throw const WorkspaceFailure('unsupported', '此资料没有该关联类型。');
    }
    final types = rule['targetTemplates'] as List? ?? [];
    final items = _summaries()
        .where(
          (r) =>
              r.ref != query.source &&
              (query.key != 'credentials' ||
                  r.ref.kind == WorkspaceRecordKind.credential) &&
              (types.isEmpty ||
                  types.any(
                    (t) => workspaceTypeMatches(r.type.id, t as String),
                  )) &&
              _keyword(r, query.keyword),
        )
        .toList();
    sortWorkspaceSummaries(items, WorkspaceSort.name);
    final offset = _offset(query.offset, query.limit, items.length);
    return WorkspaceResults(
      items: items.skip(offset).take(query.limit),
      total: items.length,
      offset: offset,
    );
  }

  void _available() {
    if (!owner.serviceAvailable) {
      throw const WorkspaceFailure('unavailable', '资料服务尚未就绪。');
    }
  }

  core.InformationItem _item(WorkspaceRecordRef ref) {
    _available();
    if (ref.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('unsupported', '请通过凭据管理入口操作。');
    }
    final item = owner.information.where((i) => i.id == ref.id).firstOrNull;
    if (item == null) throw const WorkspaceFailure('not_found', '资料已不存在。');
    return item;
  }

  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async =>
      _codec.decode(
        _item(ref),
        tagNames: {for (final tag in owner.tags) tag.id: tag.name},
      );

  Future<Map<String, Object?>> loadTemplate(String typeId) async {
    _available();
    final definition = templates[typeId];
    if (definition == null || definition['id'] != typeId) {
      throw const WorkspaceFailure('unsupported', '此资料类型尚未接入。');
    }
    return definition;
  }

  Future<WorkspaceSaveResult> createRecord(
    WorkspaceCreate draft,
  ) => _write(() async {
    _available();
    final command = _codec.createCommand(draft);
    await _checkReplay(draft.operationId, command);
    // Template adoption and file import have separate transactions. Never
    // silently treat either as an ordinary text-only create.
    if (draft.legacyTemplateId != null || draft.expectedLegacyVersion != null) {
      throw const WorkspaceFailure('unsupported', '旧模板采用尚未接入。');
    }
    if (draft.typeId == 'credential') {
      throw const WorkspaceFailure('unsupported', '托管凭据请使用凭据管理入口。');
    }
    final definition = await loadTemplate(draft.typeId);
    if (draft.expectedTemplateVersion != definition['templateVersion'] ||
        draft.expectedTemplateDigest != definition['packageDigest']) {
      throw const WorkspaceFailure('conflict', '资料模板已更新，请重新打开表单。');
    }
    final input = _codec.create(draft, definition);
    _checkRelations(input, null);
    final receipt = await owner.saveInformationRecord(draft.operationId, input);
    return _saved(receipt);
  });

  Future<WorkspaceSaveResult> saveRecord(WorkspaceEdit edit) =>
      _write(() async {
        _available();
        await _checkReplay(edit.operationId, _codec.editCommand(edit));
        final current = _item(edit.record.ref);
        final input = _codec.edit(edit, current);
        _checkRelations(input, current);
        final receipt = await owner.saveInformationRecord(
          edit.operationId,
          input,
        );
        return _saved(receipt);
      });

  Future<void> _checkReplay(
    String id,
    core.InformationRecordCommand command,
  ) async {
    final receipt = await owner.informationRecordReceipt(id);
    if (receipt == null) return;
    if (receipt.command == null) {
      throw const WorkspaceFailure('unknown_outcome', '此旧操作缺少原表单标识，请保留操作编号核对。');
    }
    if (receipt.command!.digest != command.digest ||
        receipt.command!.typeId != command.typeId) {
      throw const WorkspaceFailure('conflict', '操作编号已用于另一份修改，请重新核对。');
    }
    // A prior result may already be edited/purged. The dedicated metadata-only
    // query returns the original version; current detail cannot stand in for it.
    throw const WorkspaceFailure('unknown_outcome', '操作已提交，请核对原操作结果。');
  }

  Future<WorkspaceSaveResult> _saved(
    core.InformationRecordReceipt receipt,
  ) async {
    try {
      final ref = WorkspaceRecordRef(
        WorkspaceRecordKind.information,
        receipt.itemId,
      );
      onChanged?.call(ref);
      final detail = await readDetail(ref);
      if (detail.version != receipt.version) {
        throw const WorkspaceFailure('unknown_outcome', '资料已再次变更，请核对本次操作结果。');
      }
      return WorkspaceSaved(detail);
    } on Object {
      throw const WorkspaceFailure('unknown_outcome', '写入已提交，但无法读取结果，请核对原操作。');
    }
  }

  Future<WorkspaceSaveResult> _write(
    Future<WorkspaceSaveResult> Function() write,
  ) async {
    try {
      return await write();
    } on WorkspaceFailure catch (failure) {
      return WorkspaceRejected(failure);
    } on core.AccessFailure catch (failure) {
      return WorkspaceRejected(_failure(failure));
    } on Object {
      // Storage/transport errors can arrive after commit. Only the receipt
      // query is allowed to distinguish absence from an unknown outcome.
      return const WorkspaceRejected(
        WorkspaceFailure('unknown_outcome', '保存结果暂时无法确认，请核对原操作。'),
      );
    }
  }

  WorkspaceFailure _failure(core.AccessFailure failure) =>
      switch (failure.status) {
        'version_conflict' || 'information_conflict' || 'operation_conflict' =>
          const WorkspaceFailure('conflict', '资料或操作已变化，请重新读取并核对修改。'),
        'invalid_information' => const WorkspaceFailure(
          'validation',
          '资料内容或分类无效，请重新核对。',
        ),
        'library_changed' => const WorkspaceFailure(
          'unknown_outcome',
          '资料库已替换，不能将旧操作重放到新库。',
        ),
        'service_unavailable' => const WorkspaceFailure(
          'unavailable',
          '资料服务尚未就绪。',
        ),
        _ => const WorkspaceFailure('unknown_outcome', '操作结果无法确认，请核对原操作。'),
      };

  Future<WorkspaceOperationReceipt?> recordOperationReceipt(
    String operationId,
  ) async {
    _available();
    // Do not catch a query error and return null: null means confirmed absent.
    final receipt = await owner.informationRecordReceipt(operationId);
    if (receipt == null) return null;
    final command = receipt.command;
    if (command == null) {
      throw const WorkspaceFailure('unknown_outcome', '旧回执缺少原操作类型，不能推测成功。');
    }
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      receipt.itemId,
    );
    return WorkspaceOperationReceipt(
      operationId: receipt.operationId,
      intent: WorkspaceOperationIntent(
        kind: receipt.baseVersion == null
            ? WorkspaceOperationKind.create
            : WorkspaceOperationKind.edit,
        ref: receipt.baseVersion == null ? null : ref,
        typeId: command.typeId,
        expectedVersion: receipt.baseVersion,
      ),
      result: WorkspaceRecordReceipt(ref: ref, version: receipt.version),
    );
  }

  void _checkRelations(
    core.InformationDraftInput input,
    core.InformationItem? before,
  ) {
    final layout = input.layout!.layout;
    final definition = layout.snapshot['definition'] as Map;
    final rules = <String, Map>{
      for (final raw in definition['relations'] as List? ?? [])
        (raw as Map)['key'] as String: raw,
      for (final raw in layout.snapshot['retainedRelations'] as List? ?? [])
        (raw as Map)['key'] as String: raw,
    };
    for (final group in layout.relations.entries) {
      final rule = rules[group.key];
      for (final target in group.value) {
        // Existing dangling links are part of the saved record and survive
        // unrelated edits. New links must resolve to an eligible live target.
        if (before?.layout?.relations[group.key]?.contains(target) == true) {
          continue;
        }
        String? type;
        if (target.kind == 'information') {
          final item = owner.information
              .where((i) => i.id == target.id)
              .firstOrNull;
          if (item != null && item.id != before?.id) {
            type = item.layout?.typeId ?? 'generic';
          }
        } else if (owner.credentials.any((c) => c.id == target.id)) {
          type = 'credential';
        }
        final allowed = rule?['targetTemplates'] as List? ?? [];
        if (rule == null ||
            type == null ||
            (group.key == 'credentials' && target.kind != 'credential') ||
            (allowed.isNotEmpty &&
                !allowed.any(
                  (t) => workspaceTypeMatches(type!, t as String),
                ))) {
          throw WorkspaceFailure(
            'validation',
            '关联目标已不可用或不符合资料类型。',
            fieldErrors: {'relation:${group.key}': '请重新选择关联资料。'},
          );
        }
      }
    }
  }
}
