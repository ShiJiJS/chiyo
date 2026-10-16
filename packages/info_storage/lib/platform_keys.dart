import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'info_storage.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

typedef _ProtectNative =
    Int32 Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_Blob>,
    );
typedef _Protect =
    int Function(
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_Blob>,
    );

/// Current-user DPAPI; no LOCAL_MACHINE flag, prompt, or process command arguments.
/// The versioned envelope is NOT a portable backup.
class WindowsDatabaseKeyStore implements DatabaseKeyStore {
  WindowsDatabaseKeyStore(this.path);
  final String path;
  static const _header = <int>[73, 65, 75, 1]; // IAK, format version 1

  Uint8List _crypt(List<int> input, {required bool protect}) {
    if (!Platform.isWindows)
      throw const StorageFailure('key_provider_unavailable');
    final crypt = DynamicLibrary.open('Crypt32.dll');
    final kernel = DynamicLibrary.open('Kernel32.dll');
    final call = crypt.lookupFunction<_ProtectNative, _Protect>(
      protect ? 'CryptProtectData' : 'CryptUnprotectData',
    );
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final source = calloc<_Blob>();
    final output = calloc<_Blob>();
    final data = calloc<Uint8>(input.length);
    data.asTypedList(input.length).setAll(0, input);
    source.ref
      ..length = input.length
      ..data = data;
    try {
      // CRYPTPROTECT_UI_FORBIDDEN: fail rather than display a native dialog.
      if (call(source, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
        throw const StorageFailure('key_unavailable');
      }
      return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
    } finally {
      data.asTypedList(input.length).fillRange(0, input.length, 0);
      calloc.free(data);
      calloc.free(source);
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        localFree(output.ref.data.cast());
      }
      calloc.free(output);
    }
  }

  @override
  Future<List<int>?> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
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
