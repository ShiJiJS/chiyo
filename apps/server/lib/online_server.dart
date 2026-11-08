import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/information_transport.dart';

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

  Future<void> _handle(HttpRequest request) async {
    Future<void> reply(int status, Object value) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.headers.set('x-chiyo-server-id', serverId);
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
      final expectedServer = request.headers.value('x-chiyo-server-id');
      if (expectedServer != null && expectedServer != serverId) {
        await reply(409, {'error': 'server_changed'});
        return;
      }
      final path = request.uri.pathSegments;
      if (request.method == 'GET' && request.uri.path == '/v1/server') {
        await reply(200, {'protocolVersion': 1, 'serverId': serverId});
      } else if (request.method == 'GET' &&
          request.uri.path == '/v1/owner/information') {
        await reply(200, {
          'items': _service.owner.information.map(informationToJson).toList(),
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
          informationDraftFromJson(await _body(request)),
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
