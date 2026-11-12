import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'connection_profile.dart';
import 'owner_client.dart';
import 'server_trust.dart';

Future<OwnerClient> connectOwnerProfile(ConnectionProfile profile) =>
    OwnerClient.connect(
      address: Uri.parse(profile.address),
      token: profile.token,
      expectedServerId: profile.serverId.isEmpty ? null : profile.serverId,
      certificate: profile.certificate,
    );

final class ServerSetupProbe {
  const ServerSetupProbe({
    required this.address,
    required this.certificate,
    required this.serverId,
    required this.passwordConfigured,
    required this.requiresOwnerToken,
    this.remembered,
    this.supportsSetup = true,
  });
  final Uri address;
  final String certificate, serverId;
  final bool passwordConfigured, requiresOwnerToken, supportsSetup;
  final ConnectionProfile? remembered;
}

/// First contact only obtains public server state and its certificate. Passwords
/// and tokens are sent exclusively over a subsequently pinned TLS connection.
/// Previously saved trust is never replaced by automatic certificate discovery.
abstract final class ServerSetup {
  static Future<ServerSetupProbe> discover(
    Uri address, {
    ConnectionProfile? previous,
  }) async {
    if (address.scheme != 'https' ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty ||
        !{'', '/'}.contains(address.path) ||
        address.hasQuery ||
        address.hasFragment) {
      throw const RemoteFailure('invalid_connection');
    }
    final saved =
        previous != null && Uri.parse(previous.address).origin == address.origin
        ? previous
        : null;
    var certificate = saved?.certificate ?? '';
    if (saved == null) {
      SecureSocket? socket;
      try {
        socket = await SecureSocket.connect(
          address.host,
          address.port,
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 10),
        );
        certificate = socket.peerCertificate?.pem ?? '';
        if (certificate.isEmpty) throw const RemoteFailure('untrusted_server');
      } on HandshakeException {
        throw const RemoteFailure('untrusted_server');
      } on SocketException {
        throw const RemoteFailure('server_unavailable');
      } on TimeoutException {
        throw const RemoteFailure('server_timeout');
      } finally {
        socket?.destroy();
      }
    }
    final client = serverHttpClient(certificate: certificate);
    try {
      Map<String, dynamic> info;
      try {
        info = await _call(
          client,
          address,
          '/v1/setup',
          token: saved?.token,
          expectedServerId: saved?.serverId,
          method: 'GET',
        );
      } on RemoteFailure catch (error) {
        if (saved == null ||
            !{
              'unauthorized',
              'not_found',
              'invalid_request',
              'unsupported_route',
            }.contains(error.code))
          rethrow;
        final owner = await connectOwnerProfile(saved);
        try {
          return ServerSetupProbe(
            address: address,
            certificate: certificate,
            serverId: owner.serverId,
            passwordConfigured: false,
            requiresOwnerToken: true,
            remembered: saved,
            supportsSetup: false,
          );
        } finally {
          owner.close();
        }
      }
      if (info['protocolVersion'] != 1 ||
          info['serverId'] is! String ||
          info['passwordConfigured'] is! bool ||
          info['requiresOwnerToken'] is! bool) {
        throw const RemoteFailure('unsupported_protocol');
      }
      ConnectionProfile? remembered;
      if (saved != null) {
        try {
          final owner = await connectOwnerProfile(saved);
          remembered = ConnectionProfile(
            address: address.toString(),
            token: saved.token,
            serverId: owner.serverId,
            certificate: certificate,
          );
          owner.close();
        } on RemoteFailure catch (error) {
          if (error.code != 'unauthorized') rethrow;
        }
      }
      return ServerSetupProbe(
        address: address,
        certificate: certificate,
        serverId: info['serverId'] as String,
        passwordConfigured: info['passwordConfigured'] as bool,
        requiresOwnerToken: info['requiresOwnerToken'] as bool,
        remembered: remembered,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<ConnectionProfile> authenticate(
    ServerSetupProbe probe,
    String password, {
    required bool initialize,
  }) async {
    if (!probe.supportsSetup)
      throw const RemoteFailure('server_update_required');
    if (initialize && probe.requiresOwnerToken && probe.remembered == null) {
      throw const RemoteFailure('owner_confirmation_required');
    }
    final client = serverHttpClient(certificate: probe.certificate);
    try {
      final response = await _call(
        client,
        probe.address,
        initialize ? '/v1/setup/initialize' : '/v1/setup/login',
        expectedServerId: probe.serverId,
        token: initialize ? probe.remembered?.token : null,
        body: {'password': password},
      );
      return _profile(
        probe.address,
        probe.certificate,
        probe.serverId,
        response,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<ConnectionProfile> changePassword(
    ConnectionProfile profile,
    String current,
    String replacement,
  ) async {
    final client = await connectOwnerProfile(profile);
    try {
      final response = await client.request(
        'POST',
        '/v1/owner/connection-password',
        {'currentPassword': current, 'newPassword': replacement},
      );
      return _profile(
        Uri.parse(profile.address),
        profile.certificate,
        profile.serverId,
        response,
      );
    } finally {
      client.close();
    }
  }

  static ConnectionProfile _profile(
    Uri address,
    String certificate,
    String id,
    Map<String, dynamic> response,
  ) {
    if (response['serverId'] != id ||
        response['token'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{43,128}$',
        ).hasMatch(response['token'] as String)) {
      throw const RemoteFailure('invalid_response');
    }
    return ConnectionProfile(
      address: address.toString(),
      token: response['token'] as String,
      serverId: id,
      certificate: certificate,
    );
  }

  static Future<Map<String, dynamic>> _call(
    HttpClient client,
    Uri address,
    String path, {
    String method = 'POST',
    Object? body,
    String? token,
    String? expectedServerId,
  }) async {
    client.connectionTimeout = const Duration(seconds: 10);
    HttpClientRequest? request;
    try {
      return await (() async {
        request = await client.openUrl(method, address.resolve(path));
        request!.followRedirects = false;
        if (token != null && token.isNotEmpty)
          request!.headers.set('authorization', 'Bearer $token');
        if (expectedServerId != null && expectedServerId.isNotEmpty)
          request!.headers.set('x-chiyo-server-id', expectedServerId);
        if (body != null) {
          request!.headers.contentType = ContentType.json;
          request!.write(jsonEncode(body));
        }
        final response = await request!.close();
        if (expectedServerId != null &&
            expectedServerId.isNotEmpty &&
            response.headers.value('x-chiyo-server-id') != expectedServerId) {
          throw const RemoteFailure('server_changed');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536)
            throw const RemoteFailure('invalid_response');
          bytes.addAll(chunk);
        }
        final result = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200)
          throw RemoteFailure(result['error'] as String? ?? 'service_failure');
        return result;
      })().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          request?.abort();
          throw const RemoteFailure('server_timeout');
        },
      );
    } on HandshakeException {
      throw const RemoteFailure('untrusted_server');
    } on SocketException {
      throw const RemoteFailure('server_unavailable');
    } on FormatException {
      throw const RemoteFailure('invalid_response');
    } on TypeError {
      throw const RemoteFailure('invalid_response');
    }
  }
}
