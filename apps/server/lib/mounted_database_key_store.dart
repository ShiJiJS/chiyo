import 'dart:io';
import 'package:info_storage/info_storage.dart';

/// Reads a separately provisioned secret mount. Losing a mount must never
/// silently generate a replacement key for an existing encrypted library.
final class MountedDatabaseKeyStore implements DatabaseKeyStore {
  const MountedDatabaseKeyStore(this.path);
  final String path;

  @override
  Future<List<int>?> read() async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const StorageFailure('key_provider_unavailable');
    }
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const StorageFailure('key_unavailable');
      }
      final file = File(path);
      final stat = await file.stat();
      // Refuse group/other access, special permission bits and non-key files.
      if ((stat.mode & 0xE3F) != 0 || stat.size != 32) {
        throw const StorageFailure('invalid_key');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != 32) throw const StorageFailure('invalid_key');
      return bytes;
    } on FileSystemException {
      throw const StorageFailure('key_unavailable');
    }
  }

  @override
  Future<void> create(List<int> key) async {
    // Provisioning is explicit, independent of database startup and images.
    throw const StorageFailure('key_unavailable');
  }
}
