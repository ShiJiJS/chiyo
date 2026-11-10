import 'file_transport.dart';
import 'owner_proposal_original_contents.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_information_codec.dart';
import 'workspace_entries.dart';
import 'owner_proposal_files.dart';
import 'workspace_source.dart';
import 'owner_credential_type.dart';

class OwnerWorkspaceProposals
    implements
        WorkspaceProposalSource,
        WorkspaceProposalPreviewSource,
        WorkspaceProposalOriginalSource {
  OwnerWorkspaceProposals({
    required this.owner,
    required this.library,
    required this.changed,
    this.originals,
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final WorkspaceProposalLibrary Function() library;
  final void Function() changed;
  final core.OwnerLibraryScope _scope;
  final _codec = WorkspaceInformationCodec();
  late final _contents = OwnerProposalOriginalContents(owner);
  final OwnerProposalFiles? originals;
  OwnerProposalFiles get _originals =>
      originals ?? (throw const WorkspaceFailure('unsupported', '暂时无法预览这份文件。'));
  List<WorkspaceProposalAttachment> _attachments(
    Iterable<core.ImportAttachmentInput> attachments, {
    core.UpdateInput? update,
    core.InformationItem? before,
    WorkspaceDetail? after,
  }) => [
    for (final a in attachments)
      WorkspaceProposalAttachment(
        key: a.key,
        name: a.name,
        description: a.description,
        currentVersion: a.currentVersion,
        templateField: a.templateField ?? _attachmentField(a, update, after),
        existingName:
            before?.fields.where((f) => f.id == a.fieldId).firstOrNull?.name ??
            '',
        previous: (() {
          final v = update?.filePlan?.previousVersions[a.fieldId];
          return v == null
              ? null
              : WorkspaceProposalOriginal(
                  filename: v.originalName,
                  mediaType: v.mediaType,
                  byteLength: v.byteLength,
                  label: v.label,
                  sourceNote: v.sourceNote,
                );
        })(),
        versions: [
          for (final v in a.versions)
            WorkspaceProposalOriginal(
              filename: v.upload!.originalName,
              mediaType: v.upload!.mediaType,
              byteLength: v.upload!.byteLength,
              label: v.label,
              sourceNote: v.sourceNote,
            ),
        ],
      ),
  ];
  String? _attachmentField(
    core.ImportAttachmentInput attachment,
    core.UpdateInput? update,
    WorkspaceDetail? after,
  ) {
    if (after == null || update == null) return null;
    final existing = after.fieldIds.entries
        .where((e) => e.value == attachment.fieldId)
        .firstOrNull;
    if (existing != null) return existing.key;
    final uploads = attachment.versions.map((v) => v.upload!.id).toSet();
    final promoted = update.filePlan?.promotions
        .where((p) => uploads.contains(p.upload.id))
        .firstOrNull;
    if (promoted == null) return null;
    return after.values.entries
        .where(
          (e) =>
              e.value is Map &&
              (e.value as Map)['attachmentId'] ==
                  promoted.version.reference.attachmentId,
        )
        .firstOrNull
        ?.key;
  }

  String _suggestionId(String kind, String name) =>
      'proposed-$kind:${sha256.convert(utf8.encode((kind == 'directory' ? name.split('/').map((p) => p.trim()).join('/') : name.trim()).toLowerCase()))}';
  Map<String, String> get _suggestedDirectories => {
    for (final p in owner.importProposals)
      for (final i in p.items)
        if (i.suggestedDirectory.trim().isNotEmpty)
          for (
            var depth = 1;
            depth <= i.suggestedDirectory.split('/').length;
            depth++
          )
            _suggestionId(
              'directory',
              i.suggestedDirectory.split('/').take(depth).join('/'),
            ): i.suggestedDirectory
                .split('/')
                .take(depth)
                .map((p) => p.trim())
                .join('/'),
  };
  Map<String, String> get _suggestedTags => {
    for (final p in owner.importProposals)
      for (final i in p.items)
        for (final name in i.suggestedTags)
          if (name.trim().isNotEmpty) _suggestionId('tag', name): name.trim(),
  };
  String? _suggestedDirectoryId(String path) {
    String? parent;
    for (final part in path.trim().split('/')) {
      final found = owner.directories
          .where(
            (d) =>
                d.parentId == parent &&
                d.name.toLowerCase() == part.trim().toLowerCase(),
          )
          .firstOrNull;
      if (found == null) return null;
      parent = found.id;
    }
    return parent;
  }

  String? _importDirectory(core.ImportItemInput i) =>
      i.directoryId ??
      (i.suggestedDirectory.trim().isEmpty
          ? null
          : _suggestedDirectoryId(i.suggestedDirectory) ??
                _suggestionId('directory', i.suggestedDirectory));
  List<String> _importTags(core.ImportItemInput i) => {
    ...i.tagIds,
    for (final name in i.suggestedTags)
      if (name.trim().isNotEmpty)
        owner.tags
                .where((t) => t.name.toLowerCase() == name.trim().toLowerCase())
                .firstOrNull
                ?.id ??
            _suggestionId('tag', name),
  }.toList();
  Map<String, String> get _tags => {for (final t in owner.tags) t.id: t.name};
  Future<T> _run<T>(Future<T> Function() action) async {
    try {
      return await owner.inLibraryScope(_scope, action);
    } on core.InformationTemplateInputFailure catch (e) {
      throw WorkspaceFailure(
        'validation',
        '请按模板说明核对字段。',
        fieldErrors: e.fieldErrors,
      );
    } on core.AccessFailure catch (e) {
      throw WorkspaceFailure(
        switch (e.status) {
          'proposal_changed' ||
          'proposal_conflict' ||
          'organization_conflict' => 'conflict',
          _ => e.status,
        },
        switch (e.status) {
          'library_changed' => '资料库已替换，请重新读取提案。',
          'operation_conflict' => '原操作不能用于另一份决定。',
          'proposal_incomplete' => '请核对整份提案后保存，不能只保存其中部分条目。',
          'credential_material_required' => '提案中还有密码或凭证未填齐，整份尚未入库。',
          'attachment_capacity_exceeded' => '文件存储空间不足，请整理空间后重试；现有历史文件没有被自动清理。',
          'invalid_directory_name' =>
            '目录路径无效。请使用最多8层的名称，层级用 / 分隔；不能包含空层级、反斜线、. 或 ..。原提案未入库。',
          'upload_unavailable' => '待审批原文已不可用，请重新提交文件并审批。',
          'attachment_integrity_failed' => '文件原文核对失败，原资料没有改变，请重新核对来源。',
          'proposal_changed' ||
          'proposal_conflict' ||
          'organization_conflict' => '提案或原资料已变化，请重新核对；尚未应用这份决定。',
          _ => '暂时无法处理提案，请重试或核对原操作。',
        },
      );
    }
  }

  core.ProposalEntry _entry(String id) =>
      owner
          .queryProposals(
            focusProposalId: id,
            filter: core.ProposalFilter.all,
            limit: 100,
          )
          .entries
          .where((e) => e.id == id)
          .firstOrNull ??
      (throw const WorkspaceFailure('not_found', '提案已不存在或不在保留范围。'));
  WorkspaceRecordRef _ref(String id) =>
      WorkspaceRecordRef(WorkspaceRecordKind.information, id);
  core.InformationItem? _current(String id) =>
      owner.information.where((i) => i.id == id).firstOrNull;
  String _pendingId(String proposalId, String key) =>
      'pending:$proposalId:$key';
  core.InformationLayout? _pendingLayout(
    core.InformationLayout? layout,
    Map<String, List<core.ImportPendingReference>> pending,
    String proposalId,
  ) {
    if (layout == null || pending.isEmpty) return layout;
    return core.InformationLayout(
      typeId: layout.typeId,
      snapshot: layout.snapshot,
      fieldIds: layout.fieldIds,
      relations: {
        for (final key in {...layout.relations.keys, ...pending.keys})
          key: [
            ...layout.relations[key] ?? [],
            for (final ref in pending[key] ?? [])
              core.InformationRelationRef(
                ref.kind,
                _pendingId(ref.proposalId ?? proposalId, ref.itemKey),
              ),
          ],
      },
    );
  }

  ({core.ImportProposal proposal, String key})? _pendingTarget(String id) {
    for (final p in owner.importProposals) {
      for (final key in p.candidateNames.keys) {
        if (_pendingId(p.id, key) == id) return (proposal: p, key: key);
      }
    }
    return null;
  }

  ({
    Map<String, List<core.InformationRelationRef>> existing,
    Map<String, List<core.ImportPendingReference>> pending,
  })
  _reviewRelations(
    WorkspaceProposalItemReview review,
    String proposalId, {
    Set<String>? declaredKeys,
  }) {
    final existing = <String, List<core.InformationRelationRef>>{},
        pending = <String, List<core.ImportPendingReference>>{};
    for (final e in review.relations.entries) {
      if (declaredKeys != null && !declaredKeys.contains(e.key)) continue;
      for (final ref in e.value) {
        final target = _pendingTarget(ref.id);
        if (target == null) {
          (existing[e.key] ??= []).add(
            core.InformationRelationRef(ref.kind.name, ref.id),
          );
        } else {
          (pending[e.key] ??= []).add(
            core.ImportPendingReference(
              ref.kind.name,
              target.key,
              proposalId: target.proposal.id == proposalId
                  ? null
                  : target.proposal.id,
            ),
          );
        }
      }
    }
    return (existing: existing, pending: pending);
  }

  core.InformationItem? _retained(String id, int version) {
    final current = _current(id);
    if (current?.version == version) return current;
    for (final r in owner.informationRevisions) {
      if (r.item.id == id && r.item.version == version) return r.item;
    }
    for (final r in owner.recycleEntries) {
      if (r.snapshot?.id == id && r.snapshot?.version == version) {
        return r.snapshot;
      }
    }
    return null;
  }

  WorkspaceProposalSummary _summary(core.ProposalEntry e) {
    final deletion = owner.deleteProposals
        .where((p) => p.id == e.id)
        .firstOrNull;
    final task = owner.organizationTasks.where((p) => p.id == e.id).firstOrNull;
    return WorkspaceProposalSummary(
      id: e.id,
      title: e.title.isNotEmpty
          ? e.title
          : switch (e.kind) {
              core.ProposalKind.addition => '${e.count}项新增资料',
              core.ProposalKind.modification =>
                '修改${e.itemIds.map((id) => _current(id)?.name ?? '原资料').join('、')}',
              core.ProposalKind.deletion =>
                '删除${e.itemIds.map((id) => _current(id)?.name ?? '原资料').join('、')}',
              core.ProposalKind.organization => '${e.count}项资料整理结果',
            },
      kind: WorkspaceProposalKind.values.byName(e.kind.name),
      status: WorkspaceProposalStatus.values.byName(e.status.name),
      pending: e.pending,
      version: task == null
          ? e.version
          : e.pending
          ? 1
          : 2,
      at: e.createdAt,
      agentClaim: e.agentName,
      chatClaim: e.chatLabel,
      purpose: e.purpose,
      itemCount: e.count,
      wholeDeletion: deletion != null && deletion.fieldId == null,
      organizationOutcome: task == null ? null : _organizationOutcome(task),
    );
  }

  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery q, {
    String? keepSelection,
  }) => _run(() async {
    core.ProposalPage page({String? focus}) => owner.queryProposals(
      search: q.keyword,
      filter: core.ProposalFilter.values.byName(switch (q.filter) {
        WorkspaceProposalFilter.handled => 'handled',
        WorkspaceProposalFilter.pending => 'pending',
        _ => 'all',
      }),
      kind: q.kind == null
          ? null
          : core.ProposalKind.values.byName(q.kind!.name),
      offset: q.offset,
      limit: q.limit,
      focusProposalId: focus,
    );
    final result = page();
    String? selection;
    int? index;
    if (keepSelection != null) {
      final focused = page(focus: keepSelection);
      final local = focused.entries.indexWhere((e) => e.id == keepSelection);
      if (local >= 0) {
        selection = keepSelection;
        index = focused.offset + local;
      }
    }
    if (selection == null && result.entries.isNotEmpty) {
      selection = result.entries.first.id;
      index = result.offset;
    }
    return WorkspaceProposalResults(
      items: result.entries.map(_summary),
      total: result.total,
      pending: result.pendingCount,
      offset: result.offset,
      selection: selection,
      selectionIndex: index,
    );
  });
  core.InformationItem _stablePreview(
    core.UpdateProposal p,
    core.UpdatePreview preview,
  ) {
    final beforeIds = preview.before.fields.map((f) => f.id).toSet();
    final remap = <String, String>{
      for (final (index, f) in preview.after.fields.indexed)
        if (!beforeIds.contains(f.id) &&
            !(p.input.filePlan?.fields.any((planned) => planned.id == f.id) ??
                false))
          f.id: 'proposal:${p.id}:$index',
    };
    final a = preview.after;
    return core.InformationItem(
      a.id,
      a.name,
      a.description,
      a.version,
      [
        for (final f in a.fields)
          if (remap[f.id] != null)
            core.InformationField(
              remap[f.id]!,
              f.name,
              f.description,
              f.value,
              f.version,
              kind: f.kind,
            )
          else
            f,
      ],
      directoryId: a.directoryId,
      tagIds: a.tagIds,
      layout: a.layout?.remapFields(remap),
      createdAt: a.createdAt,
      modifiedAt: a.modifiedAt,
    );
  }

  ({String key, String? entry, String? leaf}) _slot(
    WorkspaceDetail d,
    String id,
  ) {
    for (final e in d.fieldIds.entries) {
      if (e.value == id) return (key: e.key, entry: null, leaf: null);
    }
    for (final descriptor in workspaceFields(
      d,
    ).where((f) => f['type'] == 'entries')) {
      final key = descriptor['key'] as String;
      for (final e in WorkspaceRepeatedEntry.read(d.values[key])) {
        for (final leaf in e.fieldIds.entries) {
          if (leaf.value == id) return (key: key, entry: e.id, leaf: leaf.key);
        }
      }
    }
    throw const WorkspaceFailure('invalid_scope', '原字段身份无法对应，请重新读取提案。');
  }

  List<WorkspaceProposalFieldChange> _changes(
    core.UpdateProposal p,
    core.UpdatePreview preview,
    core.InformationItem after,
    WorkspaceDetail before,
    WorkspaceDetail proposed,
  ) {
    if (p.input.templateId != null) {
      return [
        for (final old in preview.before.fields)
          if (!after.fields.any((f) => f.id == old.id))
            (() {
              final slot = _slot(before, old.id);
              return WorkspaceProposalFieldChange(
                intent: WorkspaceProposalFieldIntent.remove,
                key: slot.key,
                entryId: slot.entry,
                leaf: slot.leaf,
                fieldId: old.id,
                label: old.name,
                before: old.value,
                beforeAvailable: true,
              );
            })(),
        for (final next in after.fields.where(
          (f) => f.kind != core.FieldKind.file,
        ))
          if (!preview.before.fields.any(
            (f) => f.id == next.id && f.value == next.value,
          ))
            (() {
              final old = preview.before.fields
                  .where((f) => f.id == next.id)
                  .firstOrNull;
              final slot = _slot(proposed, next.id);
              return WorkspaceProposalFieldChange(
                intent: old == null
                    ? WorkspaceProposalFieldIntent.add
                    : WorkspaceProposalFieldIntent.correct,
                key: slot.key,
                entryId: slot.entry,
                leaf: slot.leaf,
                fieldId: old?.id,
                label: next.name,
                before: old?.value,
                after: next.value,
                beforeAvailable: old != null,
              );
            })(),
      ];
    }
    final slots = preview.before.fields.map((f) => f.id).toList();
    final changedSlots = <int, String>{};
    for (final (index, c) in p.input.changes.indexed) {
      final slot = 'new:$index';
      switch (c.kind) {
        case core.FieldChangeKind.correct:
          break;
        case core.FieldChangeKind.remove:
          slots.remove(c.fieldId);
        case core.FieldChangeKind.add:
          slots.add(slot);
          changedSlots[index] = slot;
        case core.FieldChangeKind.replace:
          slots[slots.indexOf(c.fieldId!)] = slot;
          changedSlots[index] = slot;
      }
    }
    return [
      for (final (index, c) in p.input.changes.indexed)
        (() {
          final old = preview.before.fields
              .where((f) => f.id == c.fieldId)
              .firstOrNull;
          final next =
              c.kind == core.FieldChangeKind.add ||
                  c.kind == core.FieldChangeKind.replace
              ? after.fields[slots.indexOf(changedSlots[index]!)]
              : after.fields.where((f) => f.id == c.fieldId).firstOrNull;
          final slot = _slot(
            next == null ? before : proposed,
            (next ?? old)!.id,
          );
          return WorkspaceProposalFieldChange(
            intent: WorkspaceProposalFieldIntent.values.byName(c.kind.name),
            key: slot.key,
            entryId: slot.entry,
            leaf: slot.leaf,
            fieldId: c.fieldId,
            label: (next ?? old)!.name,
            before: old?.kind == core.FieldKind.file
                ? '普通附件（内容不在提案中展开）'
                : old?.value,
            after: next?.kind == core.FieldKind.file ? '普通附件' : next?.value,
            beforeAvailable: old != null,
            definition: null,
          );
        })(),
    ];
  }

  WorkspaceOrganizationOutcome _organizationOutcome(core.OrganizationTask t) =>
      switch (owner.organizationState(t)) {
        core.OrganizationTaskState.confirmed =>
          WorkspaceOrganizationOutcome.applied,
        core.OrganizationTaskState.conflicted =>
          WorkspaceOrganizationOutcome.conflicted,
        core.OrganizationTaskState.rejected =>
          WorkspaceOrganizationOutcome.rejected,
        core.OrganizationTaskState.expired =>
          WorkspaceOrganizationOutcome.expired,
        core.OrganizationTaskState.cancelled =>
          WorkspaceOrganizationOutcome.revoked,
        _ => WorkspaceOrganizationOutcome.proposed,
      };
  WorkspaceOrganizationLocation _location(core.InformationItem? item) =>
      WorkspaceOrganizationLocation(
        directoryId: item?.directoryId,
        directoryName: item == null
            ? '原分类已不可用'
            : owner.directories
                      .where((d) => d.id == item.directoryId)
                      .firstOrNull
                      ?.name ??
                  '未归档',
        tags: [
          if (item != null)
            for (final id in item.tagIds)
              WorkspaceTag(id, _tags[id] ?? '原标签已移除'),
        ],
      );
  WorkspaceOrganizationReport _organization(
    core.OrganizationTask task,
  ) => WorkspaceOrganizationReport(
    outcome: _organizationOutcome(task),
    at: task.completedAt ?? task.createdAt,
    legacyReview:
        !task.autoApply &&
        owner.organizationState(task) == core.OrganizationTaskState.proposed,
    requestId: task.id,
    approvedAt: task.approvedAt,
    expiresAt: task.expiresAt,
    members: [
      for (final e in task.itemVersions.entries)
        (() {
          final change = task.changes
              .where((c) => c.itemId == e.key)
              .firstOrNull;
          final before = _retained(e.key, e.value);
          final applied =
              task.state == core.OrganizationTaskState.confirmed &&
                  change != null
              ? _retained(e.key, e.value + 1)
              : null;
          final after = applied != null
              ? _location(applied)
              : change == null
              ? _location(before)
              : WorkspaceOrganizationLocation(
                  directoryId: change.directoryId,
                  directoryName: change.directoryName.isNotEmpty
                      ? change.directoryName
                      : owner.directories
                                .where((d) => d.id == change.directoryId)
                                .firstOrNull
                                ?.name ??
                            '未归档',
                  tags: [
                    for (final id in change.tagIds)
                      WorkspaceTag(id, _tags[id] ?? '原标签已移除'),
                    for (final name in change.tagNames)
                      WorkspaceTag('suggested:$name', name),
                  ],
                );
          return WorkspaceOrganizationMember(
            record: _ref(e.key),
            name: task.itemNames[e.key] ?? before?.name ?? '原资料',
            baseVersion: e.value,
            before: _location(before),
            after: after,
            resultVersion: task.state == core.OrganizationTaskState.confirmed
                ? e.value + (change == null ? 0 : 1)
                : null,
            exists: _current(e.key) != null,
          );
        })(),
    ],
  );
  WorkspaceProposalDetail _detail(String id) {
    final entry = _entry(id), summary = _summary(entry);
    final items = <WorkspaceProposalItem>[],
        targets = <WorkspaceProposalTarget>[];
    WorkspaceRecordRef? currentTarget;
    String? notice;
    WorkspaceOrganizationReport? organization;
    if (entry.kind == core.ProposalKind.addition) {
      final p = owner.importProposals.singleWhere((p) => p.id == id);
      if (p.state == core.ImportProposalState.pending) {
        final states = owner.importAdmission(id);
        final problems = states
            // Pending password input is tracked by the local review draft.
            .where((s) => s.state != 'pending' && s.reason.isNotEmpty)
            .map((s) => s.reason)
            .toSet();
        if (problems.isNotEmpty) notice = problems.join('\n');
        for (final input in p.items) {
          final candidate = 'proposal:$id:${input.key}';
          if (input.credential case final material?) {
            final definition = input.layout!.snapshot['definition'] as Map;
            items.add(
              WorkspaceProposalItem(
                id: candidate,
                admissionNote: states
                    .singleWhere((s) => s.key == input.key)
                    .reason,
                credential: WorkspaceProposalCredential(
                  source: material.source,
                  account: material.account,
                  contextExposed: material.contextExposed,
                  ready: material.ready,
                  fileName: material.fileName,
                  byteLength: material.material?.length,
                ),
                proposed: WorkspaceDetail(
                  record: WorkspaceRecordSummary(
                    ref: WorkspaceRecordRef(
                      WorkspaceRecordKind.credential,
                      candidate,
                    ),
                    name: input.name,
                    description: input.description,
                    type: WorkspaceType(
                      input.templateId!,
                      (input.layout!.snapshot['type'] as Map?)?['name']
                              as String? ??
                          _credentialTypeName(definition),
                      'key',
                    ),
                    updatedAt: p.createdAt,
                    directoryId: _importDirectory(input),
                    tags: [
                      for (final t in _importTags(input))
                        WorkspaceTag(
                          t,
                          _tags[t] ?? _suggestedTags[t] ?? '建议标签',
                        ),
                    ],
                  ),
                  version: p.version,
                  definition: {
                    ...Map<String, Object?>.from(definition),
                    'templateVersion': input.templateVersion,
                    'packageDigest': input.templateDigest,
                  },
                  relations: {
                    for (final group in {
                      ...input.relations.keys,
                      ...input.pendingRelations.keys,
                    })
                      group: [
                        for (final ref in input.relations[group] ?? [])
                          WorkspaceRecordRef(
                            WorkspaceRecordKind.values.byName(ref.kind),
                            ref.id,
                          ),
                        for (final ref in input.pendingRelations[group] ?? [])
                          WorkspaceRecordRef(
                            WorkspaceRecordKind.values.byName(ref.kind),
                            _pendingId(ref.proposalId ?? id, ref.itemKey),
                          ),
                      ],
                  },
                ),
              ),
            );
            continue;
          }
          final previewFields = [
            for (final (n, f) in input.fields.indexed)
              core.InformationField(
                '$candidate:$n',
                f.name,
                f.description,
                f.value,
                1,
                kind: f.kind,
              ),
          ];
          final bound = input.bindLayout(previewFields);
          final previewLayout = bound == null
              ? null
              : core.InformationLayout(
                  typeId: bound.typeId,
                  snapshot: bound.snapshot,
                  fieldIds: bound.fieldIds,
                  relations: {
                    for (final group in {
                      ...input.relations.keys,
                      ...input.pendingRelations.keys,
                    })
                      group: [
                        ...input.relations[group] ?? [],
                        for (final ref in input.pendingRelations[group] ?? [])
                          core.InformationRelationRef(
                            ref.kind,
                            _pendingId(ref.proposalId ?? id, ref.itemKey),
                          ),
                      ],
                  },
                );
          final item = core.InformationItem(
            candidate,
            input.name,
            input.description,
            1,
            previewFields,
            layout: previewLayout,
            directoryId: _importDirectory(input),
            tagIds: _importTags(input),
          );
          items.add(
            WorkspaceProposalItem(
              id: candidate,
              originalProposalVersion: p.version,
              admissionNote: states
                  .singleWhere((s) => s.key == input.key)
                  .reason,
              proposed: (() {
                final decoded = _codec.decode(
                  item,
                  tagNames: {
                    ..._tags,
                    for (final e in _suggestedTags.entries)
                      e.key: '建议新建：${e.value}',
                  },
                );
                final fileKeys = {
                  for (final a in input.attachments) ?a.templateField,
                };
                return WorkspaceDetail(
                  record: decoded.record,
                  version: decoded.version,
                  templateState: decoded.templateState,
                  definition: decoded.definition,
                  values: {
                    ...decoded.values,
                    for (final key in fileKeys) key: input.values[key],
                  },
                  relations: decoded.relations,
                  fieldIds: decoded.fieldIds,
                  fieldOverrides: {
                    for (final e in decoded.fieldOverrides.entries)
                      if (!fileKeys.contains(e.key)) e.key: e.value,
                  },
                  retainedFields: decoded.retainedFields,
                  retainedRelations: decoded.retainedRelations,
                );
              })(),
              attachments: [
                for (final a in input.attachments)
                  WorkspaceProposalAttachment(
                    key: a.key,
                    name: a.name,
                    description: a.description,
                    templateField: a.templateField,
                    currentVersion: a.currentVersion,
                    versions: [
                      for (final v in a.versions)
                        WorkspaceProposalOriginal(
                          filename: v.upload!.originalName,
                          mediaType: v.upload!.mediaType,
                          byteLength: v.upload!.byteLength,
                          label: v.label,
                          sourceNote: v.sourceNote,
                        ),
                    ],
                  ),
              ],
            ),
          );
        }
      }
      if (p.createdItemIds.isNotEmpty) {
        if (p.rejectedKeys.isNotEmpty) {
          notice =
              '已入库${p.createdItemIds.length}项；其余${p.rejectedKeys.length}项已拒绝。';
        }
        for (final (index, r) in p.receipts.indexed) {
          targets.add(
            WorkspaceProposalTarget(
              record: WorkspaceRecordRef(
                WorkspaceRecordKind.values.byName(r.kind),
                r.id,
              ),
              name: index < p.createdItemKeys.length
                  ? p.candidateNames[p.createdItemKeys[index]] ?? '已保存资料'
                  : '已保存资料',
              version: r.version,
              exists: r.kind == 'credential'
                  ? owner.credentials.any((c) => c.id == r.id)
                  : _current(r.id) != null,
              snapshotAvailable:
                  r.kind == 'information' && _retained(r.id, r.version) != null,
            ),
          );
        }
      }
    } else if (entry.kind == core.ProposalKind.modification) {
      final p = owner.updateProposals.singleWhere((p) => p.id == id);
      currentTarget = _ref(p.input.itemId);
      if (p.state == core.UpdateProposalState.pending &&
          entry.status != core.ProposalStatus.conflicted) {
        final preview = owner.previewUpdate(id);
        final stable = _stablePreview(p, preview);
        final after = core.InformationItem(
          stable.id,
          stable.name,
          stable.description,
          stable.version,
          stable.fields,
          directoryId: stable.directoryId,
          tagIds: stable.tagIds,
          createdAt: stable.createdAt,
          modifiedAt: stable.modifiedAt,
          layout: _pendingLayout(stable.layout, p.input.pendingRelations, p.id),
        );
        final admission = owner.updateAdmission(id);
        if (admission.reason.isNotEmpty) notice = admission.reason;
        final before = _codec.decode(preview.before, tagNames: _tags),
            proposed = _codec.decode(after, tagNames: _tags);
        items.add(
          WorkspaceProposalItem(
            id: p.input.itemId,
            originalProposalVersion: p.version,
            admissionNote: admission.reason,
            proposed: proposed,
            before: before,
            beforeState: WorkspaceProposalBeforeState.available,
            attachments: _attachments(
              p.input.attachments,
              update: p.input,
              before: preview.before,
              after: proposed,
            ),
            changes: _changes(p, preview, after, before, proposed),
          ),
        );
      } else if (p.result != null) {
        targets.add(
          WorkspaceProposalTarget(
            record: _ref(p.result!.itemId),
            name: _current(p.result!.itemId)?.name ?? '已修改资料',
            version: p.result!.version,
            exists: _current(p.result!.itemId) != null,
            snapshotAvailable:
                _retained(p.result!.itemId, p.result!.version) != null,
          ),
        );
      }
    } else if (entry.kind == core.ProposalKind.deletion) {
      final p = owner.deleteProposals.singleWhere((p) => p.id == id);
      currentTarget = _ref(p.itemId);
      if (p.state == core.DeleteProposalState.pending &&
          entry.status != core.ProposalStatus.conflicted) {
        final before = owner.previewDelete(id),
            d = _codec.decode(before, tagNames: _tags);
        final removed = p.fieldId == null
            ? before.fields
            : before.fields.where((f) => f.id == p.fieldId);
        items.add(
          WorkspaceProposalItem(
            id: p.itemId,
            proposed: d,
            before: d,
            beforeState: WorkspaceProposalBeforeState.available,
            changes: [
              for (final f in removed)
                (() {
                  final slot = _slot(d, f.id);
                  return WorkspaceProposalFieldChange(
                    intent: WorkspaceProposalFieldIntent.remove,
                    key: slot.key,
                    entryId: slot.entry,
                    leaf: slot.leaf,
                    fieldId: f.id,
                    label: f.name,
                    before: f.kind == core.FieldKind.file
                        ? '普通附件（内容不在提案中展开）'
                        : f.value,
                    beforeAvailable: true,
                  );
                })(),
            ],
          ),
        );
      } else if (p.state == core.DeleteProposalState.confirmed) {
        targets.add(
          WorkspaceProposalTarget(
            record: _ref(p.itemId),
            name: _retained(p.itemId, p.baseVersion)?.name ?? '已删除资料',
            version: p.baseVersion,
            exists: _current(p.itemId) != null,
            snapshotAvailable: _retained(p.itemId, p.baseVersion) != null,
          ),
        );
      }
    } else {
      final t = owner.organizationTasks.singleWhere((t) => t.id == id);
      organization = _organization(t);
      if (summary.pending) {
        for (final c in t.changes) {
          final before = _retained(c.itemId, c.baseVersion);
          final record = WorkspaceRecordSummary(
            ref: _ref(c.itemId),
            name: before?.name ?? t.itemNames[c.itemId] ?? '原资料',
            description: '',
            updatedAt:
                before?.modifiedAt ??
                before?.createdAt ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            type: const WorkspaceType('generic', '通用资料', 'document'),
          );
          items.add(
            WorkspaceProposalItem(
              id: c.itemId,
              proposed: WorkspaceDetail(
                record: record,
                version: c.baseVersion + 1,
                definition: const {'fields': <Object?>[]},
                values: const {},
              ),
            ),
          );
        }
      }
    }
    if (summary.status == WorkspaceProposalStatus.conflicted) {
      notice = '原资料版本已变化，本批提案尚未应用。可核对当前资料或拒绝原提案。';
    }
    WorkspaceProposalDetail result(String token) => WorkspaceProposalDetail(
      summary: summary,
      reviewToken: token,
      items: items,
      targets: targets,
      notice: notice,
      currentTargetRef: currentTarget,
      currentAvailable:
          currentTarget != null && _current(currentTarget.id) != null,
      organization: organization,
      directoryFingerprint: summary.pending
          ? sha256
                .convert(
                  utf8.encode(
                    jsonEncode([
                      for (final d in owner.directories)
                        [d.id, d.name, d.parentId, d.version],
                    ]),
                  ),
                )
                .toString()
          : '',
    );
    return result(result('').snapshotDigest);
  }

  @override
  Future<WorkspaceProposalDetail> read(String id) =>
      _run(() async => _detail(id));
  WorkspaceProposalReceipt _receipt(core.OwnerProposalReceipt r) =>
      WorkspaceProposalReceipt(
        operationId: r.command.operationId,
        proposalId: r.command.proposalId,
        action: r.command.confirm
            ? WorkspaceProposalAction.confirm
            : WorkspaceProposalAction.reject,
        reviewToken: r.command.reviewToken,
        reviewedVersion: r.command.version,
        resultingVersion: r.resultingVersion,
        commandDigest: r.command.commandDigest,
        records: r.records.map(
          (r) => WorkspaceRecordReceipt(
            ref: WorkspaceRecordRef(
              WorkspaceRecordKind.values.byName(r.kind),
              r.id,
            ),
            version: r.version,
            entryId: r.recycleId,
          ),
        ),
        awaitingItemIds: r.awaitingKeys.map(
          (key) => r.command.kind == core.ProposalKind.modification
              ? key
              : 'proposal:${r.command.proposalId}:$key',
        ),
      );
  @override
  Future<WorkspaceProposalReceipt?> receipt(String id) => _run(() async {
    final r = await owner.ownerProposalReceipt(id);
    return r == null ? null : _receipt(r);
  });
  void _validateReview(WorkspaceProposalChange c, WorkspaceProposalDetail d) {
    if (c.version != d.summary.version ||
        c.reviewToken != d.reviewToken ||
        !d.summary.pending ||
        c.action == WorkspaceProposalAction.confirm && !d.canConfirm) {
      throw const core.AccessFailure('proposal_changed');
    }
    if (c.action == WorkspaceProposalAction.reject) {
      if (c.reviewed.isNotEmpty) {
        throw const WorkspaceFailure('validation', '拒绝决定不应携带入库内容。');
      }
      return;
    }
    if (c.reviewed.isEmpty ||
        c.reviewed.map((r) => r.itemId).toSet().length != c.reviewed.length ||
        c.reviewed.any((r) => !d.items.any((i) => i.id == r.itemId)) ||
        d.summary.kind != WorkspaceProposalKind.addition &&
            c.reviewed.length != d.items.length) {
      throw const WorkspaceFailure('validation', '请选择原提案中的准确资料范围。');
    }
    for (final r in c.reviewed) {
      if (d.summary.kind != WorkspaceProposalKind.addition &&
          r.suggestedDirectory.isNotEmpty) {
        throw const WorkspaceFailure('validation', '修改资料时请选择已有目录。');
      }
      final original = d.items.singleWhere((i) => i.id == r.itemId).proposed;
      for (final descriptor in workspaceFields(
        original,
      ).where((f) => f['type'] == 'entries')) {
        final key = descriptor['key'] as String;
        final before = WorkspaceRepeatedEntry.read(original.values[key]);
        final after = WorkspaceRepeatedEntry.read(r.values[key]);
        if (before.length != after.length ||
            before.any(
              (e) => !after.any(
                (a) =>
                    a.id == e.id &&
                    jsonEncode(a.fieldIds) == jsonEncode(e.fieldIds) &&
                    jsonEncode(a.toJson()['definitions']) ==
                        jsonEncode(e.toJson()['definitions']),
              ),
            )) {
          throw const WorkspaceFailure(
            'validation',
            '请保留提案原有的经历与字段身份；结构调整可在入库后管理。',
          );
        }
      }
      if (r.values.keys
              .toSet()
              .difference(original.values.keys.toSet())
              .isNotEmpty ||
          original.values.keys
              .toSet()
              .difference(r.values.keys.toSet())
              .isNotEmpty) {
        throw const WorkspaceFailure('validation', '提案字段身份已变化，请重新核对。');
      }
      String relations(Map<String, List<WorkspaceRecordRef>> v) => jsonEncode({
        for (final e in v.entries) e.key: e.value.map((r) => r.key).toList(),
      });
      if (original.definition['templateVersion'] == null &&
          relations(r.relations) != relations(original.relations)) {
        throw const WorkspaceFailure(
          'validation',
          '此提案协议保留原关联；如需变更，请在资料入库后管理关联。',
        );
      }
      if ({
            WorkspaceProposalKind.organization,
            WorkspaceProposalKind.deletion,
          }.contains(d.summary.kind) &&
          jsonEncode(r.toJson()) !=
              jsonEncode(
                WorkspaceProposalItemReview.fromItem(
                  d.items.singleWhere((i) => i.id == r.itemId),
                ).toJson(),
              )) {
        throw const WorkspaceFailure('validation', '删除和整理决定按原范围应用，不能同时修改资料正文。');
      }
    }
  }

  String _value(WorkspaceProposalItemReview r, WorkspaceProposalFieldChange c) {
    final raw = c.entryId == null
        ? r.values[c.key]
        : WorkspaceRepeatedEntry.read(
            r.values[c.key],
          ).where((e) => e.id == c.entryId).firstOrNull?.toJson()[c.leaf];
    if (raw is! String) {
      throw const WorkspaceFailure('validation', '请核对提案字段内容。');
    }
    return raw;
  }

  Map<String, Object?> _templateValues(
    WorkspaceDetail detail,
    WorkspaceProposalItemReview review, {
    core.UpdateInput? input,
  }) => {
    for (final field in detail.definition['fields'] as List)
      field['key'] as String: field['type'] == 'file'
          ? input!.values[field['key']]
          : field['type'] == 'entries'
          ? [
              for (final row in review.values[field['key']] as List? ?? [])
                {
                  for (final part in ['title', 'period', 'detail'])
                    part: (row as Map)[part] ?? '',
                },
            ]
          : review.values[field['key']] ?? '',
  };

  @override
  Future<WorkspaceProposalReceipt> change(
    WorkspaceProposalChange c,
  ) => _run(() async {
    final previous = await owner.ownerProposalReceipt(c.operationId);
    if (previous != null) {
      if (previous.command.commandDigest != c.digest) {
        throw const WorkspaceFailure('operation_conflict', '原操作不能用于另一份决定。');
      }
      return _receipt(previous);
    }
    final d = _detail(c.proposalId);
    _validateReview(c, d);
    final command = core.OwnerProposalCommand(
      operationId: c.operationId,
      proposalId: c.proposalId,
      kind: core.ProposalKind.values.byName(d.summary.kind.name),
      confirm: c.action == WorkspaceProposalAction.confirm,
      version: c.version,
      reviewToken: c.reviewToken,
      commandDigest: c.digest,
    );
    final result = await owner.performProposalDecision(
      command,
      validate: () => _validateReview(c, _detail(c.proposalId)),
      decide: () async {
        switch (d.summary.kind) {
          case WorkspaceProposalKind.addition:
            if (c.action == WorkspaceProposalAction.reject) {
              await owner.rejectImport(c.proposalId, c.version);
              break;
            }
            final p = owner.importProposals.singleWhere(
              (p) => p.id == c.proposalId,
            );
            await owner.confirmImport(c.proposalId, c.version, [
              for (final r in c.reviewed)
                (() {
                  final index = d.items.indexWhere((i) => i.id == r.itemId),
                      input = p.items[index],
                      detail = d.items[index].proposed;
                  return core.ImportItemInput(
                    r.name,
                    r.description,
                    input.templateId != null
                        ? const []
                        : [
                            for (final (n, f) in input.fields.indexed)
                              core.FieldInput(
                                f.name,
                                f.description,
                                r.values[detail.fieldIds.entries
                                        .singleWhere(
                                          (e) => e.value == '${r.itemId}:$n',
                                        )
                                        .key]
                                    as String,
                                kind: f.kind,
                              ),
                          ],
                    templateId: input.templateId,
                    key: input.key,
                    credential: input.credential,
                    attachments: input.attachments,
                    templateVersion: input.templateVersion,
                    templateDigest: input.templateDigest,
                    relations: _reviewRelations(
                      r,
                      p.id,
                      declaredKeys: {
                        for (final rule
                            in detail.definition['relations'] as List? ?? [])
                          (rule as Map)['key'] as String,
                      },
                    ).existing,
                    pendingRelations: _reviewRelations(
                      r,
                      p.id,
                      declaredKeys: {
                        for (final rule
                            in detail.definition['relations'] as List? ?? [])
                          (rule as Map)['key'] as String,
                      },
                    ).pending,
                    values: input.templateId == null
                        ? const {}
                        : {
                            for (final field
                                in detail.definition['fields'] as List)
                              field['key'] as String: field['type'] == 'file'
                                  ? input.values[field['key']] ?? ''
                                  : field['type'] == 'entries'
                                  ? [
                                      for (final row
                                          in r.values[field['key']] as List? ??
                                              [])
                                        {
                                          for (final part in [
                                            'title',
                                            'period',
                                            'detail',
                                          ])
                                            part: (row as Map)[part] ?? '',
                                        },
                                    ]
                                  : r.values[field['key']] ?? '',
                          },
                    directoryId:
                        r.suggestedDirectory.isNotEmpty ||
                            _suggestedDirectories.containsKey(r.directoryId)
                        ? null
                        : r.directoryId,
                    suggestedDirectory: r.suggestedDirectory.isNotEmpty
                        ? r.suggestedDirectory
                        : _suggestedDirectories[r.directoryId] ?? '',
                    tagIds: r.tagIds.where(
                      (id) => !_suggestedTags.containsKey(id),
                    ),
                    suggestedTags: r.tagIds
                        .where(_suggestedTags.containsKey)
                        .map((id) => _suggestedTags[id]!),
                  );
                })(),
            ]);
          case WorkspaceProposalKind.modification:
            if (c.action == WorkspaceProposalAction.reject) {
              await owner.rejectUpdate(c.proposalId, c.version);
              break;
            }
            final p = owner.updateProposals.singleWhere(
                  (p) => p.id == c.proposalId,
                ),
                r = c.reviewed.single,
                item = d.items.single;
            if (p.input.templateId != null) {
              await owner.confirmUpdate(
                c.proposalId,
                c.version,
                review: core.UpdateReview(
                  core.UpdateInput(
                    p.input.itemId,
                    p.input.baseVersion,
                    const [],
                    name: r.name,
                    description: r.description,
                    templateId: p.input.templateId,
                    templateVersion: p.input.templateVersion,
                    templateDigest: p.input.templateDigest,
                    values: _templateValues(item.proposed, r, input: p.input),
                    attachments: p.input.attachments,
                    filePlan: p.input.filePlan,
                    compiledTemplate: p.input.compiledTemplate,
                    relations: _reviewRelations(
                      r,
                      p.id,
                      declaredKeys: {
                        for (final rule
                            in item.proposed.definition['relations'] as List? ??
                                [])
                          (rule as Map)['key'] as String,
                      },
                    ).existing,
                    pendingRelations: _reviewRelations(
                      r,
                      p.id,
                      declaredKeys: {
                        for (final rule
                            in item.proposed.definition['relations'] as List? ??
                                [])
                          (rule as Map)['key'] as String,
                      },
                    ).pending,
                  ),
                  directoryId: r.directoryId,
                  tagIds: r.tagIds,
                ),
              );
              break;
            }
            final changes = <core.FieldChange>[];
            for (final (index, original) in p.input.changes.indexed) {
              final change = item.changes[index];
              changes.add(switch (original.kind) {
                core.FieldChangeKind.correct => core.FieldChange.correct(
                  original.fieldId!,
                  _value(r, change),
                ),
                core.FieldChangeKind.remove => core.FieldChange.remove(
                  original.fieldId!,
                ),
                core.FieldChangeKind.add => core.FieldChange.add(
                  core.FieldInput(
                    original.field!.name,
                    original.field!.description,
                    _value(r, change),
                    kind: original.field!.kind,
                  ),
                ),
                core.FieldChangeKind.replace => core.FieldChange.replace(
                  original.fieldId!,
                  core.FieldInput(
                    original.field!.name,
                    original.field!.description,
                    _value(r, change),
                    kind: original.field!.kind,
                  ),
                ),
              });
            }
            final touched = p.input.changes
                .map((change) => change.fieldId)
                .whereType<String>()
                .toSet();
            final current = owner.information.singleWhere(
              (i) => i.id == p.input.itemId,
            );
            for (final field in current.fields.where(
              (f) => !touched.contains(f.id),
            )) {
              final slot = _slot(item.proposed, field.id);
              final probe = WorkspaceProposalFieldChange(
                intent: WorkspaceProposalFieldIntent.correct,
                key: slot.key,
                entryId: slot.entry,
                leaf: slot.leaf,
                label: field.name,
              );
              if (field.kind == core.FieldKind.file) {
                if (jsonEncode(r.values[slot.key]) !=
                    jsonEncode(item.proposed.values[slot.key])) {
                  throw const WorkspaceFailure(
                    'validation',
                    '普通附件通过资料文件管理替换，不能在文字提案中更换。',
                  );
                }
              } else {
                final value = _value(r, probe);
                if (value != field.value) {
                  changes.add(core.FieldChange.correct(field.id, value));
                }
              }
            }
            await owner.confirmUpdate(
              c.proposalId,
              c.version,
              review: core.UpdateReview(
                core.UpdateInput(
                  p.input.itemId,
                  p.input.baseVersion,
                  changes,
                  attachments: p.input.attachments,
                  filePlan: p.input.filePlan,
                  name: r.name,
                  description: r.description,
                ),
                directoryId: r.directoryId,
                tagIds: r.tagIds,
              ),
            );
          case WorkspaceProposalKind.deletion:
            if (c.action == WorkspaceProposalAction.reject) {
              await owner.rejectDelete(c.proposalId, c.version);
            } else {
              await owner.confirmDelete(c.proposalId, c.version);
            }
          case WorkspaceProposalKind.organization:
            if (c.action == WorkspaceProposalAction.reject) {
              await owner.rejectOrganization(c.proposalId);
            } else {
              await owner.confirmOrganization(c.proposalId);
            }
        }
      },
    );
    changed();
    return _receipt(result);
  });
  @override
  Future<WorkspaceCatalog> catalog() => _run(() async {
    final original = await library().loadCatalog();
    final directories = List<WorkspaceDirectory>.of(original.directories);
    for (final path in _suggestedDirectories.values) {
      String? parent;
      final parts = path.split('/');
      if (parts.length > 8 ||
          parts.any(
            (p) => p.isEmpty || p == '.' || p == '..' || p.contains(r'\'),
          )) {
        continue;
      }
      for (var n = 0; n < parts.length; n++) {
        final part = parts[n];
        final existing = directories
            .where(
              (d) =>
                  d.parentId == parent &&
                  d.name.toLowerCase() == part.toLowerCase(),
            )
            .firstOrNull;
        if (existing != null) {
          parent = existing.id;
          continue;
        }
        final id = _suggestionId('directory', parts.take(n + 1).join('/'));
        directories.add(
          WorkspaceDirectory(id, part, parentId: parent, proposed: true),
        );
        parent = id;
      }
    }
    return WorkspaceCatalog(
      directories: directories,
      tags: [
        ...original.tags,
        for (final e in _suggestedTags.entries)
          if (!owner.tags.any(
            (t) => t.name.toLowerCase() == e.value.toLowerCase(),
          ))
            WorkspaceTag(e.key, '建议新建：${e.value}'),
      ],
      types: original.types,
      creatableTypes: original.creatableTypes,
      directoryCounts: original.directoryCounts,
      tagCounts: original.tagCounts,
      version: original.version,
      recycledCount: original.recycledCount,
    );
  });
  @override
  WorkspaceRelationSource relations(
    String proposalId,
    String itemId,
    int version,
  ) => _ProposalRelations(this, proposalId, itemId, version);
  String _credentialTypeName(Map definition) =>
      switch ((definition['credential'] as Map?)?['secretKind']) {
        'accountPassword' => '账号密码',
        'token' => 'API Key / Token',
        'file' => '凭据文件',
        _ => '凭据',
      };

  WorkspaceProposalItem _credentialPreview(core.ManagedCredential credential) {
    final layout = credential.template;
    final definition = Map<String, Object?>.from(
      layout?.snapshot['definition'] as Map? ?? {'fields': [], 'sections': []},
    );
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.credential,
      credential.id,
    );
    return WorkspaceProposalItem(
      id: ref.key,
      credential: WorkspaceProposalCredential(
        source: credential.form == core.CredentialForm.file
            ? 'agentFile'
            : 'stored',
        contextExposed: false,
        ready: true,
        account: credential.account,
        fileName: credential.fileName,
      ),
      proposed: WorkspaceDetail(
        record: WorkspaceRecordSummary(
          ref: ref,
          name: credential.name,
          description: credential.publicPurpose,
          type: ownerCredentialType(credential),
          updatedAt: credential.modifiedAt,
          directoryId: credential.directoryId,
          tags: [
            for (final id in credential.tagIds)
              WorkspaceTag(id, _tags[id] ?? '标签'),
          ],
        ),
        version: credential.revision,
        definition: definition,
        relations: {
          if (layout != null)
            for (final e in layout.relations.entries)
              e.key: [
                for (final ref in e.value)
                  WorkspaceRecordRef(
                    WorkspaceRecordKind.values.byName(ref.kind),
                    ref.id,
                  ),
              ],
        },
      ),
    );
  }

  @override
  WorkspaceRelationSource previewRelations() => library();

  @override
  Future<WorkspaceProposalItem> previewRelated(
    String proposalId,
    int version,
    WorkspaceRecordRef record, {
    WorkspaceProposalItemReview? review,
  }) => _run(() async {
    final proposal = _detail(proposalId);
    final reviewedRef =
        review != null &&
        proposal.items.any((i) => i.id == review.itemId) &&
        review.relations.values.expand((refs) => refs).contains(record);
    if (proposal.summary.version != version ||
        !reviewedRef &&
            !proposal.items.any(
              (i) => i.proposed.visibleRelations.values
                  .expand((refs) => refs)
                  .contains(record),
            )) {
      throw const WorkspaceFailure('conflict', '关联范围已变化，请重新读取提案。');
    }
    final pending = _pendingTarget(record.id);
    if (pending != null) {
      final target = _detail(pending.proposal.id).items
          .where(
            (i) => i.id == 'proposal:${pending.proposal.id}:${pending.key}',
          )
          .firstOrNull;
      if (target == null) {
        throw const WorkspaceFailure('not_found', '待录入的关联内容已变化，请重新核对。');
      }
      return target;
    }
    if (record.kind == WorkspaceRecordKind.credential) {
      final credential = owner.credentials
          .where((c) => c.id == record.id)
          .firstOrNull;
      if (credential == null) {
        throw const WorkspaceFailure('not_found', '关联凭据已不可用。');
      }
      return _credentialPreview(credential);
    }
    return WorkspaceProposalItem(
      id: record.key,
      proposed: await library().readDetail(record),
    );
  });

  @override
  Future<WorkspaceProposalItem> savedPreview(
    String proposalId,
    WorkspaceRecordRef record,
  ) => _run(() async {
    final proposal = _detail(proposalId);
    final target = proposal.targets
        .where((t) => t.record == record)
        .firstOrNull;
    if (target == null) {
      throw const WorkspaceFailure('not_found', '这份提案没有保存此资料。');
    }
    if (record.kind == WorkspaceRecordKind.credential) {
      final current = owner.credentials
          .where((c) => c.id == record.id && c.deletedAt == null)
          .firstOrNull;
      final original = owner.importProposals
          .where((p) => p.id == proposalId)
          .firstOrNull;
      final credential =
          original?.credentialSnapshots.values
              .where((c) => c.id == record.id)
              .firstOrNull ??
          (current?.revision == target.version ? current : null);
      if (current == null || credential == null) {
        throw const WorkspaceFailure(
          'history_unavailable',
          '这次保存的凭据说明暂不可用，当前内容不会替代历史内容。',
        );
      }
      return _credentialPreview(credential);
    }
    final saved = (await snapshot(proposalId, record)).detail;
    final before = proposal.summary.kind == WorkspaceProposalKind.modification
        ? _retained(record.id, target.version - 1)
        : null;
    return WorkspaceProposalItem(
      id: record.key,
      proposed: saved,
      before: before == null ? null : _codec.decode(before, tagNames: _tags),
      beforeState: before == null
          ? WorkspaceProposalBeforeState.unavailable
          : WorkspaceProposalBeforeState.available,
    );
  });

  @override
  Future<WorkspaceFilePreview> pendingOriginal(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    int page = 0,
    WorkspaceProposalItemReview? review,
    int? originalProposalVersion,
  }) => _pendingOriginal(
    proposalId,
    proposalVersion,
    itemId,
    attachmentKey,
    version,
    review: review,
    originalProposalVersion: originalProposalVersion,
    read: (p, pv, i, a, v) => _originals.pending(p, pv, i, a, v, page: page),
  );
  Future<WorkspaceFileOriginal> pendingOriginalContent(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    WorkspaceProposalItemReview? review,
    int? originalProposalVersion,
  }) => _pendingOriginal(
    proposalId,
    proposalVersion,
    itemId,
    attachmentKey,
    version,
    review: review,
    originalProposalVersion: originalProposalVersion,
    read: _contents.pending,
  );
  @override
  Future<WorkspaceFilePreview> storedOriginal(
    String proposalId,
    int proposalVersion,
    WorkspaceRecordRef record,
    String fieldKey,
    WorkspaceFileRef file, {
    int page = 0,
    WorkspaceProposalItemReview? review,
  }) => _storedOriginal(
    proposalId,
    proposalVersion,
    record,
    fieldKey,
    file,
    review: review,
    read: (ref) => _originals.stored(ref, page: page),
  );
  Future<WorkspaceFileOriginal> storedOriginalContent(
    String proposalId,
    int proposalVersion,
    WorkspaceRecordRef record,
    String fieldKey,
    WorkspaceFileRef file, {
    WorkspaceProposalItemReview? review,
  }) => _storedOriginal(
    proposalId,
    proposalVersion,
    record,
    fieldKey,
    file,
    review: review,
    read: _contents.stored,
  );

  Future<T> _pendingOriginal<T>(
    String proposalId,
    int proposalVersion,
    String itemId,
    String attachmentKey,
    int version, {
    required Future<T> Function(String, int, String, String, int) read,
    WorkspaceProposalItemReview? review,
    int? originalProposalVersion,
  }) => _run(() async {
    final proposal = _detail(proposalId);
    if (proposal.summary.version != proposalVersion ||
        (originalProposalVersion != null &&
            proposal.items.any((i) => i.id == itemId) &&
            originalProposalVersion != proposalVersion)) {
      throw const WorkspaceFailure('conflict', '提案已变化，请重新核对。');
    }
    if (proposal.items.any((i) => i.id == itemId)) {
      return read(proposalId, proposalVersion, itemId, attachmentKey, version);
    }
    final ref = WorkspaceRecordRef(
      WorkspaceRecordKind.information,
      itemId.replaceFirst('proposal:', 'pending:'),
    );
    final target = await previewRelated(
      proposalId,
      proposalVersion,
      ref,
      review: review,
    );
    final pending = _pendingTarget(ref.id);
    if (pending == null ||
        target.id != itemId ||
        originalProposalVersion != pending.proposal.version) {
      throw const WorkspaceFailure('not_found', '关联原文已不可用。');
    }
    return read(
      pending.proposal.id,
      pending.proposal.version,
      itemId,
      attachmentKey,
      version,
    );
  });

  Future<T> _storedOriginal<T>(
    String proposalId,
    int proposalVersion,
    WorkspaceRecordRef record,
    String fieldKey,
    WorkspaceFileRef file, {
    required Future<T> Function(core.InformationAttachmentRef) read,
    WorkspaceProposalItemReview? review,
  }) => _run(() async {
    final proposal = _detail(proposalId);
    if (proposal.summary.version != proposalVersion ||
        record.kind != WorkspaceRecordKind.information) {
      throw const WorkspaceFailure('conflict', '提案已变化，请重新核对文件。');
    }
    final bodies = <WorkspaceDetail>[
      for (final item in proposal.items) ...[
        if (item.proposed.record.ref == record) item.proposed,
        if (item.before?.record.ref == record &&
            item.beforeState == WorkspaceProposalBeforeState.available)
          item.before!,
      ],
    ];
    for (final target in proposal.targets.where((t) => t.record == record)) {
      final saved = _retained(record.id, target.version);
      if (saved != null) bodies.add(_codec.decode(saved, tagNames: _tags));
      if (proposal.summary.kind == WorkspaceProposalKind.modification) {
        final before = _retained(record.id, target.version - 1);
        if (before != null) bodies.add(_codec.decode(before, tagNames: _tags));
      }
    }
    if (bodies.isEmpty) {
      bodies.add(
        (await previewRelated(
          proposalId,
          proposalVersion,
          record,
          review: review,
        )).proposed,
      );
    }
    final allowed = bodies.any((body) {
      try {
        return WorkspaceFileRef.fromJson(body.values[fieldKey]) == file;
      } on WorkspaceFailure {
        return false;
      }
    });
    if (!allowed) throw const WorkspaceFailure('not_found', '这份内容没有引用所选文件版本。');
    return read(core.InformationAttachmentRef(file.id, file.version));
  });

  @override
  Future<WorkspaceDetail> currentTarget(String id) => _run(() async {
    final d = _detail(id), ref = d.currentTargetRef;
    if (ref == null || !d.currentAvailable) {
      throw const WorkspaceFailure('not_found', '当前原资料不可用。');
    }
    return library().readDetail(ref);
  });
  @override
  Future<WorkspaceArchive> snapshot(
    String id,
    WorkspaceRecordRef record,
  ) => _run(() async {
    final d = _detail(id),
        target = d.targets.where((t) => t.record == record).firstOrNull;
    final item = target == null ? null : _retained(record.id, target.version);
    if (item == null) {
      throw const WorkspaceFailure('not_found', '准确保存版本已到期或不可用，当前版本不会代替原快照。');
    }
    final detail = _codec.decode(item, tagNames: _tags);
    final targets = await library().readSummaries(
      detail.relations.values.expand((r) => r),
    );
    return WorkspaceArchive(
      detail: detail,
      archivedAt: d.summary.at,
      directoryName: owner.directories
          .where((d) => d.id == item.directoryId)
          .firstOrNull
          ?.name,
      targets: {for (final t in targets) t.ref: t},
    );
  });
}

