part of 'info_core.dart';

enum ProposalKind { addition, modification, deletion, organization }

enum ProposalStatus {
  pending,
  awaiting,
  needsAttention,
  conflicted,
  completed,
  rejected,
  ended,
}

enum ProposalFilter { pending, handled, all }

/// Owner queue metadata. Field values remain in the pending review boundary.
class ProposalEntry {
  ProposalEntry._({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.chatLabel,
    required this.agentName,
    required this.purpose,
    required this.count,
    this.changeCount = 0,
    this.statusText,
    required this.version,
    required this.pending,
    required Iterable<String> itemIds,
  }) : itemIds = List.unmodifiable(itemIds);
  final String id, chatLabel, agentName, purpose;
  final String? statusText;
  final ProposalKind kind;
  final ProposalStatus status;
  final DateTime createdAt;
  final int count, version, changeCount;
  final bool pending;
  final List<String> itemIds;
  String get kindLabel => switch (kind) {
    ProposalKind.addition => '新增',
    ProposalKind.modification => '修改',
    ProposalKind.deletion => '删除',
    ProposalKind.organization => '整理结果',
  };
  String get stateLabel =>
      statusText ??
      switch (status) {
        ProposalStatus.pending => '待确认',
        ProposalStatus.awaiting => '已批准待入库',
        ProposalStatus.needsAttention => '需要处理',
        ProposalStatus.conflicted => '版本冲突',
        ProposalStatus.completed => switch (kind) {
          ProposalKind.addition => '已入库',
          ProposalKind.modification => '已采用',
          ProposalKind.deletion => '已移入回收站',
          ProposalKind.organization => '已完成',
        },
        ProposalStatus.rejected => '已拒绝',
        ProposalStatus.ended => '已结束',
      };
}

class ProposalPage {
  ProposalPage(
    Iterable<ProposalEntry> entries, {
    required this.total,
    required this.allCount,
    required this.pendingCount,
    required this.offset,
    required this.limit,
  }) : entries = List.unmodifiable(entries);
  final List<ProposalEntry> entries;
  final int total, allCount, pendingCount, offset, limit;
}

