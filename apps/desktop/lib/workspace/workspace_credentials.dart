import 'workspace_records.dart';
import 'workspace_history.dart';

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
    this.useUnavailableReason,
    required this.form,
    required this.format,
    required this.delivery,
    required this.binding,
    required this.privateNote,
    this.filename,
    Iterable<WorkspaceRecordRef> linkedInformation = const [],
  }) : linkedInformation = List.unmodifiable(linkedInformation);
  final WorkspaceRecordSummary record;
  final int recordVersion, materialVersion, useGeneration;
  final bool enabled, useSupported;
  final String? useUnavailableReason;
  final WorkspaceCredentialForm form;
  final WorkspaceCredentialDelivery delivery;
  final String format, binding, privateNote;
  final String? filename;
  final List<WorkspaceRecordRef> linkedInformation;
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

class WorkspaceCredentialWrite {
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
    Iterable<String> tagIds = const [],
    Iterable<WorkspaceRecordRef>? linkedInformation,
  }) : tagIds = List.unmodifiable(tagIds),
       linkedInformation = linkedInformation == null
           ? null
           : List.unmodifiable(linkedInformation);
  final String operationId, name, purpose, privateNote, binding;
  final String? directoryId, candidateId;
  final WorkspaceRecordRef? ref;
  final int? expectedRecordVersion, expectedMaterialVersion;
  final List<String> tagIds;
  final List<WorkspaceRecordRef>? linkedInformation;
}

class WorkspaceCredentialToggle {
  const WorkspaceCredentialToggle({
    required this.operationId,
    required this.ref,
    required this.expectedRecordVersion,
    required this.expectedMaterialVersion,
    required this.enabled,
  });
  final String operationId;
  final WorkspaceRecordRef ref;
  final int expectedRecordVersion, expectedMaterialVersion;
  final bool enabled;
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
  });
  final String id, credentialName, purpose;
  final WorkspaceRecordRef ref;
  final int materialVersion, useGeneration, minutes;
  final WorkspaceCredentialDelivery delivery;
  final WorkspaceCredentialReceiver receiver;
  final WorkspaceCredentialSession session;
  final DateTime submittedAt;
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

class WorkspaceCredentialChange {
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
  final String operationId;
  final WorkspaceRecordRef ref;
  final int expectedRecordVersion, expectedMaterialVersion;
  final WorkspaceCredentialAction action;
  final int? materialVersion, expectedCatalogVersion;
  final String? entryId;
}

/// Contains only committed identities/versions, never credential contents.
class WorkspaceCredentialReceipt {
  WorkspaceCredentialReceipt(
    this.ref,
    this.recordVersion,
    this.materialVersion, {
    this.requestId,
    this.entryId,
    Iterable<String> notices = const [],
  }) : notices = List.unmodifiable(notices);
  final WorkspaceRecordRef ref;
  final int recordVersion, materialVersion;
  final String? requestId, entryId;
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
