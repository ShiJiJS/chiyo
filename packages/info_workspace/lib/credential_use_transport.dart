import 'workspace_credentials.dart';
import 'workspace_approval_execution.dart';
import 'workspace_records.dart';

// Explicit Owner metadata codecs. Never serialize Core requests/executions:
// those include private runtime identities and delivery capabilities.
void _shape(Map<String, dynamic> value, String keys) {
  final expected = keys.split(' ').toSet();
  if (value.length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw const FormatException('Invalid credential use metadata');
  }
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);
DateTime? _date(Object? value) =>
    value == null ? null : DateTime.parse(value as String);
Map<String, Object?> credentialReceiverToJson(
  WorkspaceCredentialReceiver value,
) => {
  'id': value.id,
  'label': value.label,
  'executable': value.executable,
  'workingDirectory': value.workingDirectory,
  'arguments': value.arguments,
  'binding': value.binding,
};
WorkspaceCredentialReceiver credentialReceiverFromJson(Object? raw) {
  final value = _map(raw);
  _shape(value, 'id label executable workingDirectory arguments binding');
  return WorkspaceCredentialReceiver(
    id: value['id'] as String,
    label: value['label'] as String,
    executable: value['executable'] as String,
    workingDirectory: value['workingDirectory'] as String,
    arguments: (value['arguments'] as List).cast<String>(),
    binding: value['binding'] as String,
  );
}

Map<String, Object?> credentialUseRequestToJson(
  WorkspaceCredentialUseRequest value,
) => {
  'id': value.id,
  'credentialId': value.ref.id,
  'credentialName': value.credentialName,
  'materialVersion': value.materialVersion,
  'useGeneration': value.useGeneration,
  'delivery': value.delivery.name,
  'receiver': credentialReceiverToJson(value.receiver),
  'session': {
    'id': value.session.id,
    'label': value.session.label,
    'agentClaim': value.session.agentClaim,
  },
  'purpose': value.purpose,
  'minutes': value.minutes,
  'submittedAt': value.submittedAt.toUtc().toIso8601String(),
  'state': value.state.name,
  'approvalReference': value.approvalReference,
  'requestExpiresAt': value.requestExpiresAt?.toUtc().toIso8601String(),
  'supportsSessionValidity': value.supportsSessionValidity,
};
WorkspaceCredentialUseRequest credentialUseRequestFromJson(Object? raw) {
  final value = _map(raw);
  _shape(
    value,
    'id credentialId credentialName materialVersion useGeneration delivery receiver session purpose minutes submittedAt state approvalReference requestExpiresAt supportsSessionValidity',
  );
  final session = _map(value['session']);
  _shape(session, 'id label agentClaim');
  final result = WorkspaceCredentialUseRequest(
    id: value['id'] as String,
    ref: WorkspaceRecordRef(
      WorkspaceRecordKind.credential,
      value['credentialId'] as String,
    ),
    credentialName: value['credentialName'] as String,
    materialVersion: value['materialVersion'] as int,
    useGeneration: value['useGeneration'] as int,
    delivery: WorkspaceCredentialDelivery.values.byName(
      value['delivery'] as String,
    ),
    receiver: credentialReceiverFromJson(value['receiver']),
    session: WorkspaceCredentialSession(
      session['id'] as String,
      session['label'] as String,
      session['agentClaim'] as String,
    ),
    purpose: value['purpose'] as String,
    minutes: value['minutes'] as int?,
    submittedAt: DateTime.parse(value['submittedAt'] as String),
    state: WorkspaceCredentialRequestState.values.byName(
      value['state'] as String,
    ),
    approvalReference: value['approvalReference'] as String?,
    requestExpiresAt: _date(value['requestExpiresAt']),
    supportsSessionValidity: value['supportsSessionValidity'] as bool,
  );
  if (result.materialVersion < 1 ||
      result.useGeneration < 1 ||
      (result.minutes == null
          ? !result.supportsSessionValidity
          : result.minutes! < 1)) {
    throw const FormatException('Invalid credential use metadata');
  }
  return result;
}

Map<String, Object?> approvalExecutionToJson(
  WorkspaceApprovalExecution value,
) => {
  'requestId': value.requestId,
  'grantId': value.grantId,
  'operationId': value.operationId,
  'credential': credentialUseRequestToJson(value.credential),
  'plan': credentialReceiverToJson(value.plan),
  'createdAt': value.createdAt.toUtc().toIso8601String(),
  'observedAt': value.observedAt?.toUtc().toIso8601String(),
  'state': value.state.name,
  'cleanup': value.cleanup.name,
  'revision': value.revision,
  'processEnded': value.processEnded,
  'processStarted': value.processStarted,
  'exitCode': value.exitCode,
  'errorCode': value.errorCode,
  'fromBackup': value.fromBackup,
};
WorkspaceApprovalExecution approvalExecutionFromJson(Object? raw) {
  final value = _map(raw);
  _shape(
    value,
    'requestId grantId operationId credential plan createdAt observedAt state cleanup revision processEnded processStarted exitCode errorCode fromBackup',
  );
  final result = WorkspaceApprovalExecution(
    requestId: value['requestId'] as String,
    grantId: value['grantId'] as String,
    operationId: value['operationId'] as String,
    credential: credentialUseRequestFromJson(value['credential']),
    plan: credentialReceiverFromJson(value['plan']),
    createdAt: DateTime.parse(value['createdAt'] as String),
    observedAt: _date(value['observedAt']),
    state: WorkspaceExecutionState.values.byName(value['state'] as String),
    cleanup: WorkspaceExecutionCleanup.values.byName(
      value['cleanup'] as String,
    ),
    revision: value['revision'] as int,
    processEnded: value['processEnded'] as bool,
    processStarted: value['processStarted'] as bool,
    exitCode: value['exitCode'] as int?,
    errorCode: value['errorCode'] as String?,
    fromBackup: value['fromBackup'] as bool,
  );
  if (!result.valid || result.credential.id != result.requestId) {
    throw const FormatException('Invalid execution metadata');
  }
  return result;
}
