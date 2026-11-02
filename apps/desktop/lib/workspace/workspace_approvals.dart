import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';
import 'workspace_files.dart';
import 'workspace_credentials.dart';
import 'workspace_approval_execution.dart';
export 'workspace_approval_execution.dart';

enum WorkspaceApprovalKind {
  information('字段读取'),
  file('文件与字段'),
  credential('凭据与字段'),
  focus('焦点填充'),
  organization('分类整理');

  const WorkspaceApprovalKind(this.label);
  final String label;
}

enum WorkspaceApprovalState {
  pending('待处理'),
  approved('已批准'),
  denied('已拒绝'),
  cancelled('已取消'),
  revoked('已撤销'),
  expired('已到期'),
  sessionEnded('会话已结束'),
  proposed('整理方案待确认'),
  conflicted('整理资料已变化'),
  completed('整理已结束'),
  unavailable('范围已失效');

  const WorkspaceApprovalState(this.label);
  final String label;
}

enum WorkspaceApprovalFilter { pending, all, done }

enum WorkspaceApprovalScopeKind { field, file, credential, organization }

class WorkspaceApprovalScope {
  WorkspaceApprovalScope({
    required this.id,
    required this.record,
    required this.label,
    required this.section,
    required this.recordName,
    required this.kind,
    required this.recordVersion,
    this.fieldKey,
    this.fieldId,
    this.entryId,
    this.requested = false,
    this.available = true,
    this.unavailableReason,
    Iterable<WorkspaceFileVersion> fileVersions = const [],
  }) : fileVersions = List.unmodifiable(fileVersions);
  final String id, label, section, recordName;
  final WorkspaceRecordRef record;
  final WorkspaceApprovalScopeKind kind;
  final int recordVersion;
  final String? fieldKey, fieldId, entryId, unavailableReason;
  final bool requested, available;
  final List<WorkspaceFileVersion> fileVersions;
  WorkspaceApprovalScope project({
    bool? requested,
    bool? available,
    String? reason,
    Iterable<WorkspaceFileVersion>? files,
  }) => WorkspaceApprovalScope(
    id: id,
    record: record,
    label: label,
    section: section,
    recordName: recordName,
    kind: kind,
    recordVersion: recordVersion,
    fieldKey: fieldKey,
    fieldId: fieldId,
    entryId: entryId,
    requested: requested ?? this.requested,
    available: available ?? this.available,
    unavailableReason: reason ?? unavailableReason,
    fileVersions: files ?? fileVersions,
  );
}

class WorkspaceApprovalSummary {
  const WorkspaceApprovalSummary({
    required this.id,
    required this.title,
    required this.kind,
    required this.agentClaim,
    required this.sessionId,
    required this.chatClaim,
    required this.purpose,
    required this.submittedAt,
    required this.requestExpiresAt,
    required this.state,
  });
  final String id, title, agentClaim, sessionId, chatClaim, purpose;
  final WorkspaceApprovalKind kind;
  final WorkspaceApprovalState state;
  final DateTime submittedAt, requestExpiresAt;
}

class WorkspaceApprovalQuery {
  const WorkspaceApprovalQuery({
    this.keyword = '',
    this.filter = WorkspaceApprovalFilter.pending,
    this.offset = 0,
    this.limit = 20,
  });
  final String keyword;
  final WorkspaceApprovalFilter filter;
  final int offset, limit;
}

class WorkspaceApprovalResults {
  WorkspaceApprovalResults({
    required Iterable<WorkspaceApprovalSummary> items,
    required this.total,
    required this.pending,
    required this.offset,
    this.selection,
    this.selectionIndex,
  }) : items = List.unmodifiable(items);
  final List<WorkspaceApprovalSummary> items;
  final int total, pending, offset;
  final String? selection;
  final int? selectionIndex;
}

