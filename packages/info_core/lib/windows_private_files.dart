part of 'runtime_material_files.dart';

/// Current-user device storage. Reuses the credential material handle/DACL
/// checks; reparse points, hard-linked files and permissive files are rejected.
/// Same-user processes are trusted, consistently with ADR0002.
final class WindowsPrivateFiles {
  static final _files = _WindowsMaterialFiles();
  static const _header = [73, 65, 80, 1]; // IAP, current-user DPAPI v1

  static void _supported() {
    if (!Platform.isWindows) {
      throw const RuntimeMaterialFailure('unsupported');
    }
  }

  static void _canonical(String path) {
    final absolute = File(path).absolute.path.replaceAll('/', '\\');
    final resolved = FileSystemEntity.isDirectorySync(path)
        ? Directory(path).resolveSymbolicLinksSync()
        : File(path).resolveSymbolicLinksSync();
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(absolute) ||
        resolved.replaceAll('/', '\\').toLowerCase() !=
            absolute.toLowerCase()) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
  }

  /// Adopt an existing application directory, or create it with a private
  /// descriptor from birth. No secret is written before verification completes.
  static Directory directory(Directory folder) {
    _supported();
    folder = folder.absolute;
    if (FileSystemEntity.typeSync(folder.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      folder.parent.createSync(recursive: true);
      try {
        _files.createDirectory(folder.path);
      } on RuntimeMaterialFailure {
        // A concurrent first launch may have won creation. Verify below.
        if (FileSystemEntity.typeSync(folder.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          rethrow;
        }
      }
    }
    _protect(folder.path, directory: true);
    return Directory(folder.resolveSymbolicLinksSync());
  }

  static void _protect(String path, {bool directory = false}) {
    _canonical(path);
    final name = path.toNativeUtf16();
    var handle = -1;
    try {
      handle = _files._open(
        name,
        0x60080,
        7,
        nullptr,
        3,
        0x00200000 | (directory ? 0x02000000 : 0),
        0,
      );
      if (handle == -1) throw const RuntimeMaterialFailure('permissions');
      // Validate the object before changing its descriptor, using the handle
      // with OPEN_REPARSE_POINT rather than following a substituted path.
      _files.identity(handle, directory: directory, checkPermissions: false);
      _files._withSecurity(directory, (attributes) {
        final set = _files.security
            .lookupFunction<
              Int32 Function(IntPtr, Uint32, Pointer<Void>),
              int Function(int, int, Pointer<Void>)
            >('SetKernelObjectSecurity');
        if (set(handle, 0x80000004, attributes.ref.descriptor) == 0) {
          throw const RuntimeMaterialFailure('permissions');
        }
      });
      _files.identity(handle, directory: directory);
    } finally {
      if (handle != -1) _files.close(handle);
      calloc.free(name);
    }
  }

  static void verify(String path, {bool directory = false}) {
    _supported();
    _canonical(path);
    final handle = _files.open(path, directory: directory, shared: true);
    try {
      _files.identity(handle, directory: directory);
    } finally {
      _files.close(handle);
    }
  }

  /// A publisher may retain the private original plus one publication link.
  /// This keeps the same protected current-user/SYSTEM descriptor checks;
  /// ordinary state/material reads still reject every hard-linked file.
  static void verifyPublicationHandle(int handle, {bool directory = false}) {
    _supported();
    // The publisher owns/pins this handle and checks its canonical binding.
    // Validate that exact object, including a directory pending deletion,
    // without reopening its name or changing Windows sharing guarantees.
    _files.identity(
      handle,
      directory: directory,
      allowPublicationLink: !directory,
    );
  }

  /// Reserve a private regular file without truncating an existing one.
  static void reserve(File file) {
    _supported();
    verify(file.parent.path, directory: true);
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      try {
        final handle = _files.createFile(file.path);
        _files.close(handle);
      } on RuntimeMaterialFailure {
        // A concurrent creator is accepted only after identity/DACL checks.
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          rethrow;
        }
      }
    }
    verify(file.path);
  }

  static List<int>? read(File file, {int maxBytes = 262144}) {
    _supported();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return null;
    }
    verify(file.parent.path, directory: true);
    _canonical(file.path);
    final name = file.path.toNativeUtf16();
    final handle = _files._open(name, 0x80020080, 7, nullptr, 3, 0x00200000, 0);
    calloc.free(name);
    if (handle == -1) throw const RuntimeMaterialFailure('read_failed');
    final data = calloc<Uint8>(maxBytes + 1), count = calloc<Uint32>();
    try {
      _files.identity(handle);
      final read = _files.kernel
          .lookupFunction<
            Int32 Function(
              IntPtr,
              Pointer<Uint8>,
              Uint32,
              Pointer<Uint32>,
              Pointer<Void>,
            ),
            int Function(
              int,
              Pointer<Uint8>,
              int,
              Pointer<Uint32>,
              Pointer<Void>,
            )
          >('ReadFile');
      if (read(handle, data, maxBytes + 1, count, nullptr) == 0 ||
          count.value > maxBytes) {
        throw const RuntimeMaterialFailure('read_failed');
      }
      return List<int>.from(data.asTypedList(count.value));
    } finally {
      data.asTypedList(maxBytes + 1).fillRange(0, maxBytes + 1, 0);
      calloc.free(data);
      calloc.free(count);
      _files.close(handle);
    }
  }

  /// Flush a private sibling and atomically publish it. Never delete the old
  /// destination as a fallback: sharing violations leave its original intact.
  static void write(File file, List<int> bytes, {bool replace = true}) {
    _supported();
    directory(file.parent);
    final parent = _files.open(file.parent.path, directory: true);
    final nonce = List.generate(24, (_) => Random.secure().nextInt(256));
    final stage = File(
      '${file.parent.path}/.private-${base64Url.encode(nonce)}',
    );
    var created = false;
    try {
      _files.identity(parent, directory: true);
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        verify(file.path);
      }
      final handle = _files.createFile(stage.path);
      created = true;
      try {
        _files.identity(handle);
        _files.writeEmpty(handle, bytes);
      } finally {
        _files.close(handle);
      }
      final source = stage.path.toNativeUtf16(),
          target = file.path.toNativeUtf16();
      try {
        final lastError = _files._lastError;
        final move = _files.kernel
            .lookupFunction<
              Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
              int Function(Pointer<Utf16>, Pointer<Utf16>, int)
            >('MoveFileExW');
        final publication = Stopwatch()..start();
        while (move(source, target, 8 | (replace ? 1 : 0)) == 0) {
          // Concurrent NTFS replacements can briefly deny delete access even
          // when all readers share deletion. Retry only this original atomic
          // publication, never remove the destination or stage new contents.
          final error = lastError();
          if (!const {5, 32, 33}.contains(error) ||
              publication.elapsed >= const Duration(milliseconds: 500)) {
            throw const RuntimeMaterialFailure('write_failed');
          }
          sleep(const Duration(milliseconds: 10));
          if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            verify(file.path);
          }
        }
        created = false;
      } finally {
        calloc.free(source);
        calloc.free(target);
      }
    } finally {
      _files.close(parent);
      if (created) stage.deleteSync();
    }
  }

  static String? readSecret(File file) {
    final bytes = read(file);
    if (bytes == null) return null;
    if (bytes.length < 5 ||
        List.generate(4, (i) => bytes[i] != _header[i]).contains(true)) {
      throw const RuntimeMaterialFailure('invalid_private_state');
    }
    return utf8.decode(
      WindowsDataProtection.crypt(bytes.sublist(4), protect: false),
    );
  }

  static void writeSecret(File file, String value, {bool replace = true}) =>
      write(file, [
        ..._header,
        ...WindowsDataProtection.crypt(utf8.encode(value), protect: true),
      ], replace: replace);
}

