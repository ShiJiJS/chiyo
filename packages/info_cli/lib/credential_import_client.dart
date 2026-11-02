part of 'agent_client.dart';

extension _CredentialImportClient on AgentClient {
  Future<Map<String, dynamic>> _executeImportCommand(
    Map<String, dynamic> input, {
    required bool revise,
  }) async {
    if (_session == null) return {'status': 'unauthorized'};
    final raw = input['items'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 20 ||
        raw.any((row) => row is! Map)) {
      return {'status': 'invalid_request'};
    }
    final hasCredential = raw.any(
      (row) => (row as Map).containsKey('credential'),
    );
    if (hasCredential || input.containsKey('operationId')) {
      final capabilities = await _call('/capabilities', {});
      if (capabilities['status'] != 'ok') return capabilities;
      if (input.containsKey('operationId') &&
          !(capabilities['capabilities'] as List? ?? []).contains(
            'information-import-operations.v1',
          )) {
        return {'status': 'unsupported_capability'};
      }
      if (hasCredential &&
          !(capabilities['capabilities'] as List? ?? []).contains(
            'credential-import.v1',
          )) {
        return {'status': 'unsupported_capability'};
      }
      final live = await _call('/session/check', {'sessionSecret': _session});
      if (live['status'] != 'ok') return live;
    }
    final items = <Map<String, dynamic>>[];
    try {
      for (final row in raw) {
        final item = Map<String, dynamic>.from(row as Map);
        if (item['credential'] != null) {
          final credential = Map<String, dynamic>.from(
            item['credential'] as Map,
          );
          if (credential.containsKey('filePath')) {
            if (credential.length != 3 ||
                credential['source'] != 'agentFile' ||
                credential['contextExposed'] is! bool ||
                credential['filePath'] is! String) {
              return {'status': 'invalid_credential_file'};
            }
            final file = File(credential['filePath'] as String);
            if ((await file.stat()).type != FileSystemEntityType.file) {
              return {'status': 'invalid_credential_file'};
            }
            final handle = await file.open();
            try {
              final length = await handle.length();
              if (length < 1 || length > 1048576) {
                return {'status': 'invalid_credential_file'};
              }
              final bytes = await handle.read(1048577);
              if (bytes.length != length || await handle.length() != length) {
                return {'status': 'invalid_credential_file'};
              }
              item['credential'] = CredentialImportInput.agentFile(
                file.uri.pathSegments.last,
                bytes,
                contextExposed: credential['contextExposed'] as bool,
              ).submissionJson;
            } finally {
              await handle.close();
            }
          } else {
            item['credential'] = CredentialImportInput.fromJson(
              credential,
            ).submissionJson;
          }
        }
        items.add(item);
      }
    } on Object {
      // Errors never disclose file contents, source paths, bytes or secrets.
      return {'status': 'invalid_credential_input'};
    }
    final body = <String, dynamic>{
      'sessionSecret': _session,
      'items': items,
      if (revise) ...{
        'proposalId': input['proposalId'],
        'version': input['version'],
      } else ...{
        'agentName': input['agentName'] ?? sourceAgent,
        if (input.containsKey('purpose')) 'purpose': input['purpose'],
        if (input.containsKey('operationId'))
          'operationId': input['operationId'],
      },
    };
    if (utf8.encode(jsonEncode(body)).length > 6000000) {
      return {'status': 'invalid_request'};
    }
    return _call(revise ? '/import/revise' : '/import/submit', body);
  }
}
