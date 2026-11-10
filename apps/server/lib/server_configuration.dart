import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:info_storage/info_storage.dart';
import 'mounted_database_key_store.dart';

/// Paths are resolved against this explicit configuration file, never against
/// a desktop profile or the process's working directory.
final class ServerConfiguration {
  ServerConfiguration._(
    this.dataDirectory,
    this.databaseKeyFile,
    this.ownerToken,
    this.serverId,
    this.tls,
    this.address,
    this.port,
    this.readCacheMiB,
  );
  final String dataDirectory, databaseKeyFile, ownerToken, serverId;
  final SecurityContext tls;
  final InternetAddress address;
  final int port, readCacheMiB;

  static Future<ServerConfiguration> read(String configPath) async {
    final file = File(configPath).absolute;
    final input = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (input.keys.toSet().difference(const {
      'dataDirectory',
      'secretsDirectory',
      'tlsCertificate',
      'tlsPrivateKey',
      'address',
      'port',
      'readCacheMiB',
    }).isNotEmpty)
      throw const FormatException('Unknown configuration');
    String resolve(String name) {
      final path = input[name] as String;
      if (path.isEmpty) throw const FormatException('Missing path');
      return file.parent.uri.resolve(path).toFilePath();
    }

    final cache = input.containsKey('readCacheMiB')
        ? input['readCacheMiB']
        : 128;
    if (cache is! int || cache < 32 || cache > 512) {
      throw const FormatException('Invalid readCacheMiB (32..512)');
    }
    final secrets = resolve('secretsDirectory');
    String encode(List<int> bytes) =>
        base64Url.encode(bytes).replaceAll('=', '');
    final ownerToken = encode(
      await MountedDatabaseKeyStore('$secrets/owner.token').read() ?? [],
    );
    final serverId = encode(
      await MountedDatabaseKeyStore('$secrets/server.id').read() ?? [],
    );
    final privateKey = await readPrivateFile(
      resolve('tlsPrivateKey'),
      maxBytes: 65536,
    );
    final tls = SecurityContext()
      ..useCertificateChain(resolve('tlsCertificate'))
      ..usePrivateKeyBytes(privateKey);
    final address = InternetAddress(input['address'] as String? ?? '127.0.0.1');
    final port = input['port'] as int? ?? 47126;
    if (port < 0 || port > 65535) throw const FormatException('Invalid port');
    return ServerConfiguration._(
      resolve('dataDirectory'),
      '$secrets/database.key',
      ownerToken,
      serverId,
      tls,
      address,
      port,
      cache,
    );
  }
}

Future<List<int>> readPrivateFile(String path, {required int maxBytes}) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const StorageFailure('key_unavailable');
  }
  final file = File(path);
  final stat = await file.stat();
  if ((stat.mode & 0xE3F) != 0 || stat.size == 0 || stat.size > maxBytes) {
    throw const StorageFailure('invalid_key');
  }
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty || bytes.length > maxBytes)
    throw const StorageFailure('invalid_key');
  return bytes;
}

/// Explicit one-time provisioning only. The directory must not exist, so
/// repeated initialization cannot replace any existing key or server identity.
Future<void> initializeServerSecrets(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS) {
    throw const StorageFailure('key_provider_unavailable');
  }
  // mkdir is atomic and refuses even an empty existing directory or symlink.
  final result = await Process.run('mkdir', ['-m', '700', path]);
  if (result.exitCode != 0) throw const StorageFailure('secrets_already_exist');
  for (final name in ['database.key', 'owner.token', 'server.id']) {
    final file = File('$path/$name');
    await file.create(exclusive: true);
    if ((await Process.run('chmod', ['600', file.path])).exitCode != 0) {
      throw const StorageFailure('key_unavailable');
    }
    final random = Random.secure();
    await file.writeAsBytes(
      List.generate(32, (_) => random.nextInt(256)),
      flush: true,
    );
  }
}
