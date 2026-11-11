import 'package:info_core/info_core.dart';

/// Private device Host transport. Ordinary Agent commands receive only the
/// public projections, never the first operation's material/proof response.
final class DeviceCredentialRoutes {
  DeviceCredentialRoutes(this.agent);
  final AgentAccess agent;
  static const sessionPaths = {
    '/credential-use/device/request',
    '/credential-use/device/operation',
    '/credential-use/device/operation/status',
    '/credential-use/device/execution/status',
  };
  static const proofPaths = {
    '/credential-use/device/worker/register',
    '/credential-use/device/materials/register',
    '/credential-use/device/execution/report',
    '/credential-use/device/cleanup/complete',
  };
  static bool handles(String path) =>
      sessionPaths.contains(path) || proofPaths.contains(path);
  void _shape(Map<String, dynamic> body, Set<String> keys) {
    if (body.length != keys.length || !body.keys.toSet().containsAll(keys)) {
      throw const CredentialUseFailure('unknown_field');
    }
  }

  String _text(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > 2000) {
      throw const CredentialUseFailure('invalid_type');
    }
    return value;
  }

  Future<Map<String, Object?>> dispatch(
    String deviceId,
    String path,
    Map<String, dynamic> body,
  ) async {
    switch (path) {
      case '/credential-use/device/request':
        final errors = submissionMetadataErrors(body);
        if (errors.isNotEmpty)
          return {
            'status': 'invalid_request',
            'errorCode': 'invalid_submission_metadata',
            'fieldErrors': errors,
          };
        final command = Map<String, dynamic>.from(body)
          ..remove('sessionSecret');
        final raw = command.remove('deviceLaunch');
        if (raw is! Map<String, dynamic>) {
          throw const CredentialUseFailure('invalid_plan');
        }
        final input = CredentialUseInput.fromJson(
          command,
          allowPortableLaunchPaths: true,
        );
        final request = await agent.requestDeviceCredentialUse(
          deviceId,
          _text(body, 'sessionSecret'),
          input,
          DeviceCredentialLaunch.fromPrivateJson(raw),
        );
        return agent.credentialUseStatus(
          _text(body, 'sessionSecret'),
          request.id,
        );
      case '/credential-use/device/operation':
      case '/credential-use/device/operation/status':
        final command = Map<String, dynamic>.from(body)
          ..remove('sessionSecret');
        if (path.endsWith('/status')) {
          final input = CredentialOperationInput.fromJson(
            command,
            allowPortableLaunchPaths: true,
          );
          return agent
                  .deviceCredentialOperationStatus(
                    deviceId,
                    _text(body, 'sessionSecret'),
                    input,
                  )
                  ?.toPublicJson() ??
              {'protocolVersion': 2, 'status': 'not_found'};
        }
        final raw = command.remove('deviceLaunch'),
            job = command.remove('deviceJob');
        if (raw is! Map<String, dynamic> || job is! String) {
          throw const CredentialUseFailure('invalid_plan');
        }
        final input = CredentialOperationInput.fromJson(
          command,
          allowPortableLaunchPaths: true,
        );
        final claim = await agent.beginDeviceCredentialOperation(
          deviceId,
          _text(body, 'sessionSecret'),
          input,
          DeviceCredentialLaunch.fromPrivateJson(raw),
          job,
        );
        return {'status': 'ok', ...claim.toPrivateJson()};
      case '/credential-use/device/execution/status':
        _shape(body, {'sessionSecret', 'executionId'});
        return agent
            .deviceCredentialExecutionStatus(
              deviceId,
              _text(body, 'sessionSecret'),
              _text(body, 'executionId'),
            )
            .toJson();
      case '/credential-use/device/worker/register':
        _shape(body, {
          'executionId',
          'executionCapability',
          'workerPid',
          'workerCreatedAt',
        });
        if (body['workerPid'] is! int) {
          throw const CredentialUseFailure('invalid_type');
        }
        await agent.registerDeviceCredentialWorker(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          body['workerPid'] as int,
          _text(body, 'workerCreatedAt'),
        );
      case '/credential-use/device/materials/register':
        _shape(body, {'executionId', 'executionCapability', 'lease'});
        if (body['lease'] is! Map<String, dynamic>) {
          throw const CredentialUseFailure('invalid_type');
        }
        await agent.registerDeviceCredentialMaterials(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          CredentialMaterialLease.fromPrivateJson(
            body['lease'] as Map<String, dynamic>,
          ),
        );
      case '/credential-use/device/execution/report':
        final report = CredentialExecutionReport.fromPrivateJson(body);
        return (await agent.reportDeviceCredentialExecution(
          deviceId,
          report,
        )).toJson();
      case '/credential-use/device/cleanup/complete':
        _shape(body, {'executionId', 'executionCapability', 'treeEnded'});
        if (body['treeEnded'] is! bool) {
          throw const CredentialUseFailure('invalid_type');
        }
        return (await agent.acknowledgeDeviceCredentialCleanup(
          deviceId,
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          treeEnded: body['treeEnded'] as bool,
        )).toJson();
      default:
        throw const CredentialUseFailure('unsupported_capability');
    }
    return {'protocolVersion': 2, 'status': 'ok'};
  }
}
