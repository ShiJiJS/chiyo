import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'agent_devices.dart';
import 'device_credential_routes.dart';

/// Authenticated online transport adapter. It reuses the Agent-only protocol;
/// the loopback HTTP server and its Host/Origin protections remain unchanged.
final class AgentGateway {
  AgentGateway(this._protocol, this._devices, {AgentAccess? deviceCredentials})
    : _deviceCredentials = deviceCredentials == null
          ? null
          : DeviceCredentialRoutes(deviceCredentials);
  final AgentProtocol _protocol;
  final AgentDeviceRegistry _devices;
  final DeviceCredentialRoutes? _deviceCredentials;
  Future<void> _commands = Future.value();

  static const _metadata = {
    '/capabilities',
    '/catalog',
    '/credentials/catalog',
    '/directories/catalog',
    '/plugins/catalog',
    '/templates/catalog',
    '/templates/read',
  };
  static const _open = {'/session', '/session/lifecycle'};
  static const _session = {
    '/session/check',
    '/credential-reveal/request',
    '/credential-reveal/read',
    '/request',
    '/request/status',
    '/cancel',
    '/status',
    '/claim',
    '/import/submit',
    '/import/revise',
    '/import/status',
    '/update/submit',
    '/update/revise',
    '/update/status',
    '/delete/submit',
    '/delete/status',
    '/organization/request',
    '/organization/status',
    '/organization/tasks',
    '/organization/metadata',
    '/organization/submit',
    '/import-file/submit',
    '/import-file/status',
    '/information-file/fetch',
    '/information-file/status',
    '/information-file/release',
    '/information-file/download',
    '/information-file/complete',
    '/information-file/cleanup',
    ...DeviceCredentialRoutes.sessionPaths,
  };

  Future<Map<String, Object?>> dispatch(
    String bearer,
    String path,
    Map<String, dynamic> body,
  ) {
    // Serialize session creation and binding before another command can use it.
    // Owner approval remains in the core's existing transaction path.
    final result = _commands.then((_) => _dispatch(bearer, path, body));
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, Object?>> _dispatch(
    String bearer,
    String path,
    Map<String, dynamic> body,
  ) async {
    final capabilities = <AgentDeviceCapability>[];
    String text(String name) {
      final value = body[name];
      if (value is! String || value.isEmpty || value.length > 2000) {
        throw const AccessFailure('invalid_request');
      }
      return value;
    }

    if (_session.contains(path)) {
      capabilities.add(AgentDeviceCapability('session', text('sessionSecret')));
    } else if (path == '/information-file/watch' ||
        path == '/information-file/discard') {
      capabilities.add(
        AgentDeviceCapability('file-cleanup', text('cleanupCapability')),
      );
    } else if (DeviceCredentialRoutes.proofPaths.contains(path)) {
      capabilities.add(
        AgentDeviceCapability(
          'credential-execution',
          text('executionCapability'),
        ),
      );
    } else if (path == '/session/end') {
      capabilities.add(AgentDeviceCapability('end', text('endCapability')));
    } else if (path == '/read') {
      capabilities.add(AgentDeviceCapability('grant', text('token')));
    } else if (!_metadata.contains(path) && !_open.contains(path)) {
      throw const AccessFailure('unsupported_capability');
    }
    final device = await _devices.authorize(bearer, capabilities: capabilities);
    final Map<String, Object?> result;
    if (DeviceCredentialRoutes.handles(path)) {
      final routes = _deviceCredentials;
      if (routes == null) throw const AccessFailure('unsupported_capability');
      result = await routes.dispatch(device.id, path, body);
    } else {
      result = await _protocol.dispatch(path, body);
    }
    final minted = <AgentDeviceCapability>[
      if (_open.contains(path)) ...[
        AgentDeviceCapability('session', result['sessionSecret'] as String),
        if (result['endCapability'] != null)
          AgentDeviceCapability('end', result['endCapability'] as String),
      ],
      if (path == '/claim')
        AgentDeviceCapability('grant', result['token'] as String),
      if (path == '/information-file/fetch')
        if (result['delivery'] case final Map delivery)
          if (delivery['cleanupCapability'] case final String proof)
            AgentDeviceCapability('file-cleanup', proof),
      if (path == '/credential-use/device/operation')
        if (result['material'] case final Map material)
          if (material['executionCapability'] case final String proof)
            AgentDeviceCapability('credential-execution', proof),
    ];
    if (minted.isNotEmpty) {
      await _devices.bindCapabilities(bearer, device.generation, minted);
    }
    // Do not deliver a value or minted proof after concurrent revoke/restore.
    await _devices.authorize(
      bearer,
      generation: device.generation,
      capabilities: [...capabilities, ...minted],
    );
    if (path == '/capabilities') {
      return {
        ...result,
        // Advertise only commands actually connected to this online gateway.
        // Files and credentials follow their own tickets.
        'capabilities': [
          'information-request-operations.v1',
          'submission-metadata.v1',
          if ((result['capabilities'] as List).contains('credential-reveal.v1'))
            'credential-reveal.v1',
          'information-directory-discovery.v1',
          'agent-device-binding.v1',
          if (_deviceCredentials != null) ...[
            'credential-device-execution.v1',
            if ((result['capabilities'] as List).contains(
              'credential-use-reuse.v1',
            ))
              'credential-use-reuse.v1',
            if ((result['capabilities'] as List).contains(
              'credential-ssh-session-validity.v1',
            ))
              'credential-ssh-session-validity.v1',
          ],
          'information-import-operations.v1',
          'import-proposal-title.v1',
          'information-update-operations.v1',
          if ((result['capabilities'] as List).contains('credential-import.v1'))
            'credential-import.v1',
          if ((result['capabilities'] as List).contains(
            'information-attachments.v1',
          )) ...[
            'information-attachments.v1',
            'information-device-delivery.v1',
            'information-file-cleanup-watch.v1',
          ],
          if ((result['capabilities'] as List).contains(
            'information-file-upload.v1',
          )) ...[
            'information-file-upload.v1',
            'information-file-update.v1',
          ],
          if ((result['capabilities'] as List).contains(
            'information-import-admission.v1',
          ))
            'information-import-admission.v1',
          if ((result['capabilities'] as List).contains(
            'information-template-discovery.v1',
          ))
            'information-template-discovery.v1',
        ],
      };
    }
    return result;
  }
}
