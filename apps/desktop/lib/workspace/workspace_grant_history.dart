import 'workspace_approvals.dart';
import 'workspace_records.dart';
import 'workspace_history.dart';
import 'workspace_files.dart';

enum WorkspaceGrantFilter { all, active, ended }

enum WorkspaceGrantState {
  active('有效'),
  partial('部分有效'),
  denied('已拒绝'),
  revoked('已撤销'),
  expired('已到期'),
  sessionEnded('会话已结束'),
  completed('整理已结束'),
  unavailable('范围已失效');

  const WorkspaceGrantState(this.label);
  final String label;
  bool get isActive =>
      this == WorkspaceGrantState.active || this == WorkspaceGrantState.partial;
}

class WorkspaceGrantQuery {
  const WorkspaceGrantQuery({
    this.keyword = '',
    this.filter = WorkspaceGrantFilter.all,
    this.kind,
    this.lastDays,
    this.offset = 0,
    this.limit = 20,
  });
  final String keyword;
  final WorkspaceGrantFilter filter;
  final WorkspaceApprovalKind? kind;
  final int? lastDays;
  final int offset, limit;
}

/// Queue metadata only: never the values of granted fields or secret material.
class WorkspaceGrantSummary {
  const WorkspaceGrantSummary({
    required this.id,
    required this.title,
    required this.kind,
    required this.state,
    required this.agentClaim,
    required this.chatClaim,
    required this.purpose,
    required this.recordedAt,
    required this.operationCount,
    this.requestId,
  });
  final String id, title, agentClaim, chatClaim, purpose;
  final String? requestId;
  final WorkspaceApprovalKind kind;
  final WorkspaceGrantState state;
  final DateTime recordedAt;
  final int operationCount;
}

class WorkspaceGrantResults {
  WorkspaceGrantResults({
    required Iterable<WorkspaceGrantSummary> items,
    required this.total,
    required this.offset,
    this.selection,
    this.selectionIndex,
  }) : items = List.unmodifiable(items);
  final List<WorkspaceGrantSummary> items;
  final int total, offset;
  final String? selection;
  final int? selectionIndex;
}

class WorkspaceGrantedScope {
  const WorkspaceGrantedScope({
    required this.id,
    required this.record,
    required this.label,
    required this.recordVersion,
    required this.kind,
    required this.active,
    this.expiresAt,
    this.fileVersion,
    this.materialVersion,
  });
  final WorkspaceRecordRef record;
  final String id, label;
  final int recordVersion;
  final WorkspaceApprovalScopeKind kind;
  final bool active;
  final DateTime? expiresAt;
  final int? fileVersion, materialVersion;
}

class WorkspaceGrantTarget {
  const WorkspaceGrantTarget({
    required this.record,
    required this.name,
    required this.version,
    required this.exists,
    required this.snapshotAvailable,
  });
  final WorkspaceRecordRef record;
  final String name;
  final int version;
  final bool exists, snapshotAvailable;
}

class WorkspaceGrantEvent {
  const WorkspaceGrantEvent(
    this.id,
    this.at,
    this.description,
    this.result, {
    this.proposalId,
  });
  final String id, description, result;
  final String? proposalId;
  final DateTime at;
}

class WorkspaceGrantDetail {
  WorkspaceGrantDetail({
    required this.summary,
    required Iterable<WorkspaceGrantedScope> scopes,
    required Iterable<WorkspaceGrantTarget> targets,
    Iterable<WorkspaceGrantEvent> events = const [],
    this.reviewToken,
    this.decidedAt,
    this.fieldExpiresAt,
    this.credentialExpiresAt,
    this.legacyNotice,
  }) : scopes = List.unmodifiable(scopes),
       targets = List.unmodifiable(targets),
       events = List.unmodifiable(events);
  final WorkspaceGrantSummary summary;
  final List<WorkspaceGrantedScope> scopes;
  final List<WorkspaceGrantTarget> targets;
  final List<WorkspaceGrantEvent> events;
  final String? reviewToken, legacyNotice;
  final DateTime? decidedAt, fieldExpiresAt, credentialExpiresAt;
  bool get canRevoke => summary.requestId != null && summary.state.isActive;
}

abstract interface class WorkspaceGrantHistorySource {
  Future<WorkspaceGrantResults> query(
    WorkspaceGrantQuery query, {
    String? keepSelection,
  });
  Future<WorkspaceGrantDetail> read(String id);

  /// Explicit Owner-only content read, separate from content-free audit metadata.
  /// Exact version or unavailable; never substitute current or same-name content.
  Future<WorkspaceFilePreview> filePreview(
    String historyId,
    String scopeId, {
    int page = 0,
  });
  Future<WorkspaceArchive> snapshot(
    String historyId,
    WorkspaceRecordRef record,
  );
}
