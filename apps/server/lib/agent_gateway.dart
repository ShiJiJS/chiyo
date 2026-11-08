import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'agent_devices.dart';

/// Authenticated online transport adapter. It reuses the Agent-only protocol;
/// the loopback HTTP server and its Host/Origin protections remain unchanged.
final class AgentGateway {
  AgentGateway(this._protocol, this._devices, {AgentAccess? deviceCredentials})
    : _deviceCredentials = deviceCredentials;
  final AgentProtocol _protocol;
  final AgentDeviceRegistry _devices;
  final AgentAccess? _deviceCredentials;
  Future<void> _commands = Future.value();

  static const _metadata = {
    '/capabilities',
    '/catalog',
    '/directories/catalog',
    '/plugins/catalog',
    '/templates/catalog',
    '/templates/read',
  };
  static const _open = {'/session', '/session/lifecycle'};
  static const _session = {
    '/session/check',
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
    '/credential-use/device/request',
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
    } else if (path == '/session/end') {
      capabilities.add(AgentDeviceCapability('end', text('endCapability')));
    } else if (path == '/read') {
      capabilities.add(AgentDeviceCapability('grant', text('token')));
    } else if (!_metadata.contains(path) && !_open.contains(path)) {
      throw const AccessFailure('unsupported_capability');
    }
    final device = await _devices.authorize(bearer, capabilities: capabilities);
    final Map<String, Object?> result;
    if (path == '/credential-use/device/request') {
      final agent = _deviceCredentials;
      if (agent == null) throw const AccessFailure('unsupported_capability');
      final command = Map<String, dynamic>.from(body)..remove('sessionSecret');
      final raw = command.remove('deviceLaunch');
      if (raw is! Map<String, dynamic>) {
        throw const CredentialUseFailure('invalid_plan');
      }
      final input = CredentialUseInput.fromJson(command);
      final request = await agent.requestDeviceCredentialUse(
        device.id,
        text('sessionSecret'),
        input,
        DeviceCredentialLaunch.fromPrivateJson(raw),
      );
      result = agent.credentialUseStatus(text('sessionSecret'), request.id);
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
          'information-directory-discovery.v1',
          'agent-device-binding.v1',
          'information-import-operations.v1',
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
