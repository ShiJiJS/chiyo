import 'info_core.dart';

/// Private execution-device transport. The authenticated gateway selects the
/// device; bodies cannot choose another device or supply an approval identity.
final class CredentialProgramProtocol {
  CredentialProgramProtocol(this.agent, this.deviceId);
  final AgentAccess agent;
  final String deviceId;
  static const base = '/credential-use/program';
  static const sessionPaths = {
    '$base/request',
    '$base/status',
    '$base/begin',
    '$base/operation',
  };
  static const proofPaths = {
    '$base/authorize',
    '$base/materials/register',
    '$base/worker/register',
    '$base/report',
    '$base/cleanup',
  };
  static bool handles(String path) =>
      sessionPaths.contains(path) || proofPaths.contains(path);
  void _shape(
    Map<String, dynamic> value,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    if (!value.keys.toSet().containsAll(required) ||
        value.keys.any((k) => !required.contains(k) && !optional.contains(k))) {
      throw const CredentialUseFailure('unknown_field');
    }
  }

  String _text(Map<String, dynamic> value, String key) {
    final text = value[key];
    if (text is! String ||
        text.isEmpty ||
        text.length > 2000 ||
        text.contains('\x00')) {
      throw const CredentialUseFailure('invalid_type');
    }
    return text;
  }

  Map<String, dynamic> _map(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const CredentialUseFailure('invalid_type');
    }
    return value;
  }

  Future<Map<String, Object?>> dispatch(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!agent.credentialProgramsAvailable) {
      throw const CredentialUseFailure('unsupported_capability');
    }
    switch (path) {
      case '$base/request':
        _shape(body, {'sessionSecret', 'operationId', 'input', 'prepared'});
        final input = _map(body['input']);
        _shape(
          input,
          {'purpose', 'launch'},
          {'agentName', 'externalChatId', 'submissionVersion'},
        );
        if (input.containsKey('submissionVersion') &&
            input['submissionVersion'] != 1) {
          throw const CredentialUseFailure('invalid_submission_metadata');
        }
        final launch = CredentialProgramPlan.fromJson(
          _map(input['launch']),
          allowPortablePaths: true,
        );
        final prepared = DeviceCredentialLaunch.fromPrivateJson(
          _map(body['prepared']),
        );
        final session = _text(body, 'sessionSecret');
        final request = await agent.requestCredentialBatch(
          session,
          deviceId,
          CredentialBatchInput.forProgram(
            prepared.resolveProgram(launch),
            purpose: _text(input, 'purpose'),
            agentName: input.containsKey('agentName')
                ? _text(input, 'agentName')
                : '',
            externalChatId: input.containsKey('externalChatId')
                ? _text(input, 'externalChatId')
                : '',
          ),
          operationId: _text(body, 'operationId'),
        );
        return agent.credentialBatchStatus(session, deviceId, request.id);
      case '$base/status':
        _shape(body, {'sessionSecret', 'requestId'});
        final result = agent.credentialBatchStatus(
          _text(body, 'sessionSecret'),
          deviceId,
          _text(body, 'requestId'),
        );
        if (!result.containsKey('programPlan')) {
          throw const CredentialUseFailure('unsupported_receiver');
        }
        return result;
      case '$base/begin':
        _shape(body, {
          'sessionSecret',
          'requestId',
          'operationId',
          'launch',
          'prepared',
          'jobName',
        });
        final session = _text(body, 'sessionSecret'),
            operation = _text(body, 'operationId');
        final claim = await agent.beginCredentialProgramOperation(
          session,
          deviceId,
          _text(body, 'requestId'),
          CredentialProgramPlan.fromJson(
            _map(body['launch']),
            allowPortablePaths: true,
          ),
          DeviceCredentialLaunch.fromPrivateJson(_map(body['prepared'])),
          _text(body, 'jobName'),
          operationId: operation,
        );
        return {
          ...claim.toPrivateJson(),
          ...agent.credentialProgramOperationStatus(
            session,
            deviceId,
            operation,
          ),
        };
      case '$base/operation':
        _shape(body, {'sessionSecret', 'operationId'});
        return agent.credentialProgramOperationStatus(
          _text(body, 'sessionSecret'),
          deviceId,
          _text(body, 'operationId'),
        );
      case '$base/authorize':
        _shape(body, {'executionId', 'executionCapability'});
        agent.authorizeCredentialProgramStart(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
        );
        return {'protocolVersion': 3, 'status': 'ok'};
      case '$base/materials/register':
        _shape(body, {'executionId', 'executionCapability', 'lease'});
        final lease = _map(body['lease']);
        _shape(lease, {'path', 'identity', 'files'});
        await agent.registerCredentialProgramMaterials(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          CredentialMaterialLease.fromPrivateJson(lease),
        );
        return {'protocolVersion': 3, 'status': 'ok'};
      case '$base/worker/register':
        _shape(body, {
          'executionId',
          'executionCapability',
          'workerPid',
          'workerCreatedAt',
        });
        if (body['workerPid'] is! int) {
          throw const CredentialUseFailure('invalid_type');
        }
        await agent.registerCredentialProgramWorker(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          body['workerPid'] as int,
          _text(body, 'workerCreatedAt'),
        );
        return {'protocolVersion': 3, 'status': 'ok'};
      case '$base/report':
        final operation = await agent.reportCredentialProgramExecution(
          deviceId,
          CredentialExecutionReport.fromPrivateJson(body),
        );
        return operation.toPublicJson();
      case '$base/cleanup':
        _shape(body, {'executionId', 'executionCapability', 'treeEnded'});
        if (body['treeEnded'] is! bool) {
          throw const CredentialUseFailure('invalid_type');
        }
        return (await agent.acknowledgeCredentialProgramCleanup(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          treeEnded: body['treeEnded'] as bool,
        )).toPublicJson();
      default:
        throw const CredentialUseFailure('unsupported_capability');
    }
  }
}
