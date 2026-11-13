part of 'chiyo_cli.dart';

extension _ChiyoReveal on ChiyoCli {
  Future<void> _revealSupport(AgentClient client) async {
    final result = await client.execute({'command': 'capabilities'});
    if (result['status'] != 'ok' ||
        !(result['capabilities'] as List? ?? []).contains(
          'credential-reveal-operations.v1',
        )) {
      throw const _PublicFailure(
        'unsupported_capability',
        '当前服务不支持可恢复的原文读取申请，请先更新服务。',
        3,
      );
    }
  }

  Future<int> _credentialVersion(AgentClient client, String id) async {
    String? cursor;
    final seen = <String>{};
    for (var page = 0; page < 1000; page++) {
      final result = await client.execute({
        'command': 'credential-catalog',
        'limit': 100,
        'cursor': ?cursor,
      });
      if (result['status'] != 'ok') {
        throw const _PublicFailure(
          'connection_unavailable',
          '无法查询凭据当前版本，请检查原资料库连接。',
          3,
        );
      }
      for (final row in result['credentials'] as List? ?? []) {
        if (row is Map && row['credentialId'] == id && row['version'] is int) {
          return row['version'] as int;
        }
      }
      final next = result['nextCursor'];
      if (next == null) break;
      if (next is! String || !seen.add(next)) break;
      cursor = next;
    }
    throw const ChiyoUsageFailure('没有找到可见的凭据，请通过 credentials list 核对 ID 和版本。');
  }

  Future<Map<String, dynamic>> _requestReveal(
    ChiyoInvocation i,
    AgentClient client,
  ) async {
    await _revealSupport(client);
    final id = _required(i, 'credential');
    final previous = i.options['operation'] == null
        ? null
        : await _intents.read(i.options['operation'] as String);
    final version = i.options['version'] == null
        ? previous?.kind == 'reveal-request'
              ? previous!.payload['version'] as int
              : await _credentialVersion(client, id)
        : int.parse(i.options['version'] as String);
    final intent = await _intents.remember('reveal-request', {
      'command': 'request-reveal',
      'protocolVersion': 2,
      'credentialId': id,
      'version': version,
      'purpose': _required(i, 'purpose'),
      'fallbackReason': _required(i, 'reason'),
      'agentName': _activeContext.agentName,
      'externalChatId': _activeContext.chatId,
      'submissionVersion': 1,
    }, operationId: i.options['operation'] as String?);
    return _submitReveal(client, intent);
  }

  Future<Map<String, dynamic>> _submitReveal(
    AgentClient client,
    ChiyoIntent intent,
  ) async {
    await _revealSupport(client);
    final result = await client.execute({
      ...intent.payload,
      'operationId': intent.operationId,
    });
    return {
      ...result,
      'operationId': intent.operationId,
      if (result['status'] == 'service_unavailable')
        'status': 'request_unknown',
    };
  }

  Future<Map<String, dynamic>> _readReveal(
    ChiyoInvocation i,
    AgentClient client,
  ) async {
    await _revealSupport(client);
    final requestId = _required(i, 'request');
    final request = await client.execute({
      'command': 'requests-show',
      'id': requestId,
    });
    if (request['kind'] != 'credential-reveal' ||
        request['status'] != 'approved' &&
            request['status'] != 'partially_approved') {
      return {
        ...request,
        'status':
            {
              'pending',
              'not_found',
              'approved',
              'partially_approved',
            }.contains(request['status'])
            ? 'scope_not_approved'
            : request['status'],
        'requestId': requestId,
      };
    }
    final selectedId = i.options['operation'] as String?;
    final previous = selectedId == null
        ? null
        : await _intents.read(selectedId);
    final intent = await _intents.remember('reveal-read', {
      'requestId': requestId,
    }, operationId: selectedId);
    // An existing send intent cannot prove the plaintext response arrived.
    // It can only query the audit, never silently deliver the password again.
    if (previous != null) return _revealReceipt(client, intent);
    final result = await client.execute({
      'command': 'read-reveal',
      'protocolVersion': 2,
      'requestId': intent.payload['requestId'],
      'operationId': intent.operationId,
    });
    if (result['status'] == 'service_unavailable' ||
        result['errorCode'] == 'attempt_consumed') {
      return {
        'status': 'operation_unknown',
        'operationId': intent.operationId,
        'requestId': intent.payload['requestId'],
        'secretReturned': false,
      };
    }
    return {...result, 'operationId': intent.operationId};
  }

  Future<Map<String, dynamic>> _revealReceipt(
    AgentClient client,
    ChiyoIntent intent,
  ) async {
    final result = await client.execute({
      'command': 'operations-show',
      'id': intent.operationId,
    });
    return {
      if (result['status'] == 'ok') ...result,
      'status': 'operation_unknown',
      'operationId': intent.operationId,
      'requestId': intent.payload['requestId'],
      'secretReturned': false,
      'readRecorded':
          result['status'] == 'ok' &&
          result['kind'] == 'credential-reveal-read',
      'next': '原操作只查询记录，不再次返回密码。确需再次读取时，使用新的操作编号，并确认原文读取批准仍然有效。',
    };
  }
}
