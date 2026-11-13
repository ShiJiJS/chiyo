import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'server_trust.dart';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';

/// Private device connection, not the user's management identity. Pin the
/// intended server before sending a command; no discovery of owner credentials.
final class AgentConnectionProfile {
  factory AgentConnectionProfile({
    required Uri address,
    required String deviceToken,
    required String serverId,
    String certificate = '',
  }) => AgentConnectionProfile._(
    address,
    deviceToken,
    serverId,
    certificate,
    false,
  );

  factory AgentConnectionProfile.local({
    required int port,
    required String deviceToken,
    required String libraryId,
  }) => AgentConnectionProfile._(
    Uri(scheme: 'http', host: '127.0.0.1', port: port),
    deviceToken,
    libraryId,
    '',
    true,
  );

  AgentConnectionProfile._(
    this.address,
    this.deviceToken,
    this.serverId,
    this.certificate,
    this.isLocal,
  ) {
    if ((isLocal
            ? address.scheme != 'http' ||
                  address.host != '127.0.0.1' ||
                  certificate.isNotEmpty
            : address.scheme != 'https') ||
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
  final bool isLocal;
  final Uri address;
  final String deviceToken, serverId, certificate;
  Map<String, Object?> toPrivateJson() => {
    'version': isLocal ? 2 : 1,
    'role': isLocal ? 'local-agent' : 'agent',
    'address': address.toString(),
    'deviceToken': deviceToken,
    'serverId': serverId,
    'certificate': certificate,
  };
  factory AgentConnectionProfile.fromPrivateJson(Map<String, dynamic> j) {
    try {
      if (j.length != 6 ||
          !(j['version'] == 1 && j['role'] == 'agent' ||
              j['version'] == 2 && j['role'] == 'local-agent') ||
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
      if (j['role'] == 'local-agent') {
        final address = Uri.parse(j['address'] as String);
        final profile = AgentConnectionProfile.local(
          port: address.port,
          deviceToken: j['deviceToken'] as String,
          libraryId: j['serverId'] as String,
        );
        if (address != profile.address || j['certificate'] != '')
          throw const FormatException();
        return profile;
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
    if (Platform.isWindows) {
      try {
        if (!file.isAbsolute) throw const FormatException();
        final value = WindowsPrivateFiles.readSecret(file);
        if (value == null) throw const FormatException();
        return AgentConnectionProfile.fromPrivateJson(
          decodeProtocolObject(value, maxBytes: 131072),
        );
      } on Object {
        throw const FormatException('Invalid private Agent connection');
      }
    }
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
    if (Platform.isWindows) {
      try {
        final file = File('${directory.absolute.path}/agent-connection.json');
        WindowsPrivateFiles.writeSecret(file, jsonEncode(toPrivateJson()));
        return file;
      } on Object {
        throw const FormatException('Private storage unavailable');
      }
    }
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
  // A durable NAS request may queue behind writes; this is a response deadline,
  // independent of approval expiry and explicitly bounded lifecycle calls.
  static const defaultRequestTimeout = Duration(seconds: 15);
  AgentConnection(this.profile)
    : _http = serverHttpClient(
        certificate: profile.certificate,
        trust: profile.trust,
      )..connectionTimeout = const Duration(seconds: 5);
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
    Duration timeout = defaultRequestTimeout,
  }) async {
    if (_serverChanged) return {'status': 'server_changed'};
    if (_closed) return {'status': 'service_unavailable'};
    if (!RegExp(r'^/[a-z0-9-]+(?:/[a-z0-9-]+)*$').hasMatch(path))
      return {'status': 'invalid_request'};
    HttpClientRequest? active;
    var expired = false;
    try {
      return await (() async {
        final request = active = await _http.postUrl(
          profile.address.resolve(profile.isLocal ? path : '/v1/agent$path'),
        );
        if (expired) {
          request.abort();
          throw TimeoutException('Request expired');
        }
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
          if (path.startsWith('/information-file/')) {
            final failure = InformationFileFailure.fromResponse(result);
            if (failure != null)
              return Map<String, dynamic>.from(failure.toJson());
          }
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
      })().timeout(
        timeout,
        onTimeout: () {
          expired = true;
          active?.abort();
          return <String, dynamic>{'status': 'service_unavailable'};
        },
      );
    } on Object {
      return {'status': 'service_unavailable'};
    }
  }
}
