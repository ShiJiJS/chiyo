import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'owner_client.dart';

final class ConnectionProfile {
  const ConnectionProfile({
    required this.address,
    required this.token,
    required this.serverId,
    this.certificate = '',
  });
  final String address, token, serverId, certificate;
  Map<String, Object?> toJson() => {
    'address': address,
    'token': token,
    'serverId': serverId,
    'certificate': certificate,
  };
  factory ConnectionProfile.fromJson(Map<String, dynamic> value) =>
      ConnectionProfile(
        address: value['address'] as String,
        token: value['token'] as String,
        serverId: value['serverId'] as String,
        certificate: value['certificate'] as String? ?? '',
      );
}

abstract interface class ConnectionProfileStore {
  Future<ConnectionProfile?> read();
  Future<void> save(ConnectionProfile profile);
}

/// Dedicated private configuration, distinct from user information and shared
/// preferences. Same-user processes remain trusted, as on the existing host.
/// Windows uses current-user DPAPI and private handle-verified files. POSIX
/// keeps its existing private JSON format.
final class PrivateConnectionProfileStore implements ConnectionProfileStore {
  const PrivateConnectionProfileStore(this.directory);
  final String directory;
  Future<void> _supported() async {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows)
      throw const RemoteFailure('profile_store_unavailable');
  }

  @override
  Future<ConnectionProfile?> read() async {
    await _supported();
    final file = File('$directory/connection.json');
    if (Platform.isWindows) {
      try {
        final value = WindowsPrivateFiles.readSecret(file);
        if (value == null) return null;
        return ConnectionProfile.fromJson(
          decodeProtocolObject(value, maxBytes: 131072),
        );
      } on Object {
        throw const RemoteFailure('invalid_profile');
      }
    }
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    final stat = await file.stat();
    if (type != FileSystemEntityType.file ||
        stat.mode & 0xE3F != 0 ||
        stat.size > 131072) {
      throw const RemoteFailure('invalid_profile');
    }
    return ConnectionProfile.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> save(ConnectionProfile profile) async {
    await _supported();
    if (Platform.isWindows) {
      try {
        WindowsPrivateFiles.writeSecret(
          File('$directory/connection.json'),
          jsonEncode(profile.toJson()),
        );
        return;
      } on Object {
        throw const RemoteFailure('profile_store_unavailable');
      }
    }
    final folder = Directory(directory).absolute;
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory)
      throw const RemoteFailure('invalid_profile');
    await folder.create(recursive: true);
    if ((await Process.run('chmod', ['700', folder.path])).exitCode != 0)
      throw const RemoteFailure('profile_store_unavailable');
    final staging = await folder.createTemp('.connection-');
    try {
      if ((await Process.run('chmod', ['700', staging.path])).exitCode != 0)
        throw const RemoteFailure('profile_store_unavailable');
      final file = File('${staging.path}/profile');
      await file.create(exclusive: true);
      if ((await Process.run('chmod', ['600', file.path])).exitCode != 0)
        throw const RemoteFailure('profile_store_unavailable');
      await file.writeAsString(jsonEncode(profile.toJson()), flush: true);
      await file.rename('${folder.path}/connection.json');
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