final class _PrivateDataBlob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

/// Current-user DPAPI, shared by device profiles and database keys. The native
/// buffers are cleared and UI is forbidden; this is not a portable backup.
final class WindowsDataProtection {
  static List<int> crypt(List<int> input, {required bool protect}) {
    if (!Platform.isWindows || input.isEmpty) {
      throw const RuntimeMaterialFailure('private_state_unavailable');
    }
    final call = DynamicLibrary.open('crypt32.dll')
        .lookupFunction<
          Int32 Function(
            Pointer<_PrivateDataBlob>,
            Pointer<Void>,
            Pointer<_PrivateDataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            Uint32,
            Pointer<_PrivateDataBlob>,
          ),
          int Function(
            Pointer<_PrivateDataBlob>,
            Pointer<Void>,
            Pointer<_PrivateDataBlob>,
            Pointer<Void>,
            Pointer<Void>,
            int,
            Pointer<_PrivateDataBlob>,
          )
        >(protect ? 'CryptProtectData' : 'CryptUnprotectData');
    final source = calloc<_PrivateDataBlob>(),
        output = calloc<_PrivateDataBlob>();
    final data = calloc<Uint8>(input.length);
    source.ref
      ..length = input.length
      ..data = data;
    data.asTypedList(input.length).setAll(0, input);
    try {
      if (call(source, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
        throw const RuntimeMaterialFailure('private_state_unavailable');
      }
      return List<int>.from(output.ref.data.asTypedList(output.ref.length));
    } finally {
      data.asTypedList(input.length).fillRange(0, input.length, 0);
      calloc.free(data);
      calloc.free(source);
      if (output.ref.data != nullptr) {
        output.ref.data
            .asTypedList(output.ref.length)
            .fillRange(0, output.ref.length, 0);
        WindowsPrivateFiles._files.free(output.ref.data.cast());
      }
      calloc.free(output);
    }
  }
}
