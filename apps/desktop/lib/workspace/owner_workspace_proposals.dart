import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart' as core;
import 'workspace_information_codec.dart';
import 'workspace_entries.dart';
import 'workspace_source.dart';

class OwnerWorkspaceProposals implements WorkspaceProposalSource {
  OwnerWorkspaceProposals({
    required this.owner,
    required this.library,
    required this.changed,
  }) : _scope = owner.captureLibraryScope();
  final core.OwnerAccess owner;
  final WorkspaceSource Function() library;
  final void Function() changed;
  final core.OwnerLibraryScope _scope;
  final _codec = WorkspaceInformationCodec();
  String _suggestionId(String kind, String name) =>
      'proposed-$kind:${sha256.convert(utf8.encode(name.trim().toLowerCase()))}';
  Map<String, String> get _suggestedDirectories => {
    for (final p in owner.importProposals)
      for (final i in p.items)
        if (i.suggestedDirectory.trim().isNotEmpty)
          _suggestionId('directory', i.suggestedDirectory): i.suggestedDirectory
              .trim(),
  };
  Map<String, String> get _suggestedTags => {
    for (final p in owner.importProposals)
      for (final i in p.items)
        for (final name in i.suggestedTags)
          if (name.trim().isNotEmpty) _suggestionId('tag', name): name.trim(),
  };
  String? _importDirectory(core.ImportItemInput i) =>
      i.directoryId ??
      (i.suggestedDirectory.trim().isEmpty
          ? null
          : owner.directories
                    .where(
                      (d) =>
                          d.parentId == null &&
                          d.name.toLowerCase() ==
                              i.suggestedDirectory.trim().toLowerCase(),
                    )
                    .firstOrNull
                    ?.id ??
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
      title: switch (e.kind) {
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
      agentClaim: e.agentName.isEmpty ? '未提供 Agent 名称' : e.agentName,
      chatClaim: e.chatLabel,
      purpose: e.purpose.isEmpty ? '原提案未提供用途说明' : e.purpose,
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
        if (!beforeIds.contains(f.id)) f.id: 'proposal:${p.id}:$index',
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
        for (final (index, input) in p.items.indexed) {
          final candidate = 'proposal:$id:$index';
          final item = core.InformationItem(
            candidate,
            input.name,
            input.description,
            1,
            [
              for (final (n, f) in input.fields.indexed)
                core.InformationField(
                  '$candidate:$n',
                  f.name,
                  f.description,
                  f.value,
                  1,
                  kind: f.kind,
                ),
            ],
            directoryId: _importDirectory(input),
            tagIds: _importTags(input),
          );
          items.add(
            WorkspaceProposalItem(
              id: candidate,
              proposed: _codec.decode(
                item,
                tagNames: {
                  ..._tags,
                  for (final e in _suggestedTags.entries)
                    e.key: '建议新建：${e.value}',
                },
              ),
            ),
          );
        }
      } else if (p.state == core.ImportProposalState.confirmed) {
        for (final (index, r) in p.receipts.indexed) {
          targets.add(
            WorkspaceProposalTarget(
              record: _ref(r.id),
              name: index < p.itemNames.length ? p.itemNames[index] : '已保存资料',
              version: r.version,
              exists: _current(r.id) != null,
              snapshotAvailable: _retained(r.id, r.version) != null,
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
        final after = _stablePreview(p, preview);
        final before = _codec.decode(preview.before, tagNames: _tags),
            proposed = _codec.decode(after, tagNames: _tags);
        items.add(
          WorkspaceProposalItem(
            id: p.input.itemId,
            proposed: proposed,
            before: before,
            beforeState: WorkspaceProposalBeforeState.available,
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
            ref: _ref(r.id),
            version: r.version,
            entryId: r.recycleId,
          ),
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
      if (relations(r.relations) != relations(original.relations)) {
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

  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange c) =>
      _run(() async {
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
                        [
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
                        directoryId:
                            _suggestedDirectories.containsKey(r.directoryId)
                            ? null
                            : r.directoryId,
                        suggestedDirectory:
                            _suggestedDirectories[r.directoryId] ?? '',
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
    return WorkspaceCatalog(
      directories: [
        ...original.directories,
        for (final e in _suggestedDirectories.entries)
          if (!owner.directories.any(
            (d) =>
                d.parentId == null &&
                d.name.toLowerCase() == e.value.toLowerCase(),
          ))
            WorkspaceDirectory(e.key, '建议新建：${e.value}'),
      ],
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
  ) => _run(() => source.library().readSummaries(refs));
}
