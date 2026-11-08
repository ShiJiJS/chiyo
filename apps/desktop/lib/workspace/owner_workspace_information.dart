import 'package:info_workspace/owner_workspace_relation_queries.dart';
import 'owner_workspace_file_selections.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_adoption.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_history.dart';
import 'workspace_information_codec.dart';
import 'workspace_records.dart';
import 'workspace_order.dart';
import 'directory_tree.dart';
import 'owner_workspace_legacy_templates.dart';

/// Ordinary-information part of the production source. The composition root
/// owns OwnerAccess and supplies installed definitions; no sample data is used.
class OwnerWorkspaceInformation implements WorkspaceRelationSource {
  OwnerWorkspaceInformation({
    required this.owner,
    required Map<String, Map<String, Object?>> templates,
    this.readTemplates,
    this.templateState,
    this.onChanged,
    this.fileSelections,
  }) : _initialTemplates = Map.unmodifiable(
         templates.map(
           (key, value) => MapEntry(key, workspaceImmutableMap(value)),
         ),
       );
  final core.OwnerAccess owner;
  final OwnerWorkspaceFileSelections? fileSelections;
  final Map<String, Map<String, Object?>> _initialTemplates;
  final Map<String, Map<String, Object?>> Function()? readTemplates;
  final WorkspaceTemplateState Function(String, String?)? templateState;
  Map<String, Map<String, Object?>> get templates =>
      readTemplates?.call() ?? _initialTemplates;
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
    if (query.sort == WorkspaceSort.manual) {
      final directoryOrder = <String?>[
        for (final d in libraryDirectoryTree(
          WorkspaceCatalog(
            directories: owner.directories.map(
              (d) => WorkspaceDirectory(d.id, d.name, parentId: d.parentId),
            ),
            tags: const [],
            types: const [],
          ),
        ))
          d.id,
        null,
      ];
      sortWorkspaceSummaries(
        items,
        query.sort,
        manualDirectories: directoryOrder,
        manualRecords: [
          for (final r in owner.libraryRecordsInOrder)
            WorkspaceRecordRef(
              r.kind == 'credential'
                  ? WorkspaceRecordKind.credential
                  : WorkspaceRecordKind.information,
              r.id,
            ),
        ],
      );
    } else {
      sortWorkspaceSummaries(items, query.sort);
    }
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
  ) => OwnerWorkspaceRelationQueries(
    owner: owner,
    readSummaries: _summaries,
    readTemplate: loadTemplate,
    sort: (items) => sortWorkspaceSummaries(items, WorkspaceSort.name),
  ).queryRelationCandidates(query);

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

  Future<WorkspaceDetail> readDetail(WorkspaceRecordRef ref) async {
    final detail = _codec.decode(
      _item(ref),
      tagNames: {for (final tag in owner.tags) tag.id: tag.name},
    );
    final state = templateState?.call(
      detail.record.type.id,
      detail.definition['packageId'] as String?,
    );
    final incomingCredentials = owner.credentialsForInformation(ref.id);
    return WorkspaceDetail(
      record: detail.record,
      version: detail.version,
      templateState: detail.templateState == WorkspaceTemplateState.available
          ? state ?? detail.templateState
          : detail.templateState,
      definition: detail.definition,
      values: detail.values,
      relations: detail.relations,
      incomingRelations: {
        if (incomingCredentials.isNotEmpty)
          'credentials': [
            for (final credential in incomingCredentials)
              WorkspaceRecordRef(WorkspaceRecordKind.credential, credential.id),
          ],
      },
      fieldIds: detail.fieldIds,
      fieldOverrides: detail.fieldOverrides,
      retainedFields: detail.retainedFields,
      retainedRelations: detail.retainedRelations,
    );
  }

  Future<Map<String, Object?>> loadTemplate(String typeId) async {
    _available();
    final definition = templates[typeId];
    if (definition == null || definition['id'] != typeId) {
      throw const WorkspaceFailure('not_found', '模板已停用、移除或不可用；已有资料继续保留自己的定义。');
    }
    return definition;
  }

  Future<WorkspaceSaveResult> createRecord(
    WorkspaceCreate draft,
  ) => _write(() async {
    _available();
    final command = _codec.createCommand(draft);
    await _checkReplay(draft.operationId, command);
    if (draft.typeId == 'credential') {
      throw const WorkspaceFailure('unsupported', '托管凭据请使用凭据管理入口。');
    }
    final Map<String, Object?> definition;
    if (draft.legacyTemplateId != null) {
      final t = owner.templates
          .where((t) => t.id == draft.legacyTemplateId)
          .firstOrNull;
      if (t == null ||
          t.version != draft.expectedLegacyVersion ||
          draft.typeId != 'generic') {
        throw const WorkspaceFailure('conflict', '旧版模板已变化，请重新打开表单。');
      }
      definition = OwnerWorkspaceLegacyTemplates.project(t).definition;
    } else {
      if (draft.expectedLegacyVersion != null) {
        throw const WorkspaceFailure('validation', '旧版模板身份无效。');
      }
      definition = await loadTemplate(draft.typeId);
      if (draft.expectedTemplateVersion != definition['templateVersion'] ||
          draft.expectedTemplateDigest != definition['packageDigest']) {
        throw const WorkspaceFailure('conflict', '资料模板已更新，请重新打开表单。');
      }
    }
    final selected = {
      for (final e in draft.fileSelections.entries)
        e.key:
            fileSelections?.selection(e.value) ??
            (throw const WorkspaceFailure('selection_expired', '附件选择已失效。')),
    };
    if (selected.values.map((s) => s.draft.id).toSet().length > 1 ||
        selected.values.map((s) => s.stage.id).toSet().length !=
            selected.length) {
      throw const WorkspaceFailure('selection_expired', '请为各字段分别选择同一表单中的附件。');
    }
    final input = _codec.create(
      draft,
      definition,
      stagedFiles: {for (final e in selected.entries) e.key: e.value.stage.id},
    );
    _checkRelations(input, null);
    final receipt = selected.isEmpty
        ? await owner.saveInformationRecord(draft.operationId, input)
        : await owner.saveInformationFormRecord(
            selected.values.first.draft,
            draft.operationId,
            input,
          );
    for (final selected in selected.values) {
      await fileSelections!.committed(selected.resource.selectionId);
    }
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
        'template_changed' || 'template_unavailable' => const WorkspaceFailure(
          'conflict',
          '模板已停用、移除或更新，请重新核对新建资料的模板。',
        ),
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
        kind: command.adoptionPlanId != null
            ? WorkspaceOperationKind.adoptTemplate
            : receipt.baseVersion == null
            ? WorkspaceOperationKind.create
            : WorkspaceOperationKind.edit,
        ref: receipt.baseVersion == null ? null : ref,
        typeId: command.typeId,
        expectedVersion: receipt.baseVersion,
        planId: command.adoptionPlanId,
        legacyTemplateId: command.legacyTemplateId,
        legacyTemplateVersion: command.legacyTemplateVersion,
      ),
      result: WorkspaceRecordReceipt(ref: ref, version: receipt.version),
    );
  }

  Future<WorkspaceRecordReceipt> applyAdoption(
    String operationId,
    WorkspaceAdoptionPreview plan, {
    void Function()? validate,
  }) async {
    _available();
    final command = core.InformationRecordCommand(
      typeId: plan.target.type.id,
      digest: sha256
          .convert(utf8.encode('adopt-template:${plan.planId}'))
          .toString(),
      adoptionPlanId: plan.planId,
      templateCatalogVersion: plan.pluginVersion,
    );
    final prior = await owner.informationRecordReceipt(operationId);
    if (prior != null) {
      if (prior.command?.digest != command.digest) {
        throw const WorkspaceFailure('conflict', '原操作不能用于另一份预览。');
      }
      return WorkspaceRecordReceipt(
        ref: WorkspaceRecordRef(WorkspaceRecordKind.information, prior.itemId),
        version: prior.version,
      );
    }
    final current = _item(plan.current.record.ref);
    if (current.version != plan.current.version ||
        owner.templatePackageVersion != plan.pluginVersion) {
      throw const WorkspaceFailure('conflict', '资料或模板已变化，请重新预览。');
    }
    final input = _codec.adopt(plan.result, current, command);
    _checkRelations(input, current);
    try {
      final receipt = await owner.saveInformationRecord(
        operationId,
        input,
        validate: validate,
      );
      onChanged?.call(plan.current.record.ref);
      return WorkspaceRecordReceipt(
        ref: plan.current.record.ref,
        version: receipt.version,
      );
    } on core.AccessFailure catch (e) {
      throw _failure(e);
    }
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
