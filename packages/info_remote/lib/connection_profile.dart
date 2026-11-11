import 'dart:io';
import 'owner_client.dart';
import 'automatic_connection.dart';
import 'private_connection_files.dart';

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
    final value =
        await AutomaticConnectionStore(directory).readOwner() ??
        await PrivateConnectionFiles.read(File('$directory/connection.json'));
    return value == null ? null : ConnectionProfile.fromJson(value);
  }

  @override
  Future<void> save(ConnectionProfile profile) async {
    await _supported();
    final active = AutomaticConnectionStore(directory);
    if (await active.readOwner() != null) {
      await active.publish(profile.toJson(), null);
    } else {
      await PrivateConnectionFiles.write(
        File('$directory/connection.json'),
        profile.toJson(),
      );
    }
  }

  Future<void> saveConnected(
    ConnectionProfile profile,
    OwnerClient client,
  ) async {
    await _supported();
    await AutomaticConnectionStore(directory).connect(client, profile.toJson());
  }
}
