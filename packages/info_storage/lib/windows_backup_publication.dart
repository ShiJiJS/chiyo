part of 'macos_backup_publication.dart';

/// Windows counterpart of the retained-original publisher. All deletions are
/// by verified handles inside registered staging, never recursive/output paths.
final class _WindowsPublicationFiles {
  static final _native = _WindowsPublicationNative();
  static (String, String) path(String value) {
    final normalized = value.replaceAll('/', r'\');
    if (normalized.length > 32768 ||
        normalized.contains('\x00') ||
        !RegExp(r'^[A-Za-z]:\\').hasMatch(normalized)) {
      throw const BackupPublicationFailure('invalid_path');
    }
    final segments = normalized.substring(3).split(r'\');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.length > 255 ||
          segment.endsWith('.') ||
          segment.endsWith(' ') ||
          RegExp(r'[\x00-\x1f:*?"<>|]').hasMatch(segment) ||
          RegExp(
            r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
            caseSensitive: false,
          ).hasMatch(segment),
    )) {
      throw const BackupPublicationFailure('invalid_path');
    }
    final split = normalized.lastIndexOf(r'\');
    return (
      normalized.substring(0, split == 2 ? 3 : split),
      normalized.substring(split + 1),
    );
  }

  static T _guard<T>(T Function() action) {
    if (!Platform.isWindows)
      throw const BackupPublicationFailure('unsupported_platform');
    try {
      return action();
    } on BackupPublicationFailure {
      rethrow;
    } on Object {
      throw const BackupPublicationFailure('publication_io_failed');
    }
  }

  static MacBackupStagingDirectory createStaging(String destination) =>
      _guard(() {
        final (parent, _) = path(destination);
        final parentHandle = _native.open(parent, directory: true);
        try {
          final nonce = List.generate(
            24,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          final folder = Directory(
            '$parent${Platform.pathSeparator}info-output-$nonce',
          );
          if (FileSystemEntity.typeSync(folder.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const BackupPublicationFailure('staging_not_empty');
          }
          WindowsPrivateFiles.directory(folder);
          return captureStaging(folder.path);
        } finally {
          _native.close(parentHandle);
        }
      });
  static MacBackupStagingDirectory captureStaging(String directory) =>
      _guard(() {
        final (parent, _) = path(directory);
        final from = _native.open(directory, directory: true, private: true);
        var parentHandle = -1;
        try {
          parentHandle = _native.open(parent, directory: true);
          if (Directory(directory).listSync(followLinks: false).isNotEmpty) {
            throw const BackupPublicationFailure('staging_not_empty');
          }
          return MacBackupStagingDirectory._(
            directory,
            _native.identity(from),
            _native.identity(parentHandle),
          );
        } finally {
          _native.close(parentHandle);
          _native.close(from);
        }
      });
  static bool stagingExists(MacBackupStagingDirectory value) => _guard(() {
    final (parent, _) = path(value.path);
    final parentHandle = _native.open(parent, directory: true);
    var directory = -1;
    try {
      if (_native.identity(parentHandle) != value.parentIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      directory = _native.open(
        value.path,
        directory: true,
        private: true,
        missing: true,
      );
      if (directory < 0) return false;
      if (_native.identity(directory) != value.identity)
        throw const BackupPublicationFailure('identity_changed');
      return true;
    } finally {
      _native.close(directory);
      _native.close(parentHandle);
    }
  });
  static void writePrivate(String file, List<int> bytes) => _guard(() {
    path(file);
    WindowsPrivateFiles.write(File(file), bytes, replace: false);
  });
  static MacBackupPublication prepare(String source, String destination) =>
      _guard(() {
        final (sourceParent, sourceName) = path(source);
        final (targetParent, _) = path(destination);
        if (_native.samePath(source, destination) ||
            _native.samePath('$source.publish', destination) ||
            sourceName.length > 240) {
          throw const BackupPublicationFailure('invalid_publication');
        }
        final from = _native.open(sourceParent, directory: true, private: true);
        var target = -1, file = -1;
        try {
          target = _native.open(targetParent, directory: true);
          if (_native.volume(from) != _native.volume(target))
            throw const BackupPublicationFailure('different_volume');
          file = _native.open(
            source,
            private: true,
            singleLink: true,
            writing: true,
          );
          final identity = _native.identity(file),
              content = _native.content(file);
          _native.flush(file);
          return MacBackupPublication._(
            source,
            destination,
            identity,
            _native.identity(from),
            _native.identity(target),
            content.$1,
            content.$2,
          );
        } finally {
          _native.close(file);
          _native.close(target);
          _native.close(from);
        }
      });
  static T _with<T>(MacBackupPublication value, T Function() action) =>
      _guard(() {
        final (sourceParent, _) = path(value.source);
        final (targetParent, _) = path(value.destination);
        final from = _native.open(sourceParent, directory: true, private: true);
        var target = -1;
        try {
          target = _native.open(targetParent, directory: true);
          if (_native.identity(from) != value.sourceDirectoryIdentity ||
              _native.identity(target) != value.destinationDirectoryIdentity ||
              _native.volume(from) != _native.volume(target)) {
            throw const BackupPublicationFailure('identity_changed');
          }
          return action();
        } finally {
          _native.close(target);
          _native.close(from);
        }
      });
  static void _verify(
    String path,
    MacBackupPublication value, {
    bool singleLink = false,
  }) {
    final handle = _native.open(path, private: true, singleLink: singleLink);
    try {
      if (_native.identity(handle) != value.sourceIdentity ||
          _native.content(handle) != (value.bytes, value.digest)) {
        throw const BackupPublicationFailure('prepared_file_changed');
      }
    } finally {
      _native.close(handle);
    }
  }

  static void verifyPrepared(MacBackupPublication value) =>
      _with(value, () => _verify(value.source, value));
  static void publish(MacBackupPublication value) => _with(value, () {
    _verify(value.source, value, singleLink: true);
    if (FileSystemEntity.typeSync(value.destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const BackupPublicationFailure('publish_failed');
    }
    final pending = '${value.source}.publish';
    _native.link(value.source, pending);
    _verify(pending, value);
    // No REPLACE_EXISTING or COPY_ALLOWED. The private source remains as the
    // original identity anchor until the caller durably records success.
    _native.move(pending, value.destination);
  });
  static BackupPublicationObservation observe(
    MacBackupPublication value, {
    required bool flush,
  }) => _with(value, () {
    _verify(value.source, value);
    final target = _native.open(
      value.destination,
      missing: true,
      writing: flush,
    );
    if (target < 0) return BackupPublicationObservation.absent;
    try {
      if (_native.identity(target) != value.sourceIdentity ||
          _native.content(target) != (value.bytes, value.digest)) {
        return BackupPublicationObservation.different;
      }
      if (flush) _native.flush(target);
      return BackupPublicationObservation.matching;
    } finally {
      _native.close(target);
    }
  });
  static void cleanup(MacBackupPublication value) => _guard(() {
    final (parent, _) = path(value.source);
    final directory = _native.open(parent, directory: true, private: true);
    final handles = <int>[];
    try {
      if (_native.identity(directory) != value.sourceDirectoryIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      for (final path in [value.source, '${value.source}.publish']) {
        final handle = _native.open(
          path,
          private: true,
          deleting: true,
          missing: true,
        );
        if (handle < 0) continue;
        handles.add(handle);
        if (_native.identity(handle) != value.sourceIdentity)
          throw const BackupPublicationFailure('identity_changed');
      }
      for (final handle in handles) {
        _native.remove(handle);
      }
    } finally {
      for (final handle in handles) {
        _native.close(handle);
      }
      _native.close(directory);
    }
  });
  static void cleanupStaging(
    MacBackupStagingDirectory value, {
    required Set<String> generatedFiles,
  }) => _guard(() {
    for (final name in generatedFiles) {
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains(RegExp(r'[/\\\x00]'))) {
        throw const BackupPublicationFailure('invalid_staging');
      }
    }
    final (parent, _) = path(value.path);
    final parentHandle = _native.open(parent, directory: true, missing: true);
    if (parentHandle < 0) return;
    var directory = -1;
    final handles = <int>[];
    try {
      if (_native.identity(parentHandle) != value.parentIdentity)
        throw const BackupPublicationFailure('identity_changed');
      directory = _native.open(
        value.path,
        directory: true,
        private: true,
        deleting: true,
        missing: true,
      );
      if (directory < 0) return;
      if (_native.identity(directory) != value.identity)
        throw const BackupPublicationFailure('identity_changed');
      for (final entry in Directory(value.path).listSync(followLinks: false)) {
        final (_, name) = path(entry.path);
        if (entry is! File || !generatedFiles.contains(name))
          throw const BackupPublicationFailure('staging_not_empty');
        handles.add(_native.open(entry.path, private: true, deleting: true));
      }
      for (final handle in handles) {
        _native.remove(handle);
      }
      for (final handle in handles) {
        _native.close(handle);
      }
      handles.clear();
      _native.remove(directory);
    } finally {
      for (final handle in handles) {
        _native.close(handle);
      }
      _native.close(directory);
      _native.close(parentHandle);
    }
  });
}

final class _WindowsPublicationNative {
  late final kernel = DynamicLibrary.open('kernel32.dll');
  late final _open = kernel
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  late final _close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final _info = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('GetFileInformationByHandle');
  late final _lastError = kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final _finalPath = kernel
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32),
        int Function(int, Pointer<Utf16>, int, int)
      >('GetFinalPathNameByHandleW');
  late final _read = kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('ReadFile');
  late final _flush = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'FlushFileBuffers',
      );
  late final _link = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
      >('CreateHardLinkW');
  late final _move = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('MoveFileExW');
  late final _setInfo = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('SetFileInformationByHandle');
  String _normal(String value) => value.replaceAll('/', r'\').toLowerCase();
  bool samePath(String first, String second) =>
      _normal(first) == _normal(second);
  T _name<T>(String path, T Function(Pointer<Utf16>) action) {
    final name = (r'\\?\' + path.replaceAll('/', r'\')).toNativeUtf16();
    try {
      return action(name);
    } finally {
      calloc.free(name);
    }
  }

  int open(
    String path, {
    bool directory = false,
    bool private = false,
    bool singleLink = false,
    bool deleting = false,
    bool writing = false,
    bool missing = false,
  }) {
    // The parent directory handles omit SHARE_DELETE, pinning the complete
    // canonical binding while a source/destination operation is in progress.
    final lastError = _lastError;
    final (handle, error) = _name(path, (name) {
      final handle = _open(
        name,
        0x20080 |
            (directory ? 0 : 0x80000000) |
            (writing ? 0x40000000 : 0) |
            (deleting ? 0x10000 : 0),
        directory ? 3 : 5,
        nullptr,
        3,
        0x00200000 | (directory ? 0x02000000 : 0),
        0,
      );
      return (handle, lastError());
    });
    if (handle == -1) {
      if (missing && {2, 3}.contains(error)) return -1;
      throw const BackupPublicationFailure('identity_unavailable');
    }
    try {
      final buffer = calloc<Uint16>(32768);
      try {
        final length = _finalPath(handle, buffer.cast(), 32768, 0);
        if (length == 0 ||
            length >= 32768 ||
            !samePath(
              buffer.cast<Utf16>().toDartString().replaceFirst(r'\\?\', ''),
              path,
            )) {
          throw const BackupPublicationFailure('identity_changed');
        }
      } finally {
        calloc.free(buffer);
      }
      _metadata(handle, directory: directory, singleLink: singleLink);
      if (private) {
        WindowsPrivateFiles.verifyPublicationHandle(
          handle,
          directory: directory,
        );
      }
      return handle;
    } catch (_) {
      close(handle);
      rethrow;
    }
  }

  List<int> _metadata(int handle, {bool? directory, bool singleLink = false}) {
    final bytes = calloc<Uint8>(52);
    try {
      if (_info(handle, bytes) == 0)
        throw const BackupPublicationFailure('identity_unavailable');
      final words = bytes.cast<Uint32>().asTypedList(13);
      if (words[0] & 0x400 != 0 ||
          directory != null && (words[0] & 0x10 != 0) != directory ||
          (words[0] & 0x10 == 0) &&
              (words[10] < 1 || words[10] > (singleLink ? 1 : 2))) {
        throw const BackupPublicationFailure('identity_changed');
      }
      return words.toList();
    } finally {
      calloc.free(bytes);
    }
  }

  String identity(int handle) {
    final words = _metadata(handle);
    final object = 'windows:${words[7]}:${words[11]}:${words[12]}';
    // NTFS tunneling can replace a file's creation time when its hard link is
    // renamed onto a recently deleted name. The retained source link keeps
    // this file ID allocated through publication/reconciliation/cleanup;
    // content, DACL, canonical binding and link count are checked separately.
    // Directory creation time remains useful across reopen (no rename here).
    return words[0] & 0x10 != 0 ? '$object:${words[2]}:${words[1]}' : object;
  }

  int volume(int handle) => _metadata(handle)[7];
  (int, String) content(int handle) {
    final before = _metadata(handle, directory: false);
    final length = before[8] * 4294967296 + before[9];
    if (length > 256 * 1024 * 1024)
      throw const BackupPublicationFailure('invalid_file_content');
    final data = calloc<Uint8>(65536), count = calloc<Uint32>();
    final output = _DigestSink();
    final digest = sha256.startChunkedConversion(output);
    var total = 0;
    try {
      while (true) {
        if (_read(handle, data, 65536, count, nullptr) == 0)
          throw const BackupPublicationFailure('file_read_failed');
        if (count.value == 0) break;
        total += count.value;
        if (total > length)
          throw const BackupPublicationFailure('prepared_file_changed');
        digest.add(data.asTypedList(count.value));
      }
      digest.close();
      if (total != length ||
          _metadata(handle)[8] * 4294967296 + _metadata(handle)[9] != length) {
        throw const BackupPublicationFailure('prepared_file_changed');
      }
      return (total, output.value.toString());
    } finally {
      data.asTypedList(65536).fillRange(0, 65536, 0);
      calloc.free(data);
      calloc.free(count);
    }
  }

  void flush(int handle) {
    if (_flush(handle) == 0)
      throw const BackupPublicationFailure('flush_failed');
  }

  void link(String source, String pending) => _name(
    pending,
    (to) => _name(source, (from) {
      if (_link(to, from, nullptr) == 0)
        throw const BackupPublicationFailure('link_failed');
    }),
  );
  void move(String source, String destination) => _name(
    source,
    (from) => _name(destination, (to) {
      if (_move(from, to, 8) == 0) {
        final code = _lastError();
        if ({2, 3, 5, 17, 32, 33, 80, 183}.contains(code))
          throw const BackupPublicationFailure('publish_failed');
        // A write-through I/O failure can follow the rename. Preserve the
        // submitted state for observation instead of calling it a failed write.
        throw const BackupPublicationFailure('flush_failed');
      }
    }),
  );
  void remove(int handle) {
    final disposition = calloc<Uint8>()..value = 1;
    try {
      if (_setInfo(handle, 4, disposition.cast(), 1) == 0)
        throw const BackupPublicationFailure('cleanup_failed');
    } finally {
      calloc.free(disposition);
    }
  }

  void close(int handle) {
    if (handle != -1) _close(handle);
  }
}
