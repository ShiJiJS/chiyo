import 'dart:io';
import 'dart:math';
import 'package:info_storage/info_storage.dart';

/// Only new empty installations may generate identities. Existing data never
/// causes a missing database key or TLS identity to be silently replaced.
Future<void> prepareServerIdentity({
  required String dataDirectory,
  required String secretsDirectory,
  required String certificate,
  required String privateKey,
  required Future<void> Function(String) initializeSecrets,
}) async {
  final databaseExists =
      await FileSystemEntity.type(
        '$dataDirectory/library.db',
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;
  final secretsType = await FileSystemEntity.type(
    secretsDirectory,
    followLinks: false,
  );
  if (secretsType == FileSystemEntityType.notFound) {
    if (databaseExists) throw const StorageFailure('key_unavailable');
    await Directory(secretsDirectory).parent.create(recursive: true);
    await initializeSecrets(secretsDirectory);
  } else if (secretsType != FileSystemEntityType.directory) {
    throw const StorageFailure('key_unavailable');
  }
  for (final name in ['database.key', 'owner.token', 'server.id']) {
    if (await FileSystemEntity.type(
          '$secretsDirectory/$name',
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      throw const StorageFailure('key_unavailable');
    }
  }
  final certificateType = await FileSystemEntity.type(
    certificate,
    followLinks: false,
  );
  final keyType = await FileSystemEntity.type(privateKey, followLinks: false);
  if (certificateType == FileSystemEntityType.file &&
      keyType == FileSystemEntityType.file)
    return;
  if (databaseExists ||
      certificateType != FileSystemEntityType.notFound ||
      keyType != FileSystemEntityType.notFound) {
    throw const StorageFailure('tls_identity_unavailable');
  }
  await File(certificate).parent.create(recursive: true);
  await File(privateKey).parent.create(recursive: true);
  final temporary = Directory(
    '$secretsDirectory/.tls-${Random.secure().nextInt(1 << 32)}',
  );
  await temporary.create();
  try {
    if ((await Process.run('/bin/chmod', ['700', temporary.path])).exitCode !=
        0)
      throw const StorageFailure('key_unavailable');
    final config = File('${temporary.path}/openssl.cnf');
    await config.writeAsString(
      '[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=server\n[dn]\nCN=Chiyo Server\n[server]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n',
    );
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:3072',
      '-nodes',
      '-sha256',
      '-days',
      '3650',
      '-config',
      config.path,
      '-keyout',
      '${temporary.path}/server.key',
      '-out',
      '${temporary.path}/server.pem',
    ]);
    if (generated.exitCode != 0)
      throw const StorageFailure('tls_initialization_failed');
    if ((await Process.run('/bin/chmod', [
          '600',
          '${temporary.path}/server.key',
          '${temporary.path}/server.pem',
        ])).exitCode !=
        0) {
      throw const StorageFailure('key_unavailable');
    }
    await File('${temporary.path}/server.key').rename(privateKey);
    await File('${temporary.path}/server.pem').rename(certificate);
  } finally {
    await temporary.delete(recursive: true);
  }
}
