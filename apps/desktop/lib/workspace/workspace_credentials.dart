import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'workspace_records.dart';
import 'workspace_history.dart';

abstract interface class WorkspaceCredentialCommand {
  String get operationId;
  String get commandDigest;
}

String _credentialDigest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

enum WorkspaceCredentialForm { string, file }

enum WorkspaceCredentialDelivery {
  environment('子进程环境变量'),
  file('临时凭据文件'),
  focus('本机焦点填充'),
  storage('仅保管');

  const WorkspaceCredentialDelivery(this.label);
  final String label;
}

/// Picker metadata only. The identifier never denotes a filesystem path.
class WorkspaceCredentialCandidate {
  const WorkspaceCredentialCandidate({
    required this.id,
    required this.label,
    required this.form,
    required this.format,
    required this.delivery,
    this.filename,
    this.binding = '',
  });
  final String id, label, format, binding;
  final String? filename;
  final WorkspaceCredentialForm form;
  final WorkspaceCredentialDelivery delivery;
}

/// Host-owned secure entry / file selection. Plaintext stays outside generic
/// workspace records; the service resolves this staged identity on save.
typedef WorkspaceCredentialPicker =
    Future<WorkspaceCredentialCandidate?> Function(
      WorkspaceCredentialForm? requiredForm,
    );

class WorkspaceCredentialDetail {
  WorkspaceCredentialDetail({
    required this.record,
    required this.recordVersion,
    required this.materialVersion,
    required this.useGeneration,
    required this.enabled,
    required this.useSupported,
    this.discoverable = false,
    this.useUnavailableReason,
    required this.form,
    required this.format,
    required this.delivery,
    required this.binding,
    required this.privateNote,
    this.filename,
    Iterable<WorkspaceRecordRef> linkedInformation = const [],
    Iterable<WorkspaceRecordRef> linkedCredentials = const [],
  }) : linkedInformation = List.unmodifiable(linkedInformation),
       linkedCredentials = List.unmodifiable(linkedCredentials);
  final WorkspaceRecordSummary record;
  final int recordVersion, materialVersion, useGeneration;
  final bool enabled, useSupported, discoverable;
  final String? useUnavailableReason;
  final WorkspaceCredentialForm form;
  final WorkspaceCredentialDelivery delivery;
  final String format, binding, privateNote;
  final String? filename;
  final List<WorkspaceRecordRef> linkedInformation;
  final List<WorkspaceRecordRef> linkedCredentials;
  List<WorkspaceRecordRef> get allLinks => [
    ...linkedInformation,
    ...linkedCredentials,
  ];
  String get mask => '••••••••';
  bool get canRequestUse =>
      enabled &&
      useSupported &&
      delivery != WorkspaceCredentialDelivery.storage;
  String? get unavailableReason => !enabled
      ? '凭据已停用，不能发起新的使用申请。'
      : delivery == WorkspaceCredentialDelivery.storage
      ? '此类文件当前仅保管，尚不支持运行时使用。'
      : !useSupported
      ? useUnavailableReason ?? '当前尚不支持此使用方式。'
      : null;
}

class WorkspaceCredentialWrite implements WorkspaceCredentialCommand {
  WorkspaceCredentialWrite({
    required this.operationId,
    required this.name,
    this.purpose = '',
    this.privateNote = '',
    this.binding = '',
    this.directoryId,
    this.ref,
    this.expectedRecordVersion,
    this.expectedMaterialVersion,
    this.candidateId,
    this.discoverable,
    Iterable<String> tagIds = const [],
    Iterable<WorkspaceRecordRef>? linkedInformation,
  }) : tagIds = List.unmodifiable(tagIds),
       linkedInformation = linkedInformation == null
           ? null
           : List.unmodifiable(linkedInformation);
  @override
  final String operationId;
  final String name, purpose, privateNote, binding;
  final String? directoryId, candidateId;
  final bool? discoverable;
  final WorkspaceRecordRef? ref;
  final int? expectedRecordVersion, expectedMaterialVersion;
  final List<String> tagIds;
  final List<WorkspaceRecordRef>? linkedInformation;
  @override
  String get commandDigest => _credentialDigest({
    'kind': 'credential-save',
    'operationId': operationId,
    'ref': ref?.key,
    'record': expectedRecordVersion,
    'material': expectedMaterialVersion,
    'name': name,
    'purpose': purpose,
    'note': privateNote,
    'binding': binding,
    'candidate': candidateId,
    'discoverable': discoverable,
    'directory': directoryId,
    'tags': List.of(tagIds)..sort(),
    'links': linkedInformation == null
        ? null
        : (linkedInformation!.map((r) => r.key).toList()..sort()),
  });
}

