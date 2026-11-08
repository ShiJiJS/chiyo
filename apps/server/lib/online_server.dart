import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

/// User management is a separate authenticated surface from the Agent API.
/// This host never starts a local credential executor or owns a desktop.
final class OnlineServer {
  OnlineServer._(this._http, this._service, this._ownerToken, this.serverId) {
    _http.listen(
      _handle,
      onError: (Object error, StackTrace stack) {
        // Rejected TLS peers and disconnected clients are transport failures,
        // not unhandled host errors. Certificate verification stays enabled.
        if (error is! HandshakeException &&
            error is! SocketException &&
            error is! HttpException) {
          Zone.current.handleUncaughtError(error, stack);
        }
      },
    );
  }
  final HttpServer _http;
  final InformationService _service;
  final String _ownerToken;
  final String serverId;
  int get port => _http.port;

  static Future<OnlineServer> start({
    required InformationService service,
    required SecurityContext tls,
    required String ownerToken,
    required String serverId,
    InternetAddress? address,
    int port = 0,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43,128}$').hasMatch(ownerToken) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(serverId)) {
      throw const FormatException('Invalid server configuration');
    }
    final http = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      tls,
    );
    return OnlineServer._(http, service, ownerToken, serverId);
  }

  Future<void> close() => _http.close(force: true);

  bool _authenticated(String? value) {
    final expected = 'Bearer $_ownerToken'.codeUnits;
    final supplied = (value ?? '').codeUnits;
    var difference = expected.length ^ supplied.length;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ (i < supplied.length ? supplied[i] : 0);
    }
    return difference == 0;
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const FormatException('Expected JSON');
    }
    final bytes = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const FormatException('Request too large');
      }
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>)
      throw const FormatException('Expected object');
    return value;
  }

  InformationDraftInput _draft(Map<String, dynamic> value) {
    if (value.keys.any(
      (k) => !const {
        'name',
        'description',
        'fields',
        'itemId',
        'baseVersion',
      }.contains(k),
    ))
      throw const FormatException('Unsupported draft member');
    final fields = value['fields'] as List;
    return InformationDraftInput(
      name: value['name'] as String,
      description: value['description'] as String,
      itemId: value['itemId'] as String?,
      baseVersion: value['baseVersion'] as int?,
      fields: fields.map((raw) {
        final f = raw as Map<String, dynamic>;
        if (f.keys.any(
          (k) => !const {'name', 'description', 'text', 'fieldId'}.contains(k),
        )) {
          throw const FormatException('Unsupported field member');
        }
        return InformationDraftField.text(
          f['name'] as String,
          f['description'] as String,
          f['text'] as String,
          fieldId: f['fieldId'] as String?,
        );
      }),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    Future<void> reply(int status, Object value) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.write(jsonEncode(value));
      await request.response.close();
    }

    try {
      // No browser management surface is part of this version.
      if (request.headers.value('origin') != null ||
          !_authenticated(request.headers.value('authorization'))) {
        await reply(401, {'error': 'unauthorized'});
        return;
      }
      final path = request.uri.pathSegments;
      if (request.method == 'GET' && request.uri.path == '/v1/server') {
        await reply(200, {'protocolVersion': 1, 'serverId': serverId});
      } else if (request.method == 'GET' &&
          request.uri.path == '/v1/owner/information') {
        await reply(200, {
          'items': [
            for (final item in _service.owner.information)
              {
                'id': item.id,
                'name': item.name,
                'description': item.description,
                'version': item.version,
                'directoryId': item.directoryId,
                'tagIds': item.tagIds.toList(),
                'fields': [
                  for (final f in item.fields)
                    {
                      'id': f.id,
                      'name': f.name,
                      'description': f.description,
                      'kind': f.kind.name,
                      'value': f.value,
                      'version': f.version,
                    },
                ],
              },
          ],
        });
      } else if (path.length == 4 &&
          path.take(3).join('/') == 'v1/owner/operations' &&
          request.method == 'GET') {
        final receipt = await _service.owner.informationRecordReceipt(
          path.last,
        );
        await reply(
          receipt == null ? 404 : 200,
          receipt?.toJson() ?? {'error': 'operation_not_found'},
        );
      } else if (path.length == 4 &&
          path.take(3).join('/') == 'v1/owner/saves' &&
          request.method == 'POST') {
        final receipt = await _service.owner.saveInformationRecord(
          path.last,
          _draft(await _body(request)),
        );
        await reply(200, receipt.toJson());
      } else {
        await reply(404, {'error': 'not_found'});
      }
    } on AccessFailure catch (e) {
      await reply(409, {'error': e.status});
    } on FormatException {
      await reply(400, {'error': 'invalid_request'});
    } on TypeError {
      await reply(400, {'error': 'invalid_request'});
    } on Object {
      // Never reflect field values, tokens, filesystem paths or exception text.
      try {
        await reply(500, {'error': 'service_failure'});
      } on Object {
        /* disconnected */
      }
    }
  }
}
