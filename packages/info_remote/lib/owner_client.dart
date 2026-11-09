import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';

final class RemoteFailure implements Exception {
  const RemoteFailure(this.code, {this.fieldErrors = const {}});
  final String code;
  final Map<String, String> fieldErrors;
  @override
  String toString() => 'RemoteFailure($code)';
}

/// Owns a client connection only, never the server process or a local library.
/// Management credentials belong to the user App, not the Agent CLI.
final class OwnerClient {
  OwnerClient._(
    this.address,
    this._token,
    this._http,
    this.serverId, {
    this.initialWorkspaceObservation,
    this.initialLibrarySort,
  });
  final Uri address;
  final String _token;
  final HttpClient _http;
  final String serverId;
  final String? initialWorkspaceObservation;
  final String? initialLibrarySort;

  static Future<OwnerClient> connect({
    required Uri address,
    required String token,
    String? expectedServerId,
    SecurityContext? trust,
  }) async {
    if (address.scheme != 'https' ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty ||
        !const ['', '/'].contains(address.path) ||
        address.hasQuery ||
        address.hasFragment ||
        token.isEmpty) {
      throw const RemoteFailure('invalid_connection');
    }
    final http = HttpClient(context: trust)
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final provisional = OwnerClient._(
        address,
        token,
        http,
        expectedServerId ?? '',
      );
      final identity = await provisional.request('GET', '/v1/server');
      final id = identity['serverId'];
      if (identity['protocolVersion'] != 1 || id is! String || id.isEmpty) {
        throw const RemoteFailure('unsupported_protocol');
      }
      if (expectedServerId != null && expectedServerId != id)
        throw const RemoteFailure('server_changed');
      return OwnerClient._(
        address,
        token,
        http,
        id,
        initialWorkspaceObservation:
            identity['workspaceObservation'] as String?,
        initialLibrarySort: identity['librarySort'] as String?,
      );
    } on Object {
      http.close(force: true);
      rethrow;
    }
  }

  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Object? body,
  ]) async {
    HttpClientRequest? active;
    var expired = false;
    try {
      return await (() async {
        final target = address.resolve(path);
        if (target.origin != address.origin)
          throw const RemoteFailure('invalid_request');
        final request = active = await _http.openUrl(method, target);
        request.followRedirects = false;
        if (expired) {
          request.abort();
          throw TimeoutException('Request expired');
        }
        request.headers.set('authorization', 'Bearer $_token');
        if (serverId.isNotEmpty)
          request.headers.set('x-chiyo-server-id', serverId);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (serverId.isNotEmpty &&
            response.headers.value('x-chiyo-server-id') != serverId) {
          throw const RemoteFailure('server_changed');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 15),
        )) {
          if (bytes.length + chunk.length > 32 * 1024 * 1024)
            throw const RemoteFailure('response_too_large');
          bytes.addAll(chunk);
        }
        final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          throw RemoteFailure(
            value['error'] as String? ?? 'service_failure',
            fieldErrors: value['fieldErrors'] == null
                ? const {}
                : Map<String, String>.unmodifiable(
                    (value['fieldErrors'] as Map).cast<String, String>(),
                  ),
          );
        }
        return value;
      })().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          expired = true;
          active?.abort();
          throw TimeoutException('Request expired');
        },
      );
    } on HandshakeException {
      throw const RemoteFailure('untrusted_server');
    } on SocketException {
      throw const RemoteFailure('server_unavailable');
    } on TimeoutException {
      throw const RemoteFailure('server_timeout');
    } on HttpException {
      throw const RemoteFailure('connection_closed');
    } on FormatException {
      throw const RemoteFailure('invalid_response');
    } on TypeError {
      throw const RemoteFailure('invalid_response');
    }
  }

  Future<List<InformationItem>> information() async =>
      ((await request('GET', '/v1/owner/information'))['items'] as List)
          .map((item) => informationFromJson(item as Map<String, dynamic>))
          .toList();

  Future<InformationRecordReceipt> save(
    String operationId,
    InformationDraftInput input,
  ) async => InformationRecordReceipt.fromJson(
    await request(
      'POST',
      '/v1/owner/saves/${Uri.encodeComponent(operationId)}',
      input.toPrivateJson(),
    ),
  );

  Future<InformationRecordReceipt?> receipt(String operationId) async {
    try {
      return InformationRecordReceipt.fromJson(
        await request(
          'GET',
          '/v1/owner/operations/${Uri.encodeComponent(operationId)}',
        ),
      );
    } on RemoteFailure catch (e) {
      if (e.code == 'operation_not_found') return null;
      rethrow;
    }
  }
}