class WorkspaceCredentialToggle implements WorkspaceCredentialCommand {
  const WorkspaceCredentialToggle({
    required this.operationId,
    required this.ref,
    required this.expectedRecordVersion,
    required this.expectedMaterialVersion,
    required this.enabled,
  });
  @override
  final String operationId;
  final WorkspaceRecordRef ref;
  final int expectedRecordVersion, expectedMaterialVersion;
  final bool enabled;
  @override
  String get commandDigest => _credentialDigest({
    'kind': 'credential-toggle',
    'operationId': operationId,
    'ref': ref.key,
    'record': expectedRecordVersion,
    'material': expectedMaterialVersion,
    'enabled': enabled,
  });
}

class WorkspaceCredentialReceiver {
  WorkspaceCredentialReceiver({
    required this.id,
    required this.label,
    required this.executable,
    required this.workingDirectory,
    required Iterable<String> arguments,
    required this.binding,
  }) : arguments = List.unmodifiable(arguments);
  final String id, label, executable, workingDirectory, binding;
  final List<String> arguments;
}

class WorkspaceCredentialSession {
  const WorkspaceCredentialSession(this.id, this.label, this.agentClaim);
  final String id, label, agentClaim;
}

class WorkspaceCredentialUseDraft {
  const WorkspaceCredentialUseDraft({
    required this.operationId,
    required this.ref,
    required this.expectedRecordVersion,
    required this.expectedMaterialVersion,
    required this.useGeneration,
    required this.purpose,
    required this.receiverId,
    required this.sessionId,
    this.minutes = 15,
  });
  final String operationId, purpose, receiverId, sessionId;
  final WorkspaceRecordRef ref;
  final int expectedRecordVersion,
      expectedMaterialVersion,
      useGeneration,
      minutes;
}

enum WorkspaceCredentialRequestState {
  pending('待审批'),
  approved('已批准'),
  partiallyApproved('仅批准普通字段'),
  denied('已拒绝'),
  revoked('已撤销'),
  expired('已到期'),
  sessionEnded('会话已结束'),
  unavailable('许可未启用'),
  superseded('凭据已更换'),
  disabled('凭据已停用'),
  recycled('凭据已回收');

  const WorkspaceCredentialRequestState(this.label);
  final String label;
}

class WorkspaceCredentialUseRequest {
  const WorkspaceCredentialUseRequest({
    required this.id,
    required this.ref,
    required this.credentialName,
    required this.materialVersion,
    required this.useGeneration,
    required this.delivery,
    required this.receiver,
    required this.session,
    required this.purpose,
    required this.minutes,
    required this.submittedAt,
    this.state = WorkspaceCredentialRequestState.pending,
    this.approvalReference,
    this.requestExpiresAt,
  });
  final String id, credentialName, purpose;
  final String? approvalReference;
  String get approvalId => approvalReference ?? 'credential:$id';
  final WorkspaceRecordRef ref;
  final int materialVersion, useGeneration, minutes;
  final WorkspaceCredentialDelivery delivery;
  final WorkspaceCredentialReceiver receiver;
  final WorkspaceCredentialSession session;
  final DateTime submittedAt;
  final DateTime? requestExpiresAt;
  final WorkspaceCredentialRequestState state;
  WorkspaceCredentialUseRequest withState(
    WorkspaceCredentialRequestState value,
  ) => WorkspaceCredentialUseRequest(
    id: id,
    ref: ref,
    credentialName: credentialName,
    materialVersion: materialVersion,
    useGeneration: useGeneration,
    delivery: delivery,
    receiver: receiver,
    session: session,
    purpose: purpose,
    minutes: minutes,
    submittedAt: submittedAt,
    state: value,
    approvalReference: approvalReference,
    requestExpiresAt: requestExpiresAt,
  );
}

class WorkspaceCredentialUseOperation {
  const WorkspaceCredentialUseOperation(
    this.id,
    this.at,
    this.description,
    this.result,
  );
  final String id, description, result;
  final DateTime at;
}

class WorkspaceCredentialUseHistory {
  WorkspaceCredentialUseHistory({
    required this.grantId,
    required this.credentialName,
    required this.materialVersion,
    required this.delivery,
    required this.session,
    required this.purpose,
    required this.expiresAt,
    required this.state,
    required Iterable<WorkspaceCredentialUseOperation> operations,
  }) : operations = List.unmodifiable(operations);
  final String grantId, credentialName, purpose, state;
  final int materialVersion;
  final WorkspaceCredentialDelivery delivery;
  final WorkspaceCredentialSession session;
  final DateTime expiresAt;
  final List<WorkspaceCredentialUseOperation> operations;
}

