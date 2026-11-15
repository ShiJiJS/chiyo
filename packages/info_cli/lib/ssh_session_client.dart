part of 'agent_client.dart';

extension _SshClient on AgentClient {
  Future<Map<String, dynamic>> _executeSsh(Map<String, dynamic> input) async {
    if (_session == null) return {'status': 'session_required'};
    if (utf8.encode(jsonEncode(input)).length > 131072) {
      return {'status': 'invalid_request'};
    }
    if (input['command'] == 'ssh-request') {
      final capabilities = await _call('/capabilities', {});
      if (!(capabilities['capabilities'] as List? ?? []).contains(
        'ssh-interactive-sessions.v1',
      )) {
        return {'status': 'unsupported_capability'};
      }
      return _call('/credential-use/batch/request', {
        'sessionSecret': _session,
        'operationId': input['operationId'],
        'input': {
          'protocolVersion': 3,
          'purpose': input['purpose'],
          if (input.containsKey('title')) 'title': input['title'],
          'agentName': input['agentName'],
          'externalChatId': input['externalChatId'],
          'items': [
            {
              'credentialId': input['credentialId'],
              'version': input['version'],
              'destination': {'via': 'ssh', 'target': input['target']},
            },
          ],
        },
      });
    }
    final profile = _remote?.profile ?? _local?.profile;
    if (profile == null || deviceFileStateDirectory == null) {
      return {'status': 'service_unavailable'};
    }
    return DeviceCredentialHost(
      profile,
      deviceFileStateDirectory!,
      workerExecutable: _runtimeWorkerExecutable,
    ).execute(_session!, input);
  }
}
