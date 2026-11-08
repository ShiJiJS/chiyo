import 'workspace_records.dart';

enum WorkspaceOrganizationOutcome {
  proposed('等待主人确认'),
  applied('已应用'),
  conflicted('整批未应用：版本冲突'),
  failed('整批未应用：保存失败'),
  unknown('结果未知'),
  revoked('未应用：授权已撤销'),
  expired('未应用：授权已到期'),
  sessionEnded('未应用：会话已结束'),
  rejected('主人已拒绝');

  const WorkspaceOrganizationOutcome(this.label);
  final String label;
}

/// Classification metadata only. It cannot carry values, files or credentials.
class WorkspaceOrganizationLocation {
  WorkspaceOrganizationLocation({
    this.directoryId,
    required this.directoryName,
    required Iterable<WorkspaceTag> tags,
  }) : tags = List.unmodifiable(tags);
  final String? directoryId;
  final String directoryName;
  final List<WorkspaceTag> tags;
  Map<String, Object?> toJson() => {
    'directoryId': directoryId,
    'directoryName': directoryName,
    'tags': [
      for (final t in tags) {'id': t.id, 'name': t.name},
    ],
  };
}

class WorkspaceOrganizationMember {
  const WorkspaceOrganizationMember({
    required this.record,
    required this.name,
    required this.baseVersion,
    required this.before,
    required this.after,
    this.resultVersion,
    this.exists = true,
  });
  final WorkspaceRecordRef record;
  final String name;
  final int baseVersion;
  final int? resultVersion;
  final WorkspaceOrganizationLocation before, after;
  final bool exists;
  bool get changed =>
      before.directoryId != after.directoryId ||
      before.tags.length != after.tags.length ||
      !before.tags
          .map((t) => t.id)
          .toSet()
          .containsAll(after.tags.map((t) => t.id));
  Map<String, Object?> toJson() => {
    'record': record.key,
    'name': name,
    'baseVersion': baseVersion,
    'resultVersion': resultVersion,
    'before': before.toJson(),
    'after': after.toJson(),
  };
  WorkspaceOrganizationMember project({
    int? version,
    bool? exists,
    bool clearResult = false,
  }) => WorkspaceOrganizationMember(
    record: record,
    name: name,
    baseVersion: baseVersion,
    before: before,
    after: after,
    resultVersion: clearResult ? null : version ?? resultVersion,
    exists: exists ?? this.exists,
  );
}

class WorkspaceOrganizationReport {
  WorkspaceOrganizationReport({
    required this.outcome,
    required Iterable<WorkspaceOrganizationMember> members,
    required this.at,
    this.legacyReview = false,
    this.requestId,
    this.historyId,
    this.operationId,
    this.approvedAt,
    this.expiresAt,
    this.reason,
  }) : members = List.unmodifiable(members);
  final WorkspaceOrganizationOutcome outcome;
  final List<WorkspaceOrganizationMember> members;
  final DateTime at;
  final bool legacyReview;
  final String? requestId, historyId, operationId, reason;
  final DateTime? approvedAt, expiresAt;
  Map<String, Object?> toJson() => {
    'outcome': outcome.name,
    'legacyReview': legacyReview,
    'requestId': requestId,
    'historyId': historyId,
    'operationId': operationId,
    'at': at.toIso8601String(),
    'approvedAt': approvedAt?.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'reason': reason,
    'members': members.map((m) => m.toJson()).toList(),
  };
  WorkspaceOrganizationReport project({
    WorkspaceOrganizationOutcome? outcome,
    Iterable<WorkspaceOrganizationMember>? members,
    String? operationId,
  }) => WorkspaceOrganizationReport(
    outcome: outcome ?? this.outcome,
    members: members ?? this.members,
    at: at,
    legacyReview: legacyReview,
    requestId: requestId,
    historyId: historyId,
    operationId: operationId ?? this.operationId,
    approvedAt: approvedAt,
    expiresAt: expiresAt,
    reason: reason,
  );
}