/// Owner metadata only: no field values, file bytes, credential material or token.
class WorkspaceApprovalDetail {
  WorkspaceApprovalDetail({
    required this.request,
    required this.reviewToken,
    required Iterable<WorkspaceApprovalScope> scopes,
    Iterable<String> approved = const [],
    Map<String, int> fileVersions = const {},
    this.credential,
    this.decidedAt,
    this.fieldExpiresAt,
    this.credentialExpiresAt,
    this.approveUnavailableReason,
    this.fileVersionPolicy,
    this.decisionUnavailableReason,
    Iterable<WorkspaceApprovalExecution> executions = const [],
  }) : executions = List.unmodifiable(executions),
       scopes = List.unmodifiable(scopes),
       approved = Set.unmodifiable(approved),
       fileVersions = Map.unmodifiable(fileVersions);
  final List<WorkspaceApprovalExecution> executions;
  final WorkspaceApprovalSummary request;
  final String reviewToken;
  final List<WorkspaceApprovalScope> scopes;
  final Set<String> approved;
  final Map<String, int> fileVersions;
  final WorkspaceCredentialUseRequest? credential;
  final DateTime? decidedAt, fieldExpiresAt, credentialExpiresAt;
  final String? approveUnavailableReason, fileVersionPolicy;

  /// Applies to all owner decisions, including deny/revoke. A source may expose
  /// real read-only facts before its transactional decision adapter is ready.
  final String? decisionUnavailableReason;
  WorkspaceApprovalDetail withExecution(WorkspaceApprovalExecution next) =>
      WorkspaceApprovalDetail(
        request: request,
        reviewToken: reviewToken,
        scopes: scopes,
        approved: approved,
        fileVersions: fileVersions,
        credential: credential,
        decidedAt: decidedAt,
        fieldExpiresAt: fieldExpiresAt,
        credentialExpiresAt: credentialExpiresAt,
        approveUnavailableReason: approveUnavailableReason,
        fileVersionPolicy: fileVersionPolicy,
        decisionUnavailableReason: decisionUnavailableReason,
        executions: [
          for (final e in executions)
            e.operationId == next.operationId ? next : e,
        ],
      );
  bool get canApprove =>
      request.state == WorkspaceApprovalState.pending &&
      scopes.any((s) => s.available) &&
      decisionUnavailableReason == null &&
      approveUnavailableReason == null;
}

enum WorkspaceApprovalAction { approve, deny, revoke }

class WorkspaceApprovalChange {
  WorkspaceApprovalChange({
    required this.operationId,
    required this.requestId,
    required this.reviewToken,
    required this.action,
    Iterable<String> selected = const [],
    Map<String, int> fileVersions = const {},
    this.fieldMinutes = 30,
    this.credentialMinutes = 15,
  }) : selected = List.unmodifiable(selected),
       fileVersions = Map.unmodifiable(fileVersions);
  final String operationId, requestId, reviewToken;
  final WorkspaceApprovalAction action;
  final List<String> selected;
  final Map<String, int> fileVersions;
  final int fieldMinutes, credentialMinutes;
  String get digest => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            requestId,
            action.name,
            reviewToken,
            selected,
            {
              for (final k in (fileVersions.keys.toList()..sort()))
                k: fileVersions[k],
            },
            fieldMinutes,
            credentialMinutes,
          ]),
        ),
      )
      .toString();
}

class WorkspaceApprovalReceipt {
  const WorkspaceApprovalReceipt({
    required this.operationId,
    required this.requestId,
    required this.action,
    required this.reviewToken,
    required this.revision,
    required this.commandDigest,
  });
  final String operationId, requestId, reviewToken, commandDigest;
  final WorkspaceApprovalAction action;
  final int revision;
}

abstract interface class WorkspaceApprovalSource {
  Future<WorkspaceApprovalResults> query(
    WorkspaceApprovalQuery query, {
    String? keepSelection,
  });
  Future<WorkspaceApprovalDetail> read(String id);
  Future<WorkspaceApprovalReceipt> change(WorkspaceApprovalChange change);

  /// Read original operation metadata, even after its grant ends. Never execute,
  /// replay or infer that a missing/failed lookup means no execution occurred.
  Future<WorkspaceApprovalExecution> execution(
    String requestId,
    String operationId,
  );

  /// null confirms no commit; a failed lookup must throw.
  Future<WorkspaceApprovalReceipt?> receipt(String operationId);
}