class _ProposalRelations implements WorkspaceRelationSource {
  _ProposalRelations(this.source, this.id, this.itemId, this.version);
  final OwnerWorkspaceProposals source;
  final String id, itemId;
  final int version;
  Future<T> _run<T>(Future<T> Function() action) => source._run(() async {
    final d = source._detail(id);
    if (d.summary.version != version || !d.items.any((i) => i.id == itemId)) {
      throw const WorkspaceFailure('conflict', '提案已变化，请重新读取关联范围。');
    }
    return action();
  });
  @override
  Future<WorkspaceResults> queryRelationCandidates(WorkspaceRelationQuery q) =>
      _run(() => source.library().queryRelationCandidates(q));
  @override
  Future<List<WorkspaceRecordSummary>> readSummaries(
    Iterable<WorkspaceRecordRef> refs,
  ) => _run(() async {
    final requested = refs.toSet();
    final pending = {
      for (final ref in requested) ref: ?source._pendingTarget(ref.id),
    };
    return [
      ...await source.library().readSummaries(
        requested.where((r) => !pending.containsKey(r)),
      ),
      for (final e in pending.entries)
        (() {
          final p = e.value.proposal, key = e.value.key;
          final input = p.items.where((i) => i.key == key).firstOrNull;
          final type = input?.layout?.snapshot['type'] as Map?;
          return WorkspaceRecordSummary(
            ref: e.key,
            name:
                '${p.candidateNames[key] ?? '关联资料'}${p.rejectedKeys.contains(key) ? '（已拒绝）' : '（待入库）'}',
            description: '',
            type: WorkspaceType(
              input?.templateId ?? 'generic',
              type?['name'] as String? ?? '待录入资料',
              type?['icon'] as String? ?? 'file',
            ),
            updatedAt: p.createdAt,
          );
        })(),
    ];
  });
}
