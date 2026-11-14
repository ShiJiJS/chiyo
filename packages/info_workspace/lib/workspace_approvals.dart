import 'package:info_core/access_timing.dart';
import 'package:info_core/info_core.dart' as core;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'workspace_records.dart';
import 'workspace_files.dart';
import 'workspace_credentials.dart';
import 'workspace_approval_execution.dart';
import 'workspace_credential_batches.dart';
import 'workspace_credential_programs.dart';
import 'workspace_credential_operation_pages.dart';
export 'workspace_credential_operation_pages.dart';
export 'workspace_credential_batches.dart';
export 'workspace_credential_programs.dart';
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
    this.credentialBatch = false,
    this.sshSession = false,
    this.sshTarget,
    this.batchSupportsSessionValidity = false,
    this.batchSessionBound = false,
    this.programPlan,
    this.operationTotal,
    this.operationsCursor,
    this.decidedAt,
    this.fieldExpiresAt,
    this.credentialExpiresAt,
    this.approveUnavailableReason,
    this.fileVersionPolicy,
    this.decisionUnavailableReason,
    Iterable<WorkspaceApprovalExecution> executions = const [],
    Iterable<WorkspaceCredentialBatchOperation> batchOperations = const [],
    Iterable<WorkspaceCredentialProgramOperation> programOperations = const [],
  }) : executions = List.unmodifiable(executions),
       batchOperations = List.unmodifiable(batchOperations),
       programOperations = List.unmodifiable(programOperations),
       scopes = List.unmodifiable(scopes),
       approved = Set.unmodifiable(approved),
       fileVersions = Map.unmodifiable(fileVersions);
  final List<WorkspaceApprovalExecution> executions;
  final List<WorkspaceCredentialBatchOperation> batchOperations;
  final List<WorkspaceCredentialProgramOperation> programOperations;
  final WorkspaceCredentialProgramPlan? programPlan;
  final int? operationTotal;
  final String? operationsCursor;
  int get operationsTotal =>
      operationTotal ?? batchOperations.length + programOperations.length;
  final WorkspaceApprovalSummary request;
  final String reviewToken;
  final List<WorkspaceApprovalScope> scopes;
  final Set<String> approved;
  final Map<String, int> fileVersions;
  final WorkspaceCredentialUseRequest? credential;
  final bool credentialBatch;
  final bool sshSession, batchSupportsSessionValidity, batchSessionBound;
  final core.SshSessionTarget? sshTarget;
  bool get supportsSessionValidity =>
      batchSupportsSessionValidity ||
      credential?.supportsSessionValidity == true;
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
        credentialBatch: credentialBatch,
        sshSession: sshSession,
        sshTarget: sshTarget,
        batchSupportsSessionValidity: batchSupportsSessionValidity,
        batchSessionBound: batchSessionBound,
        programPlan: programPlan,
        operationTotal: operationTotal,
        operationsCursor: operationsCursor,
        programOperations: programOperations,
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
        batchOperations: batchOperations,
      );
  WorkspaceApprovalDetail withBatchOperation(
    WorkspaceCredentialBatchOperation next,
  ) => WorkspaceApprovalDetail(
    request: request,
    reviewToken: reviewToken,
    scopes: scopes,
    approved: approved,
    fileVersions: fileVersions,
    credential: credential,
    credentialBatch: credentialBatch,
    sshSession: sshSession,
    sshTarget: sshTarget,
    batchSupportsSessionValidity: batchSupportsSessionValidity,
    batchSessionBound: batchSessionBound,
    programPlan: programPlan,
    operationTotal: operationTotal,
    operationsCursor: operationsCursor,
    programOperations: programOperations,
    decidedAt: decidedAt,
    fieldExpiresAt: fieldExpiresAt,
    credentialExpiresAt: credentialExpiresAt,
    approveUnavailableReason: approveUnavailableReason,
    fileVersionPolicy: fileVersionPolicy,
    decisionUnavailableReason: decisionUnavailableReason,
    executions: executions,
    batchOperations: [
      for (final o in batchOperations)
        o.operationId == next.operationId ? next : o,
    ],
  );
  WorkspaceApprovalDetail withProgramOperation(
    WorkspaceCredentialProgramOperation next,
  ) => WorkspaceApprovalDetail(
    request: request,
    reviewToken: reviewToken,
    scopes: scopes,
    approved: approved,
    fileVersions: fileVersions,
    credential: credential,
    credentialBatch: credentialBatch,
    sshSession: sshSession,
    sshTarget: sshTarget,
    batchSupportsSessionValidity: batchSupportsSessionValidity,
    batchSessionBound: batchSessionBound,
    programPlan: programPlan,
    operationTotal: operationTotal,
    operationsCursor: operationsCursor,
    decidedAt: decidedAt,
    fieldExpiresAt: fieldExpiresAt,
    credentialExpiresAt: credentialExpiresAt,
    approveUnavailableReason: approveUnavailableReason,
    fileVersionPolicy: fileVersionPolicy,
    decisionUnavailableReason: decisionUnavailableReason,
    executions: executions,
    batchOperations: batchOperations,
    programOperations: [
      for (final operation in programOperations)
        operation.operationId == next.operationId ? next : operation,
    ],
  );
  WorkspaceApprovalDetail withOperationPage(
    WorkspaceCredentialOperationPage input,
  ) {
    final page = WorkspaceCredentialOperationPage.fromJson(
      Map<String, dynamic>.from(input.toJson()),
    );
    final ids = {
      ...batchOperations.map((o) => o.operationId),
      ...programOperations.map((o) => o.operationId),
    };
    if (!credentialBatch ||
        page.cursor != operationsCursor ||
        operationsCursor == null ||
        !page.validFor(
          request.id,
          programPlan,
          scopes.map((s) => s.id).toSet(),
        ) ||
        page.keys.any((key) => ids.contains(key.$2)) ||
        page.total < ids.length + page.length) {
      throw const WorkspaceFailure('invalid_response', '记录分页已变化，请重新读取申请后再继续。');
    }
    return WorkspaceApprovalDetail(
      request: request,
      reviewToken: reviewToken,
      scopes: scopes,
      approved: approved,
      fileVersions: fileVersions,
      credential: credential,
      credentialBatch: credentialBatch,
      sshSession: sshSession,
      sshTarget: sshTarget,
      batchSupportsSessionValidity: batchSupportsSessionValidity,
      batchSessionBound: batchSessionBound,
      programPlan: programPlan,
      decidedAt: decidedAt,
      fieldExpiresAt: fieldExpiresAt,
      credentialExpiresAt: credentialExpiresAt,
      approveUnavailableReason: approveUnavailableReason,
      fileVersionPolicy: fileVersionPolicy,
      decisionUnavailableReason: decisionUnavailableReason,
      executions: executions,
      batchOperations: [...batchOperations, ...page.batches],
      programOperations: [...programOperations, ...page.programs],
      operationTotal: page.total,
      operationsCursor: page.nextCursor,
    );
  }

  bool get credentialSessionBound =>
      batchSessionBound || credential?.sessionBound == true;
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
    this.fieldMinutes = AccessTiming.defaultMinutes,
    this.credentialMinutes = AccessTiming.defaultMinutes,
  }) : selected = List.unmodifiable(selected),
       fileVersions = Map.unmodifiable(fileVersions);
  final String operationId, requestId, reviewToken;
  final WorkspaceApprovalAction action;
  final List<String> selected;
  final Map<String, int> fileVersions;
  final int fieldMinutes;
  final int? credentialMinutes;
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

  bool matches(WorkspaceApprovalChange change) =>
      operationId == change.operationId &&
      requestId == change.requestId &&
      action == change.action &&
      reviewToken == change.reviewToken &&
      commandDigest == change.digest &&
      revision >= 1;
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