/// Metadata for one retained immutable material version, never raw material.
class WorkspaceCredentialMaterial {
  const WorkspaceCredentialMaterial({
    required this.version,
    required this.form,
    required this.format,
    required this.createdAt,
    this.filename,
    this.retiredAt,
  });
  final int version;
  final WorkspaceCredentialForm form;
  final String format;
  final String? filename;
  final DateTime createdAt;
  final DateTime? retiredAt;
  String get mask => '••••••••';
}

class WorkspaceCredentialMaterialHistory {
  WorkspaceCredentialMaterialHistory(
    this.current,
    Iterable<WorkspaceCredentialMaterial> materials,
  ) : materials = List.unmodifiable(materials);
  final WorkspaceCredentialDetail current;
  final List<WorkspaceCredentialMaterial> materials;
}

class WorkspaceCredentialRecycled {
  WorkspaceCredentialRecycled(
    this.entry,
    this.detail, {
    required this.restored,
    required this.catalogVersion,
    Iterable<String> notices = const [],
  }) : notices = List.unmodifiable(notices);
  final WorkspaceRecycleEntry entry;
  final WorkspaceCredentialDetail detail, restored;
  final int catalogVersion;
  final List<String> notices;
}

enum WorkspaceCredentialAction {
  recycle,
  restoreMaterial,
  restoreRecycled,
  purge,
}

class WorkspaceCredentialChange implements WorkspaceCredentialCommand {
  const WorkspaceCredentialChange({
    required this.operationId,
    required this.ref,
    required this.expectedRecordVersion,
    required this.expectedMaterialVersion,
    required this.action,
    this.materialVersion,
    this.entryId,
    this.expectedCatalogVersion,
  });
  @override
  final String operationId;
  final WorkspaceRecordRef ref;
  final int expectedRecordVersion, expectedMaterialVersion;
  final WorkspaceCredentialAction action;
  final int? materialVersion, expectedCatalogVersion;
  final String? entryId;
  @override
  String get commandDigest => _credentialDigest({
    'kind': 'credential-lifecycle',
    'operationId': operationId,
    'ref': ref.key,
    'record': expectedRecordVersion,
    'material': expectedMaterialVersion,
    'action': action.name,
    'selected': materialVersion,
    'entry': entryId,
    'catalog': expectedCatalogVersion,
  });
}

/// Contains only committed identities/versions, never credential contents.
class WorkspaceCredentialReceipt {
  WorkspaceCredentialReceipt(
    this.ref,
    this.recordVersion,
    this.materialVersion, {
    this.requestId,
    this.entryId,
    this.commandDigest,
    Iterable<String> notices = const [],
  }) : notices = List.unmodifiable(notices);
  final WorkspaceRecordRef ref;
  final int recordVersion, materialVersion;
  final String? requestId, entryId, commandDigest;
  final List<String> notices;
}

abstract interface class WorkspaceCredentialSource {
  Future<WorkspaceCredentialDetail> read(WorkspaceRecordRef ref);
  Future<WorkspaceCredentialMaterialHistory> materials(WorkspaceRecordRef ref);
  Future<WorkspaceCredentialRecycled> readRecycled(String entryId);
  Future<WorkspaceCredentialReceipt> change(WorkspaceCredentialChange change);
  Future<List<WorkspaceCredentialCandidate>> candidates();

  /// Releases a form's staging lease. Committed/uncertain operations retain
  /// their own service references; this never cancels or replays a write.
  Future<void> releaseCandidate(String candidateId);
  Future<WorkspaceCredentialReceipt> save(WorkspaceCredentialWrite write);
  Future<WorkspaceCredentialReceipt> setEnabled(
    WorkspaceCredentialToggle change,
  );
  Future<WorkspaceCredentialReceipt?> receipt(String operationId);
  Future<List<WorkspaceCredentialSession>> sessions();
  Future<List<WorkspaceCredentialReceiver>> receivers(WorkspaceRecordRef ref);
  Future<WorkspaceCredentialReceipt> requestUse(
    WorkspaceCredentialUseDraft draft,
  );
  Future<List<WorkspaceCredentialUseRequest>> requests({
    WorkspaceRecordRef? ref,
  });
  Future<List<WorkspaceCredentialUseHistory>> history(WorkspaceRecordRef ref);
}
