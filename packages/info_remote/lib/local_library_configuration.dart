import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_connection.dart';
import 'automatic_connection.dart';
import 'owner_client.dart';
import 'private_connection_files.dart';

String _randomToken(int length) => base64Url
    .encode(List.generate(length, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

/// Persistent identity for one encrypted local library. An active CLI proof
/// belongs to one running host and is replaced only after that host is ready.
final class LocalLibraryConfiguration {
  LocalLibraryConfiguration._(this.directory, this.libraryId);
  final String directory, libraryId;
  String get libraryDirectory => '$directory/local';
  String get serverId => 'local-$libraryId';

  static Future<LocalLibraryConfiguration> open(String directory) async {
    final local = Directory('$directory/local');
    final type = await FileSystemEntity.type(local.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const RemoteFailure('invalid_profile');
    }
    final file = File('$directory/local-library.json');
    var identity = await PrivateConnectionFiles.read(file);
    if (identity == null) {
      if (await local.exists() && !(await local.list().isEmpty)) {
        throw const RemoteFailure('local_identity_missing');
      }
      identity = {'version': 1, 'libraryId': _randomToken(24)};
      try {
        await PrivateConnectionFiles.write(file, identity, replace: false);
      } on RemoteFailure {
        // Concurrent first launches must agree on the identity already
        // published, rather than selecting different system keys for one DB.
        identity = await PrivateConnectionFiles.read(file);
        if (identity == null) rethrow;
      }
    }
    if (identity.length != 2 ||
        identity['version'] != 1 ||
        identity['libraryId'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_-]{32}$',
        ).hasMatch(identity['libraryId'] as String)) {
      throw const RemoteFailure('invalid_profile');
    }
    return LocalLibraryConfiguration._(
      Directory(directory).absolute.path,
      identity['libraryId'] as String,
    );
  }

  AgentConnectionProfile connection(int port) => AgentConnectionProfile.local(
    port: port,
    deviceToken: '${_randomToken(16)}.${_randomToken(32)}',
    libraryId: serverId,
  );

  Future<void> publish(AgentConnectionProfile connection) async {
    if (!connection.isLocal || connection.serverId != serverId) {
      throw const RemoteFailure('invalid_profile');
    }
    await AutomaticConnectionStore(
      directory,
    ).publish({'mode': 'local', 'libraryId': libraryId}, connection);
    // Compatibility entry for already-installed integrations. Immutable chat
    // associations keep their own original connection; this affects new chats.
    await connection.saveIn(Directory(directory));
  }
}
