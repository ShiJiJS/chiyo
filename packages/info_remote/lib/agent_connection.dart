import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/protocol_json.dart';

/// Private device connection, not the user's management identity. Pin the
/// intended server before sending a command; no discovery of owner credentials.
final class AgentConnectionProfile {
  AgentConnectionProfile({
    required this.address,
    required this.deviceToken,
    required this.serverId,
    this.certificate = '',
  }) {
    if (address.scheme != 'https' ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty ||
        !const ['', '/'].contains(address.path) ||
        address.hasQuery ||
        address.hasFragment ||
        address.port < 1 ||
        address.port > 65535 ||
        !RegExp(
          r'^[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}$',
        ).hasMatch(deviceToken) ||
        !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(serverId) ||
        certificate.length > 65536) {
      throw const FormatException('Invalid Agent connection');
    }
  }
  final Uri address;
  final String deviceToken, serverId, certificate;
  Map<String, Object?> toPrivateJson() => {
    'version': 1,
    'role': 'agent',
    'address': address.toString(),
    'deviceToken': deviceToken,
    'serverId': serverId,
    'certificate': certificate,
  };
  factory AgentConnectionProfile.fromPrivateJson(Map<String, dynamic> j) {
    try {
      if (j.length != 6 ||
          j['version'] != 1 ||
          j['role'] != 'agent' ||
          j.keys.any(
            (k) => !const {
              'version',
              'role',
              'address',
              'deviceToken',
              'serverId',
              'certificate',
            }.contains(k),
          )) {
        throw const FormatException();
      }
      return AgentConnectionProfile(
        address: Uri.parse(j['address'] as String),
        deviceToken: j['deviceToken'] as String,
        serverId: j['serverId'] as String,
        certificate: j['certificate'] as String,
      );
    } on Object {
      throw const FormatException('Invalid Agent connection');
    }
  }
  SecurityContext get trust => certificate.isEmpty
      ? SecurityContext.defaultContext
      : (SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(utf8.encode(certificate)));

  static Future<AgentConnectionProfile> read(File file) async {
    if (!Platform.isMacOS && !Platform.isLinux)
      throw const FormatException('Unsupported private storage');
    final parent = file.parent;
    if (!file.isAbsolute ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        (await file.stat()).mode & 0xE3F != 0 ||
        (await parent.stat()).mode & 0xE3F != 0) {
      throw const FormatException('Invalid private Agent connection');
    }
    if (await file.length() > 131072)
      throw const FormatException('Invalid Agent connection');
    return AgentConnectionProfile.fromPrivateJson(
      decodeProtocolObject(await file.readAsString(), maxBytes: 131072),
    );
  }

  /// Only a dedicated private directory is supplied by the trusted owner setup.
  /// The file is replaced atomically; no Keychain or global trust is involved.
  Future<File> saveIn(Directory directory) async {
    if (!Platform.isMacOS && !Platform.isLinux)
      throw const FormatException('Unsupported private storage');
    final folder = directory.absolute;
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound)
      throw const FormatException('Invalid Agent directory');
    await folder.create(recursive: true);
    if ((await Process.run('/bin/chmod', ['700', folder.path])).exitCode != 0)
      throw const FormatException('Private storage unavailable');
    final staging = await folder.createTemp('.agent-connection-');
    try {
      if ((await Process.run('/bin/chmod', ['700', staging.path])).exitCode !=
          0)
        throw const FormatException('Private storage unavailable');
      final file = File('${staging.path}/profile');
      await file.create(exclusive: true);
      if ((await Process.run('/bin/chmod', ['600', file.path])).exitCode != 0)
        throw const FormatException('Private storage unavailable');
      await file.writeAsString(jsonEncode(toPrivateJson()), flush: true);
      return await file.rename('${folder.path}/agent-connection.json');
    } finally {
      await staging.delete(recursive: true);
    }
  }
}

/// Agent-only HTTPS. Paths cannot escape to user management or another origin.
final class AgentConnection {
  AgentConnection(this.profile)
    : _http = HttpClient(context: profile.trust)
        ..connectionTimeout = const Duration(seconds: 5);
  final AgentConnectionProfile profile;
  final HttpClient _http;
  bool _closed = false, _serverChanged = false;
  void close() {
    _closed = true;
    _http.close(force: true);
  }

  Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_serverChanged) return {'status': 'server_changed'};
    if (_closed) return {'status': 'service_unavailable'};
    if (!RegExp(r'^/[a-z0-9-]+(?:/[a-z0-9-]+)*$').hasMatch(path))
      return {'status': 'invalid_request'};
    try {
      return await (() async {
        final request = await _http.postUrl(
          profile.address.resolve('/v1/agent$path'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer ${profile.deviceToken}');
        request.headers.set('x-chiyo-server-id', profile.serverId);
        request.write(jsonEncode(body));
        final response = await request.close();
        if (response.headers.value('x-chiyo-server-id') != profile.serverId) {
          _serverChanged = true;
          _http.close(force: true);
          return <String, dynamic>{'status': 'server_changed'};
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 32 * 1024 * 1024)
            throw const FormatException();
          bytes.addAll(chunk);
        }
        final result = decodeProtocolObject(
          utf8.decode(bytes),
          maxBytes: 32 * 1024 * 1024,
        );
        if (response.statusCode != 200) {
          final code = result['error'] ?? result['status'];
          return <String, dynamic>{
            'status': code is String && !const {'ok', 'ended'}.contains(code)
                ? code
                : 'service_unavailable',
            if (result['fieldErrors'] != null)
              'fieldErrors': Map<String, String>.unmodifiable(
                (result['fieldErrors'] as Map).cast<String, String>(),
              ),
          };
        }
        if (result['status'] is! String) throw const FormatException();
        return result;
      })().timeout(timeout);
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }
}
