import 'dart:io';
import 'dart:typed_data';
import 'package:info_core/info_core.dart';
import 'info_storage.dart';

/// Current-user DPAPI; no LOCAL_MACHINE flag, prompt, or process command arguments.
/// The versioned envelope is NOT a portable backup.
class WindowsDatabaseKeyStore implements DatabaseKeyStore {
  WindowsDatabaseKeyStore(this.path, {this.privateFile = false});
  final String path;
  final bool privateFile;
  static const _header = <int>[73, 65, 75, 1]; // IAK, format version 1

  Uint8List _crypt(List<int> input, {required bool protect}) {
    if (!Platform.isWindows)
      throw const StorageFailure('key_provider_unavailable');
    try {
      return Uint8List.fromList(
        WindowsDataProtection.crypt(input, protect: protect),
      );
    } on Object {
      throw const StorageFailure('key_unavailable');
    }
  }

  @override
  Future<List<int>?> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = privateFile
          ? WindowsPrivateFiles.read(file)
          : await file.readAsBytes();
      if (bytes == null) return null;
      if (bytes.length < 5 ||
          List.generate(4, (i) => bytes[i] != _header[i]).contains(true)) {
        throw const StorageFailure('key_unavailable');
      }
      final key = _crypt(bytes.sublist(4), protect: false);
      if (key.length != 32) throw const StorageFailure('key_unavailable');
      return key;
    } catch (_) {
      throw const StorageFailure('key_unavailable');
    }
  }

  @override
  Future<void> create(List<int> key) async {
    if (key.length != 32) throw const StorageFailure('invalid_key');
    final file = File(path);
    try {
      if (privateFile) {
        WindowsPrivateFiles.write(file, [
          ..._header,
          ..._crypt(key, protect: true),
        ], replace: false);
        return;
      }
      await file.parent.create(recursive: true);
      // Database open holds the library lock across creation/readback. Exclusive
      // file creation additionally prevents replacing an existing envelope.
      await file.create(exclusive: true);
      await file.writeAsBytes([
        ..._header,
        ..._crypt(key, protect: true),
      ], flush: true);
    } catch (_) {
      throw const StorageFailure('key_creation_failed');
    }
  }
}

/// The Flutter adapter supplies a native Security.framework method channel.
/// No key is passed to a shell or shared with the agent transport.
class MacOsDatabaseKeyStore implements DatabaseKeyStore {
  MacOsDatabaseKeyStore(this.invoke);

  factory MacOsDatabaseKeyStore.forLibrary(
    String libraryId,
    Future<Object?> Function(String method, Object? arguments) invoke, {
    bool requestKeyAccess = false,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(libraryId)) {
      throw const StorageFailure('invalid_key');
    }
    return MacOsDatabaseKeyStore(
      (method, value) => invoke(
        method == 'create'
            ? 'createLocal'
            : requestKeyAccess
            ? 'readLocalWithInteraction'
            : 'readLocal',
        {'libraryId': libraryId, if (method == 'create') 'key': value},
      ),
    );
  }

  final Future<Object?> Function(String method, Object? arguments) invoke;
  @override
  Future<List<int>?> read() async {
    try {
      final result = await invoke('read', null);
      if (result == null) return null;
      if (result is! Uint8List || result.length != 32)
        throw const StorageFailure('key_unavailable');
      return result;
    } catch (_) {
      throw const StorageFailure('key_unavailable');
    }
  }

  @override
  Future<void> create(List<int> key) async {
    if (key.length != 32) throw const StorageFailure('invalid_key');
    try {
      await invoke('create', Uint8List.fromList(key));
    } catch (_) {
      throw const StorageFailure('key_creation_failed');
    }
  }
}
