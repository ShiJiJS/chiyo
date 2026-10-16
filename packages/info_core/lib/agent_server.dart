import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'info_core.dart';

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
              request.uri.path == '/update/submit'
          ? 262144
          : 16384;
      if (request.contentLength > limit) {
        throw const AccessFailure('invalid_request');
      }
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 5))) {
        if (bytes.length + chunk.length > limit) {
          throw const AccessFailure('invalid_request');
        }
        bytes.addAll(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map<String, dynamic>) {
        throw const AccessFailure('invalid_request');
      }
      result = await _dispatch(request.uri.path, body);
    } on AccessFailure catch (error) {
      result = {'status': error.status};
    } on Object {
      // Never echo submitted text, authorization material, or internal errors.
      result = {'status': 'invalid_request'};
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
        final session = _agent.openSessionWithEndCapability(
          _text(body, 'chatLabel'),
        );
        return {
          'status': 'ok',
          'sessionSecret': session.sessionSecret,
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
    final session = _text(body, 'sessionSecret');
    final items = raw
        .map((i) => ImportItemInput.fromJson(i as Map<String, dynamic>))
        .toList();
    final id = await _agent.submitImport(session, items);
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

  String _text(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is! String || value.isEmpty || value.length > 2000) {
      throw const AccessFailure('invalid_request');
    }
    return value;
  }
}
