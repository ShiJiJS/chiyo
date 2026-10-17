import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AgentClient {
  AgentClient(this.port, {String? sessionSecret, this.sourceAgent = '通用 CLI'})
    : _session = sessionSecret;
  final int port;
  final String sourceAgent;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  String? _session;
  String? _endCapability;

  /// Private capability, for trusted adapters only. Never include in diagnostics.
  String? get sessionSecret => _session;
  String? get endCapability => _endCapability;
  final _tokens = <String, String>{};

  /// Trusted hook bootstrap only; creates a fresh, unapproved session.
  /// Ordinary CLI commands retain the original response contract.
  Future<Map<String, dynamic>> openLifecycleSession(String label) async {
    if (_session != null) return {'status': 'invalid_request'};
    final result = await _call('/session/lifecycle', {'chatLabel': label});
    final secret = result.remove('sessionSecret');
    final endCapability = result.remove('endCapability');
    if (result['status'] == 'ok' &&
        secret is String &&
        endCapability is String) {
      _session = secret;
      _endCapability = endCapability;
    }
    return result;
  }

  void close() {
    _tokens.clear();
    _session = null;
    _endCapability = null;
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> execute(Map<String, dynamic> input) async {
    final command = input['command'];
    if (utf8.encode(jsonEncode(input)).length >
        (command == 'credential-catalog' || command == 'import-submit' ||
                command == 'update-submit' ||
                command == 'organize-submit'
            ? 262144
            : 16384)) {
      return command == 'credential-catalog'
        ? {'protocolVersion': 1, 'status': 'invalid_request', 'errorCode': 'limit_exceeded', 'retryable': false}
        : {'status': 'invalid_request'};
    }
    switch (command) {
      case 'credential-catalog':
        if (input.keys.any((k) => !{'command','cursor','limit'}.contains(k))) {
          return {'protocolVersion': 1, 'status': 'invalid_request', 'errorCode': 'unknown_field', 'retryable': false};
        }
        if (input['cursor'] != null && input['cursor'] is! String ||
          input.containsKey('limit') && (input['limit'] is! int || (input['limit'] as int) < 1 || (input['limit'] as int) > 100)) {
          return {'protocolVersion': 1, 'status': 'invalid_request', 'errorCode': 'invalid_type', 'retryable': false};
        }
        return _call('/credentials/catalog', {'cursor': input['cursor'], 'limit': input['limit'] ?? 50});
      case 'organize-request':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/request', {
          'sessionSecret': _session,
          'purpose': input['purpose'],
          'itemIds': input['itemIds'],
          'agentName': input['agentName'] ?? sourceAgent,
        });
      case 'organize-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/status', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
        });
      case 'organize-wait':
        if (_session == null) return {'status': 'unauthorized'};
        final timeout = input['timeoutMs'] ?? 30000;
        if (timeout is! int || timeout < 0 || timeout > 300000) {
          return {'status': 'invalid_request'};
        }
        final watch = Stopwatch()..start();
        while (true) {
          final status = await _call('/organization/status', {
            'sessionSecret': _session,
            'taskId': input['taskId'],
          });
          if (status['status'] != 'pending') return status;
          if (watch.elapsedMilliseconds >= timeout) {
            return {...status, 'waitTimedOut': true};
          }
          await Future<void>.delayed(
            Duration(
              milliseconds: (timeout - watch.elapsedMilliseconds).clamp(1, 250),
            ),
          );
        }
      case 'organize-tasks':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/tasks', {'sessionSecret': _session});
      case 'organize-metadata':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/metadata', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
        });
      case 'organize-submit':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/organization/submit', {
          'sessionSecret': _session,
          'taskId': input['taskId'],
          'changes': input['changes'],
        });
      case 'delete-submit':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/delete/submit', {
          'sessionSecret': _session,
          'itemId': input['itemId'],
          'baseVersion': input['baseVersion'],
          if (input['fieldId'] != null) 'fieldId': input['fieldId'],
        });
      case 'delete-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/delete/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'update-submit':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/update/submit', {
          'sessionSecret': _session,
          'update': input['update'],
        });
      case 'update-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/update/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'import-submit':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/import/submit', {
          'sessionSecret': _session,
          'items': input['items'],
          'agentName': input['agentName'] ?? sourceAgent,
          if (input.containsKey('purpose')) 'purpose': input['purpose'],
        });
      case 'import-status':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/import/status', {
          'sessionSecret': _session,
          'proposalId': input['proposalId'],
        });
      case 'catalog':
        return _call('/catalog', {
          for (final key in [
            'query',
            'directoryId',
            'tagId',
            'offset',
            'limit',
          ])
            if (input.containsKey(key)) key: input[key],
        });
      case 'session':
        if (_session != null) return {'status': 'invalid_request'};
        final result = await _call('/session', {
          'chatLabel': input['chatLabel'],
        });
        final secret = result.remove('sessionSecret');
        final endCapability = result.remove('endCapability');
        if (result['status'] == 'ok' && secret is String) _session = secret;
        if (result['status'] == 'ok' && endCapability is String) {
          _endCapability = endCapability;
        }
        return result;
      case 'session-check':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/session/check', {'sessionSecret': _session});
      case 'request':
        if (_session == null) return {'status': 'unauthorized'};
        return _call('/request', {
          'sessionSecret': _session,
          'purpose': input['purpose'],
          'fields': input['fields'],
        });
      case 'status':
      case 'cancel':
      case 'claim':
        if (_session == null) return {'status': 'unauthorized'};
        final id = input['requestId'];
        if (id is! String) return {'status': 'invalid_request'};
        final result = await _call('/$command', {
          'sessionSecret': _session,
          'requestId': id,
        });
        final token = result.remove('token');
        if (command == 'claim' && result['status'] == 'ok' && token is String) {
          _tokens[id] = token;
        }
        return result;
      case 'wait':
        if (_session == null) return {'status': 'unauthorized'};
        final id = input['requestId'];
        final timeout = input['timeoutMs'] ?? 30000;
        if (id is! String ||
            timeout is! int ||
            timeout < 0 ||
            timeout > 300000) {
          return {'status': 'invalid_request'};
        }
        final elapsed = Stopwatch()..start();
        while (true) {
          final result = await _call('/status', {
            'sessionSecret': _session,
            'requestId': id,
          });
          if (result['status'] != 'pending') return result;
          final remaining = timeout - elapsed.elapsedMilliseconds;
          if (remaining <= 0) return {...result, 'waitTimedOut': true};
          await Future<void>.delayed(
            Duration(milliseconds: remaining < 250 ? remaining : 250),
          );
        }
      case 'read':
        final token = _tokens[input['requestId']];
        if (token == null) return {'status': 'unauthorized'};
        return _call('/read', {
          'token': token,
          'itemId': input['itemId'],
          'fieldId': input['fieldId'],
        });
      default:
        return {'status': 'invalid_request'};
    }
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      return await (() async {
        final request = await _http.post('127.0.0.1', port, path);
        request.headers.contentType = ContentType.json;
        request.followRedirects = false;
        request.write(jsonEncode(data));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return jsonDecode(text) as Map<String, dynamic>;
      })().timeout(const Duration(seconds: 5));
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }
}