extension OwnerProposals on OwnerAccess {
  ProposalPage queryProposals({
    String search = '',
    ProposalFilter filter = ProposalFilter.pending,
    ProposalKind? kind,
    int offset = 0,
    int limit = 8,
    String? focusProposalId,
  }) {
    if (!serviceAvailable) throw const AccessFailure('service_unavailable');
    if (search.length > 2000 ||
        offset < 0 ||
        offset > 1000000 ||
        limit < 1 ||
        limit > 100) {
      throw const AccessFailure('invalid_query');
    }
    bool conflict(String id, int version) =>
        !information.any((item) => item.id == id && item.version == version);
    bool updateConflict(UpdateProposal proposal) {
      if (conflict(proposal.input.itemId, proposal.input.baseVersion)) {
        return true;
      }
      final current = information.firstWhere(
        (item) => item.id == proposal.input.itemId,
      );
      return proposal.input.changes.any(
        (change) =>
            change.kind != FieldChangeKind.add &&
            !current.fields.any((field) => field.id == change.fieldId),
      );
    }

    bool deleteConflict(DeleteProposal proposal) {
      if (conflict(proposal.itemId, proposal.baseVersion)) return true;
      return proposal.fieldId != null &&
          !information
              .firstWhere((item) => item.id == proposal.itemId)
              .fields
              .any((field) => field.id == proposal.fieldId);
    }

    final entries = <ProposalEntry>[
      for (final p in importProposals)
        ProposalEntry._(
          id: p.id,
          kind: ProposalKind.addition,
          status: switch (p.state) {
            ImportProposalState.pending =>
              importAdmission(p.id).any((s) => s.state == 'needs_attention')
                  ? ProposalStatus.needsAttention
                  : p.awaitingAdmission
                  ? ProposalStatus.awaiting
                  : ProposalStatus.pending,
            ImportProposalState.confirmed => ProposalStatus.completed,
            ImportProposalState.rejected => ProposalStatus.rejected,
          },
          createdAt: p.createdAt,
          chatLabel: p.chatLabel,
          agentName: p.agentName,
          purpose: p.purpose,
          count: p.state == ImportProposalState.pending
              ? p.items.length
              : p.createdItemIds.isEmpty
              ? p.itemCount
              : p.createdItemIds.length,
          version: p.version,
          pending: p.state == ImportProposalState.pending,
          itemIds: p.createdItemIds,
        ),
      for (final p in updateProposals)
        ProposalEntry._(
          id: p.id,
          kind: ProposalKind.modification,
          changeCount:
              p.input.changes.length +
              p.input.values.length +
              (p.input.name == null ? 0 : 1) +
              (p.input.description == null ? 0 : 1),
          status: switch (p.state) {
            UpdateProposalState.pending =>
              updateConflict(p)
                  ? ProposalStatus.conflicted
                  : updateAdmission(p.id).state == 'needs_attention'
                  ? ProposalStatus.needsAttention
                  : p.approved
                  ? ProposalStatus.awaiting
                  : ProposalStatus.pending,
            UpdateProposalState.confirmed => ProposalStatus.completed,
            UpdateProposalState.rejected => ProposalStatus.rejected,
            UpdateProposalState.conflicted => ProposalStatus.conflicted,
          },
          createdAt: p.createdAt,
          chatLabel: p.chatLabel,
          agentName: '',
          purpose: '',
          count: 1,
          version: p.version,
          pending: p.state == UpdateProposalState.pending,
          itemIds: [p.input.itemId],
        ),
      for (final p in deleteProposals)
        ProposalEntry._(
          id: p.id,
          kind: ProposalKind.deletion,
          status: switch (p.state) {
            DeleteProposalState.pending =>
              deleteConflict(p)
                  ? ProposalStatus.conflicted
                  : ProposalStatus.pending,
            DeleteProposalState.confirmed => ProposalStatus.completed,
            DeleteProposalState.rejected => ProposalStatus.rejected,
            DeleteProposalState.conflicted => ProposalStatus.conflicted,
          },
          createdAt: p.createdAt,
          chatLabel: p.chatLabel,
          agentName: '',
          purpose: '',
          count: 1,
          version: p.version,
          pending: p.state == DeleteProposalState.pending,
          itemIds: [p.itemId],
        ),
      for (final task in organizationTasks)
        if (organizationState(task) == OrganizationTaskState.proposed ||
            organizationState(task) == OrganizationTaskState.confirmed ||
            (task.approvedAt != null &&
                ![
                  OrganizationTaskState.pending,
                  OrganizationTaskState.active,
                ].contains(organizationState(task))))
          ProposalEntry._(
            id: task.id,
            kind: ProposalKind.organization,
            statusText: switch (organizationState(task)) {
              OrganizationTaskState.confirmed when task.changes.isEmpty =>
                '无改动完成',
              OrganizationTaskState.cancelled => '已撤销 · 未应用',
              OrganizationTaskState.expired => '已到期 · 未应用',
              OrganizationTaskState.conflicted => '版本冲突 · 整批未应用',
              _ => null,
            },
            status: switch (organizationState(task)) {
              OrganizationTaskState.proposed => ProposalStatus.pending,
              OrganizationTaskState.confirmed => ProposalStatus.completed,
              OrganizationTaskState.conflicted => ProposalStatus.conflicted,
              OrganizationTaskState.rejected => ProposalStatus.rejected,
              _ => ProposalStatus.ended,
            },
            createdAt: task.createdAt,
            chatLabel: task.chatLabel,
            agentName: task.agentName,
            purpose: task.purpose,
            count: task.itemVersions.length,
            version: 1,
            pending: organizationState(task) == OrganizationTaskState.proposed,
            itemIds: task.itemVersions.keys,
          ),
    ];
    final needle = search.trim().toLowerCase();
    final matching = entries
        .where(
          (entry) =>
              (kind == null || entry.kind == kind) &&
              (needle.isEmpty ||
                  [
                    entry.id,
                    entry.chatLabel,
                    entry.agentName,
                    entry.purpose,
                    entry.kindLabel,
                    entry.stateLabel,
                    for (final item in information.where(
                      (item) => entry.itemIds.contains(item.id),
                    ))
                      item.name,
                    if (entry.kind == ProposalKind.addition)
                      for (final p in importProposals.where(
                        (p) => p.id == entry.id,
                      ))
                        ...p.itemNames,
                  ].any((value) => value.toLowerCase().contains(needle))),
        )
        .toList();
    final filtered =
        matching
            .where(
              (entry) => switch (filter) {
                ProposalFilter.all => true,
                ProposalFilter.pending => entry.pending,
                ProposalFilter.handled => !entry.pending,
              },
            )
            .toList()
          ..sort((a, b) {
            final created = b.createdAt.compareTo(a.createdAt);
            return created == 0 ? a.id.compareTo(b.id) : created;
          });
    if (focusProposalId != null) {
      final index = filtered.indexWhere((entry) => entry.id == focusProposalId);
      if (index >= 0) offset = index ~/ limit * limit;
    }
    offset = min(
      offset,
      filtered.isEmpty ? 0 : (filtered.length - 1) ~/ limit * limit,
    );
    return ProposalPage(
      filtered.skip(offset).take(limit),
      total: filtered.length,
      allCount: matching.length,
      pendingCount: matching.where((entry) => entry.pending).length,
      offset: offset,
      limit: limit,
    );
  }
}
