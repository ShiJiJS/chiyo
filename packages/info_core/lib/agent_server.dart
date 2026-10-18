import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'info_core.dart';
import 'protocol_json.dart';

class _CredentialRequestFailure implements Exception {
  const _CredentialRequestFailure(this.code, [this.fieldPath]);
  final String code;
  final String? fieldPath;
}

Map<String, Object?> _credentialFailure(String code, {String? fieldPath}) => {
  'protocolVersion': 1,
  'status': 'invalid_request',
  'errorCode': code,
  'retryable': false,
  'fieldPath': ?fieldPath,
};

/// Agent-only transport. OwnerAccess is intentionally not a dependency.
class AgentServer {
  AgentServer._(this._server, this._agent) {
    _server.listen(_handle);
  }
  final HttpServer _server;
  final AgentAccess _agent;
  int get port => _server.port;
  static Future<AgentServer> start(
    AgentAccess agent, {
    int port = 47125,
  }) async => AgentServer._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: false),
    agent,
  );
  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    Map<String, Object?> result;
    final runtime = request.uri.path.startsWith('/credential-use/');
    try {
      if (request.method != 'POST' ||
          request.headers.value('origin') != null ||
          request.headers.host != '127.0.0.1' ||
          request.headers.port != port ||
          request.headers.contentType?.mimeType != 'application/json') {
        throw const AccessFailure('unauthorized');
      }
      final limit =
          request.uri.path == '/import/submit' ||
              request.uri.path == '/organization/submit' ||
              request.uri.path == '/update/submit' ||
              request.uri.path == '/credentials/catalog' ||
              runtime
          ? 262144
          : 16384;
      if (request.contentLength > limit) {
        if (request.uri.path == '/credentials/catalog' || runtime) {
          throw const _CredentialRequestFailure('limit_exceeded');
        }
        throw const AccessFailure('invalid_request');
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > limit) {
          if (request.uri.path == '/credentials/catalog' || runtime) {
            throw const _CredentialRequestFailure('limit_exceeded');
          }
          throw const AccessFailure('invalid_request');
        }
        bytes.addAll(chunk);
      }
      final body = request.uri.path == '/credentials/catalog' || runtime
          ? decodeProtocolObject(utf8.decode(bytes))
          : jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        throw const AccessFailure('invalid_request');
      }
      result = await _dispatch(request.uri.path, body);
    } on CredentialUseFailure catch (error) {
      result = error.toJson();
    } on _CredentialRequestFailure catch (error) {
      result = _credentialFailure(error.code, fieldPath: error.fieldPath);
    } on FormatException {
      result = request.uri.path == '/credentials/catalog' || runtime
          ? _credentialFailure('invalid_json')
          : {'status': 'invalid_request'};
    } on AccessFailure catch (error) {
      result = {'status': error.status};
    } on Object {
      // Never echo submitted text, authorization material, or internal errors.
      result = {'status': 'invalid_request'};
    }
    if ((request.uri.path == '/credentials/catalog' || runtime) &&
        result['protocolVersion'] == null) {
      result = {
        'protocolVersion': 1,
        'status':
            {'service_unavailable', 'unauthorized'}.contains(result['status'])
            ? result['status']
            : 'invalid_request',
        'errorCode': result['status'] == 'service_unavailable'
            ? 'service_unavailable'
            : 'invalid_reference',
        'retryable': false,
      };
    }
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.headers.set('X-Content-Type-Options', 'nosniff');
    request.response.statusCode = result['status'] == 'unauthorized'
        ? 403
        : result['status'] == 'invalid_request'
        ? 400
        : 200;
    try {
      request.response.write(jsonEncode(result));
      await request.response.close();
    } on Object {
      /* A disconnected caller must not terminate the desktop. */
    }
  }

  Future<Map<String, Object?>> _dispatch(
    String path,
    Map<String, dynamic> body,
  ) async {
    switch (path) {
      case '/credential-use/materials/register':
        if (body.keys.any(
          (k) => !{'executionId', 'executionCapability', 'lease'}.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        await _agent.registerCredentialMaterials(
          _text(body, 'executionId'),
          _text(body, 'executionCapability'),
          CredentialMaterialLease.fromPrivateJson(
            body['lease'] as Map<String, dynamic>,
          ),
        );
        return {'protocolVersion': 1, 'status': 'ok'};
      case '/credential-use/cleanup':
        if (body.keys.any((k) => !{'sessionSecret', 'executionId'}.contains(k))) {
          throw const CredentialUseFailure('unknown_field');
        }
        final execution = await _agent.cleanupCredentialExecution(
          _text(body, 'sessionSecret'),
          _text(body, 'executionId'),
        );
        return {
          'protocolVersion': 1,
          'status': 'ok',
          'executionId': execution.id,
          'cleanupState': execution.cleanupState,
        };
      case '/credential-use/request':
        final session = _text(body, 'sessionSecret');
        final command = Map<String, dynamic>.from(body)
          ..remove('sessionSecret');
        final request = await _agent.requestCredentialUse(
          session,
          CredentialUseInput.fromJson(command),
        );
        return _agent.credentialUseStatus(session, request.id);
      case '/credential-use/consume':
        if (body.keys.any((k) => !{'sessionSecret', 'requestId'}.contains(k))) {
          throw const CredentialUseFailure('unknown_field');
        }
        return (await _agent.consumeCredentialUse(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
        )).toPrivateJson();
      case '/credential-use/execution/report':
        return (await _agent.reportCredentialExecution(
          CredentialExecutionReport.fromPrivateJson(body),
        )).toJson();
      case '/credential-use/execution/status':
        if (body.keys.any(
          (k) => !{'sessionSecret', 'executionId'}.contains(k),
        )) {
          throw const CredentialUseFailure('unknown_field');
        }
        return _agent
            .credentialExecutionStatus(
              _text(body, 'sessionSecret'),
              _text(body, 'executionId'),
            )
            .toJson();
      case '/credentials/catalog':
        if (body.keys.any((k) => !{'cursor', 'limit'}.contains(k))) {
          throw const _CredentialRequestFailure('unknown_field');
        }
        if (body['cursor'] != null && body['cursor'] is! String) {
          throw const _CredentialRequestFailure('invalid_type', 'cursor');
        }
        if (body['limit'] != null && body['limit'] is! int) {
          throw const _CredentialRequestFailure('invalid_type', 'limit');
        }
        if (body['limit'] is int &&
            ((body['limit'] as int) < 1 || (body['limit'] as int) > 100)) {
          throw const _CredentialRequestFailure('limit_exceeded', 'limit');
        }
        return _agent
            .credentialCatalog(
              cursor: body['cursor'] as String?,
              limit: body['limit'] as int? ?? 50,
            )
            .toJson();
      case '/delete/submit':
        return _submitDelete(body);
      case '/delete/status':
        return _agent.deleteStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/update/submit':
        return _submitUpdate(body);
      case '/update/status':
        return _agent.updateStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/import/submit':
        return _submitImport(body);
      case '/import/status':
        return _agent.importStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'proposalId'),
        );
      case '/organization/request':
        final ids = body['itemIds'];
        final agentName = body['agentName'] ?? '';
        if (ids is! List ||
            ids.any((id) => id is! String) ||
            agentName is! String) {
          throw const AccessFailure('invalid_request');
        }
        final task = await _agent.requestOrganization(
          _text(body, 'sessionSecret'),
          _text(body, 'purpose'),
          ids.cast<String>(),
          agentName: agentName,
        );
        return _agent.organizationStatus(_text(body, 'sessionSecret'), task.id);
      case '/organization/status':
        return _agent.organizationStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/organization/tasks':
        return {
          'status': 'ok',
          'tasks': _agent.organizationTasks(_text(body, 'sessionSecret')),
        };
      case '/organization/metadata':
        return _agent.organizationMetadata(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/organization/submit':
        final raw = body['changes'];
        if (raw is! List ||
            raw.length > 200 ||
            raw.any((c) => c is! Map<String, dynamic>)) {
          throw const AccessFailure('invalid_request');
        }
        final allowed = {
          'itemId',
          'baseVersion',
          'directoryId',
          'directoryName',
          'tagIds',
          'tagNames',
        };
        if (raw.any(
          (dynamic c) => (c as Map<String, dynamic>).keys.any(
            (key) => !allowed.contains(key),
          ),
        )) {
          throw const AccessFailure('invalid_request');
        }
        await _agent.submitOrganization(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
          raw
              .map(
                (dynamic c) =>
                    OrganizationChange.fromJson(c as Map<String, dynamic>),
              )
              .toList(),
        );
        return _agent.organizationStatus(
          _text(body, 'sessionSecret'),
          _text(body, 'taskId'),
        );
      case '/catalog':
        final query = body['query'] ?? '';
        final directoryId = body['directoryId'];
        final tagId = body['tagId'];
        final offset = body['offset'] ?? 0;
        final limit = body['limit'] ?? 20;
        if (query is! String ||
            (directoryId != null && directoryId is! String) ||
            (tagId != null && tagId is! String) ||
            offset is! int ||
            limit is! int) {
          throw const AccessFailure('invalid_request');
        }
        final page = _agent.searchCatalog(
          query: query,
          directoryId: directoryId as String?,
          tagId: tagId as String?,
          offset: offset,
          limit: limit,
        );
        return {
          'status': 'ok',
          'items': page.items,
          'total': page.total,
          'offset': offset,
          'nextOffset': page.nextOffset,
        };
      case '/session':
      case '/session/lifecycle':
        final session = _agent.openSessionWithEndCapability(
          _text(body, 'chatLabel'),
        );
        return {
          'status': 'ok',
          'sessionSecret': session.sessionSecret,
          if (path == '/session/lifecycle')
            'endCapability': session.endCapability,
        };
      case '/session/check':
        _agent.validateSession(_text(body, 'sessionSecret'));
        return {'status': 'ok'};
      case '/session/end':
        _agent.endSessionWithCapability(_text(body, 'endCapability'));
        return {'status': 'ended'};
      case '/request':
        final raw = body['fields'];
        if (raw is! List || raw.length > 200) {
          throw const AccessFailure('invalid_request');
        }
        final fields = raw.map((f) {
          if (f is! Map<String, dynamic>) {
            throw const AccessFailure('invalid_request');
          }
          return FieldRef(_text(f, 'itemId'), _text(f, 'fieldId'));
        }).toList();
        final receipt = _agent.request(
          _text(body, 'sessionSecret'),
          _text(body, 'purpose'),
          fields,
        );
        return _agent.status(_text(body, 'sessionSecret'), receipt.id);
      case '/cancel':
        final session = _text(body, 'sessionSecret');
        final id = _text(body, 'requestId');
        _agent.cancel(session, id);
        return _agent.status(session, id);
      case '/status':
        return _agent.status(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
        );
      case '/claim':
        final grant = _agent.claim(
          _text(body, 'sessionSecret'),
          _text(body, 'requestId'),
        );
        return {
          'status': 'ok',
          'token': grant.token,
          'fields': grant.fields.map((f) => f.toJson()).toList(),
          'expiresAt': grant.expiresAt.toUtc().toIso8601String(),
          'scopeNotice':
              'Only these item and field identities are approved. New items and fields require a new request.',
        };
      case '/read':
        return {
          'status': 'ok',
          'value': await _agent.read(
            _text(body, 'token'),
            FieldRef(_text(body, 'itemId'), _text(body, 'fieldId')),
          ),
        };
      default:
        throw const AccessFailure('unauthorized');
    }
  }

  Future<Map<String, Object?>> _submitImport(Map<String, dynamic> body) async {
    final raw = body['items'];
    if (raw is! List ||
        raw.isEmpty ||
        raw.length > 20 ||
        raw.any((i) => i is! Map<String, dynamic>)) {
      throw const AccessFailure('invalid_request');
    }
    for (final key in ['agentName', 'purpose']) {
      if (body.containsKey(key) && body[key] is! String) {
        throw const AccessFailure('invalid_request');
      }
    }
    final session = _text(body, 'sessionSecret');
    final items = raw
        .map((i) => ImportItemInput.fromJson(i as Map<String, dynamic>))
        .toList();
    final id = await _agent.submitImport(
      session,
      items,
      agentName: body['agentName'] is String ? body['agentName'] as String : '',
      purpose: body['purpose'] is String ? body['purpose'] as String : '',
    );
    return _agent.importStatus(session, id);
  }

  Future<Map<String, Object?>> _submitUpdate(Map<String, dynamic> body) async {
    final raw = body['update'];
    if (raw is! Map<String, dynamic>) {
      throw const AccessFailure('invalid_request');
    }
    final session = _text(body, 'sessionSecret');
    final id = await _agent.submitUpdate(session, UpdateInput.fromJson(raw));
    return _agent.updateStatus(session, id);
  }

  Future<Map<String, Object?>> _submitDelete(Map<String, dynamic> body) async {
    final version = body['baseVersion'];
    if (version is! int ||
        (body['fieldId'] != null && body['fieldId'] is! String)) {
      throw const AccessFailure('invalid_request');
    }
    final session = _text(body, 'sessionSecret');
    final id = await _agent.submitDelete(
      session,
      _text(body, 'itemId'),
      version,
      fieldId: body['fieldId'] == null ? null : _text(body, 'fieldId'),
    );
    return _agent.deleteStatus(session, id);
  }

  String _text(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > 2000) {
      throw const AccessFailure('invalid_request');
    }
    return value;
  }
}
