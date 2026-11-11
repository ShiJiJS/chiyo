import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:info_core/protocol_json.dart';
import 'owner_client.dart';

/// Private configuration only. Windows secrets use current-user DPAPI; POSIX
/// files are staged under a private directory and atomically renamed.
abstract final class PrivateConnectionFiles {
  static Future<Map<String, dynamic>?> read(File file) async {
    try {
      if (Platform.isWindows) {
        final value = WindowsPrivateFiles.readSecret(file);
        return value == null
            ? null
            : decodeProtocolObject(value, maxBytes: 131072);
      }
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      final stat = await file.stat();
      if (await FileSystemEntity.type(file.parent.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          (await file.parent.stat()).mode & 0xE3F != 0 ||
          type != FileSystemEntityType.file ||
          stat.mode & 0xE3F != 0 ||
          stat.size > 131072) {
        throw const RemoteFailure('invalid_profile');
      }
      return decodeProtocolObject(await file.readAsString(), maxBytes: 131072);
    } on Object {
      throw const RemoteFailure('invalid_profile');
    }
  }

  static Future<void> write(
    File target,
    Map<String, Object?> value, {
    bool replace = true,
  }) async {
    if (Platform.isWindows) {
      try {
        WindowsPrivateFiles.writeSecret(
          target,
          jsonEncode(value),
          replace: replace,
        );
        return;
      } on Object {
        throw const RemoteFailure('profile_store_unavailable');
      }
    }
    final folder = target.absolute.parent;
    final type = await FileSystemEntity.type(folder.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const RemoteFailure('invalid_profile');
    }
    await folder.create(recursive: true);
    if ((await Process.run('chmod', ['700', folder.path])).exitCode != 0) {
      throw const RemoteFailure('profile_store_unavailable');
    }
    final staging = await folder.createTemp('.connection-');
    try {
      if ((await Process.run('chmod', ['700', staging.path])).exitCode != 0) {
        throw const RemoteFailure('profile_store_unavailable');
      }
      final file = File('${staging.path}/profile');
      await file.create(exclusive: true);
      if ((await Process.run('chmod', ['600', file.path])).exitCode != 0) {
        throw const RemoteFailure('profile_store_unavailable');
      }
      await file.writeAsString(jsonEncode(value), flush: true);
      if (replace) {
        await file.rename(target.absolute.path);
      } else {
        // A hard link publishes the fully flushed file only if no other first
        // launch has already created this identity. Removing staging leaves
        // the single durable target; a rename could overwrite the winner.
        if (await FileSystemEntity.type(target.path, followLinks: false) !=
                FileSystemEntityType.notFound ||
            (await Process.run('ln', [
                  file.path,
                  target.absolute.path,
                ])).exitCode !=
                0) {
          throw const RemoteFailure('profile_store_unavailable');
        }
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
