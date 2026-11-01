import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// A private journal value, never a page resource or an Agent response.
/// Keep the prepared source until the durable successful receipt is committed.
final class MacBackupPublication {
  const MacBackupPublication._(
    this.source,
    this.destination,
    this.sourceIdentity,
    this.sourceDirectoryIdentity,
    this.destinationDirectoryIdentity,
    this.bytes,
    this.digest,
  );
  final String source, destination, sourceIdentity;
  final String sourceDirectoryIdentity, destinationDirectoryIdentity, digest;
  final int bytes;
  Map<String, Object?> toPrivateJson() => {
    'source': source,
    'destination': destination,
    'sourceIdentity': sourceIdentity,
    'sourceDirectoryIdentity': sourceDirectoryIdentity,
    'destinationDirectoryIdentity': destinationDirectoryIdentity,
    'bytes': bytes,
    'digest': digest,
  };
  factory MacBackupPublication.fromPrivateJson(Map<String, dynamic> json) {
    const strings = [
      'source',
      'destination',
      'sourceIdentity',
      'sourceDirectoryIdentity',
      'destinationDirectoryIdentity',
      'digest',
    ];
    if (json.length != 7 ||
        strings.any((k) => json[k] is! String) ||
        json['bytes'] is! int ||
        (json['bytes'] as int) < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['digest'] as String)) {
      throw const BackupPublicationFailure('invalid_publication');
    }
    _MacFiles.path(json['source'] as String);
    _MacFiles.path(json['destination'] as String);
    if (json['source'] == json['destination'] ||
        '${json['source']}.publish' == json['destination']) {
      throw const BackupPublicationFailure('invalid_publication');
    }
    for (final key in strings.skip(2).take(3)) {
      if (!RegExp(
        r'^macos:-?\d+:\d+:\d+:\d+:\d+:\d+$',
      ).hasMatch(json[key] as String)) {
        throw const BackupPublicationFailure('invalid_publication');
      }
    }
    return MacBackupPublication._(
      json['source'] as String,
      json['destination'] as String,
      json['sourceIdentity'] as String,
      json['sourceDirectoryIdentity'] as String,
      json['destinationDirectoryIdentity'] as String,
      json['bytes'] as int,
      json['digest'] as String,
    );
  }
  @override
  String toString() => 'MacBackupPublication([private])';
}

final class BackupPublicationFailure implements Exception {
  const BackupPublicationFailure(this.code);
  final String code;
  @override
  String toString() => 'BackupPublicationFailure($code)';
}

/// These are observations, NOT operation outcomes. An absent/replaced output
/// cannot prove a previously submitted publication never occurred.
enum BackupPublicationObservation { matching, absent, different }

/// Identity of an empty private directory reserved for one backup operation.
/// Persist this before creating material inside it. Never send it to a page.
final class MacBackupStagingDirectory {
  const MacBackupStagingDirectory._(
    this.path,
    this.identity,
    this.parentIdentity,
  );
  final String path, identity, parentIdentity;
  Map<String, Object?> toPrivateJson() => {
    'path': path,
    'identity': identity,
    'parentIdentity': parentIdentity,
  };
  factory MacBackupStagingDirectory.fromPrivateJson(Map<String, dynamic> json) {
    if (json.length != 3 ||
        json['path'] is! String ||
        json['identity'] is! String ||
        json['parentIdentity'] is! String) {
      throw const BackupPublicationFailure('invalid_staging');
    }
    _MacFiles.path(json['path'] as String);
    for (final key in ['identity', 'parentIdentity']) {
      if (!RegExp(
        r'^macos:-?\d+:\d+:\d+:\d+:\d+:\d+$',
      ).hasMatch(json[key] as String)) {
        throw const BackupPublicationFailure('invalid_staging');
      }
    }
    return MacBackupStagingDirectory._(
      json['path'] as String,
      json['identity'] as String,
      json['parentIdentity'] as String,
    );
  }
  @override
  String toString() => 'MacBackupStagingDirectory([private])';
}

/// macOS same-volume publication with a retained inode anchor. The caller must
/// durably journal [prepare]'s result BEFORE calling [publish], then commit the
/// success receipt BEFORE [cleanup]. Reconciliation never republishes a file.
/// Only the private registered staging names are removed; never the output.
class MacBackupPublicationFiles {
  static final _native = _MacFiles();

  static MacBackupStagingDirectory captureStaging(String path) {
    final (parent, _) = _MacFiles.path(path);
    final dir = _native.directory(path, private: true);
    var parentFd = -1;
    try {
      parentFd = _native.directory(parent);
      if (Directory(path).listSync(followLinks: false).isNotEmpty) {
        throw const BackupPublicationFailure('staging_not_empty');
      }
      return MacBackupStagingDirectory._(
        path,
        _native.identity(dir, directory: true, private: true),
        _native.identity(parentFd, directory: true),
      );
    } finally {
      if (parentFd >= 0) _native.close(parentFd);
      _native.close(dir);
    }
  }

  /// False means the registered name is absent, never a different directory.
  static bool stagingExists(MacBackupStagingDirectory value) {
    final (parent, name) = _MacFiles.path(value.path);
    final parentFd = _native.directory(parent);
    var dir = -1;
    try {
      if (_native.identity(parentFd, directory: true) != value.parentIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      dir = _native.at(parentFd, name, flags: 0x100000, missing: true);
      if (dir < 0) return false;
      if (_native.identity(dir, directory: true, private: true) !=
          value.identity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      return true;
    } finally {
      if (dir >= 0) _native.close(dir);
      _native.close(parentFd);
    }
  }

  /// Only exact generated basenames in the previously registered private
  /// directory may be removed. Unknown entries, links and replaced directories
  /// preserve the whole directory. No recursive deletion or output cleanup.
  static void cleanupStaging(
    MacBackupStagingDirectory value, {
    Set<String> generatedFiles = const {},
  }) {
    for (final name in generatedFiles) {
      if (name.isEmpty ||
          name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\x00')) {
        throw const BackupPublicationFailure('invalid_staging');
      }
    }
    final (parent, name) = _MacFiles.path(value.path);
    final parentFd = _native.directory(parent);
    var dir = -1;
    try {
      if (_native.identity(parentFd, directory: true) != value.parentIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      dir = _native.at(parentFd, name, flags: 0x100000, missing: true);
      if (dir < 0) return;
      if (_native.identity(dir, directory: true, private: true) !=
          value.identity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      final entries = Directory(value.path).listSync(followLinks: false);
      for (final entry in entries) {
        final child = entry.uri.pathSegments.last;
        if (!generatedFiles.contains(child)) {
          throw const BackupPublicationFailure('staging_not_empty');
        }
        final fd = _native.at(dir, child);
        try {
          _native.identity(fd);
        } finally {
          _native.close(fd);
        }
      }
      // Recheck the path binding after enumeration; deletion uses the retained
      // directory descriptor, never paths supplied by a page or recursive walk.
      final check = _native.at(parentFd, name, flags: 0x100000);
      try {
        if (_native.identity(check, directory: true, private: true) !=
            value.identity) {
          throw const BackupPublicationFailure('identity_changed');
        }
      } finally {
        _native.close(check);
      }
      for (final entry in entries) {
        _native.unlink(dir, entry.uri.pathSegments.last);
      }
      _native.flush(dir);
      _native.name(name, (p) {
        if (_native.unlinkAt(parentFd, p, 0x80) != 0) {
          throw const BackupPublicationFailure('staging_not_empty');
        }
      });
      _native.flush(parentFd);
    } finally {
      if (dir >= 0) _native.close(dir);
      _native.close(parentFd);
    }
  }

  static void writeRecoveryKey(String path, List<int> bytes) {
    if (bytes.isEmpty ||
        bytes.length > 256 ||
        bytes.any((b) => b < 0 || b > 255)) {
      throw const BackupPublicationFailure('invalid_recovery_key');
    }
    final (parent, name) = _MacFiles.path(path);
    final dir = _native.directory(parent, private: true);
    var fd = -1;
    try {
      fd = _native.at(dir, name, flags: 1 | 0x200 | 0x800, mode: 0x180);
      _native.writeBytes(fd, bytes);
      _native.flush(fd);
      _native.flush(dir);
    } finally {
      if (fd >= 0) _native.close(fd);
      _native.close(dir);
    }
  }

  static MacBackupPublication prepare(String source, String destination) {
    final (sourceParent, sourceName) = _MacFiles.path(source);
    final (targetParent, _) = _MacFiles.path(destination);
    if (source == destination ||
        '$source.publish' == destination ||
        sourceName.length > 240) {
      throw const BackupPublicationFailure('invalid_publication');
    }
    final from = _native.directory(sourceParent, private: true);
    var to = -1, file = -1;
    try {
      to = _native.directory(targetParent);
      file = _native.at(from, sourceName);
      final identity = _native.identity(file, singleLink: true);
      final content = _native.content(file);
      _native.flush(file);
      return MacBackupPublication._(
        source,
        destination,
        identity,
        _native.identity(from, directory: true),
        _native.identity(to, directory: true),
        content.$1,
        content.$2,
      );
    } finally {
      if (file >= 0) _native.close(file);
      if (to >= 0) _native.close(to);
      _native.close(from);
    }
  }

  static T _with<T>(
    MacBackupPublication value,
    T Function(int, int, String, String) action,
  ) {
    final (sourceParent, sourceName) = _MacFiles.path(value.source);
    final (targetParent, targetName) = _MacFiles.path(value.destination);
    final from = _native.directory(sourceParent, private: true);
    var to = -1;
    try {
      to = _native.directory(targetParent);
      if (_native.identity(from, directory: true) !=
              value.sourceDirectoryIdentity ||
          _native.identity(to, directory: true) !=
              value.destinationDirectoryIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      return action(from, to, sourceName, targetName);
    } finally {
      if (to >= 0) _native.close(to);
      _native.close(from);
    }
  }

  static void _verify(int directory, String name, MacBackupPublication value) {
    final fd = _native.at(directory, name);
    try {
      if (_native.identity(fd) != value.sourceIdentity ||
          _native.content(fd) != (value.bytes, value.digest)) {
        throw const BackupPublicationFailure('prepared_file_changed');
      }
    } finally {
      _native.close(fd);
    }
  }

  static void publish(MacBackupPublication value) => _with(value, (
    from,
    to,
    source,
    target,
  ) {
    _verify(from, source, value);
    final pending = '$source.publish';
    // Hard-linking preserves the original inode as evidence across a crash.
    // Both linkat and renameatx_np refuse an existing name. No copying fallback.
    _native.link(from, source, pending);
    _verify(from, pending, value);
    _native.rename(from, pending, to, target);
    _native.flush(to);
    _native.flush(from);
  });

  static void verifyPrepared(MacBackupPublication value) =>
      _with(value, (from, _, source, _) => _verify(from, source, value));

  static BackupPublicationObservation observe(MacBackupPublication value) =>
      _observe(value, flush: false);

  /// Before committing success, retry durability checks that may have failed
  /// after rename. This never creates or republishes an output.
  static BackupPublicationObservation confirmPublished(
    MacBackupPublication value,
  ) => _observe(value, flush: true);

  static BackupPublicationObservation _observe(
    MacBackupPublication value, {
    required bool flush,
  }) => _with(value, (from, to, source, target) {
    _verify(from, source, value);
    final fd = _native.at(to, target, missing: true);
    if (fd < 0) return BackupPublicationObservation.absent;
    try {
      if (_native.identity(fd) != value.sourceIdentity ||
          _native.content(fd) != (value.bytes, value.digest)) {
        return BackupPublicationObservation.different;
      }
      if (flush) {
        _native.flush(fd);
        _native.flush(to);
        _native.flush(from);
      }
      return BackupPublicationObservation.matching;
    } finally {
      _native.close(fd);
    }
  });

  static void cleanup(MacBackupPublication value) {
    final (parent, source) = _MacFiles.path(value.source);
    final dir = _native.directory(parent, private: true);
    try {
      if (_native.identity(dir, directory: true) !=
          value.sourceDirectoryIdentity) {
        throw const BackupPublicationFailure('identity_changed');
      }
      // Validate all existing names before deleting any; retain unknown files.
      for (final name in [source, '$source.publish']) {
        final fd = _native.at(dir, name, missing: true);
        if (fd < 0) continue;
        try {
          if (_native.identity(fd) != value.sourceIdentity) {
            throw const BackupPublicationFailure('identity_changed');
          }
        } finally {
          _native.close(fd);
        }
      }
      for (final name in [source, '$source.publish']) {
        _native.unlink(dir, name);
      }
      _native.flush(dir);
    } finally {
      _native.close(dir);
    }
  }
}

// Same Darwin stat ABI as the existing protected material-file driver.
final class _Stat extends Struct {
  @Int32()
  external int device;
  @Uint16()
  external int mode;
  @Uint16()
  external int links;
  @Uint64()
  external int inode;
  @Uint32()
  external int uid;
  @Uint32()
  external int gid;
  @Int32()
  external int rdevice;
  @Array(6)
  external Array<Int64> timestamps;
  @Int64()
  external int birthSeconds;
  @Int64()
  external int birthNanos;
  @Int64()
  external int bytes;
  @Int64()
  external int blocks;
  @Int32()
  external int blockSize;
  @Uint32()
  external int flags;
  @Uint32()
  external int generation;
  @Int32()
  external int reserved;
  @Array(2)
  external Array<Int64> reserved64;
}

class _MacFiles {
  static (String, String) path(String value) {
    if (!value.startsWith('/') ||
        value.contains('\x00') ||
        value.length > 32768) {
      throw const BackupPublicationFailure('invalid_path');
    }
    final file = File(value);
    final name = file.uri.pathSegments.lastOrNull;
    if (name == null || name.isEmpty || name == '.' || name == '..') {
      throw const BackupPublicationFailure('invalid_path');
    }
    return (file.parent.path, name);
  }

  late final lib = Platform.isMacOS
      ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
      : throw const BackupPublicationFailure('unsupported_platform');
  late final open = lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  late final openAt = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(int, Pointer<Utf8>, int, int)
      >('openat');
  late final close = lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  late final stat = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<_Stat>),
        int Function(int, Pointer<_Stat>)
      >('fstat${Abi.current() == Abi.macosX64 ? r'$INODE64' : ''}');
  late final uid = lib.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  );
  late final errno = lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  late final fsync = lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  late final seek = lib
      .lookupFunction<
        Int64 Function(Int32, Int64, Int32),
        int Function(int, int, int)
      >('lseek');
  late final read = lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('read');
  late final write = lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  late final linkAt = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('linkat');
  late final renameAt = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
        int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
      >('renameatx_np');
  late final unlinkAt = lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int)
      >('unlinkat');
  late final getAcl = lib
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32),
        Pointer<Void> Function(int, int)
      >('acl_get_fd_np');
  late final validAcl = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_valid');
  late final aclEntry = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('acl_get_entry');
  late final freeAcl = lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free');

  T name<T>(String text, T Function(Pointer<Utf8>) run) {
    final ptr = text.toNativeUtf8();
    try {
      return run(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  int directory(String path, {bool private = false}) {
    try {
      if (Directory(path).resolveSymbolicLinksSync() != path) {
        throw const BackupPublicationFailure('identity_changed');
      }
      final fd = name(path, (p) => open(p, 0x100000 | 0x100 | 0x1000000, 0));
      if (fd < 0) throw const BackupPublicationFailure('directory_unavailable');
      try {
        identity(fd, directory: true, private: private);
        return fd;
      } catch (_) {
        close(fd);
        rethrow;
      }
    } on FileSystemException {
      throw const BackupPublicationFailure('directory_unavailable');
    }
  }

  int at(
    int parent,
    String file, {
    int flags = 0,
    int mode = 0,
    bool missing = false,
  }) => name(file, (p) {
    final fd = openAt(parent, p, flags | 0x100 | 0x1000000 | 0x4, mode);
    if (fd < 0 && !(missing && errno().value == 2)) {
      throw const BackupPublicationFailure('file_unavailable');
    }
    return fd;
  });
  String identity(
    int fd, {
    bool directory = false,
    bool private = false,
    bool singleLink = false,
  }) {
    final ptr = calloc<_Stat>();
    try {
      if (stat(fd, ptr) != 0)
        throw const BackupPublicationFailure('identity_unavailable');
      final v = ptr.ref;
      if (v.uid != uid() ||
          v.mode & 0xf000 != (directory ? 0x4000 : 0x8000) ||
          private && v.mode & 0x1ff != 0x1c0 ||
          singleLink && v.links != 1) {
        throw const BackupPublicationFailure('identity_changed');
      }
      if (private || !directory) checkAcl(fd);
      return 'macos:${v.device}:${v.inode}:${v.birthSeconds}:${v.birthNanos}:${v.generation}:${v.mode}';
    } finally {
      calloc.free(ptr);
    }
  }

  void checkAcl(int fd) {
    errno().value = 0;
    final acl = getAcl(fd, 0x100);
    if (acl == nullptr) {
      if (errno().value == 2) return;
      throw const BackupPublicationFailure('permissions');
    }
    final entry = calloc<Pointer<Void>>();
    try {
      if (validAcl(acl) != 0)
        throw const BackupPublicationFailure('permissions');
      errno().value = 0;
      if (aclEntry(acl, 0, entry) != -1 || errno().value != 22) {
        throw const BackupPublicationFailure('permissions');
      }
    } finally {
      calloc.free(entry);
      freeAcl(acl);
    }
  }

  (int, String) content(int fd) {
    if (seek(fd, 0, 0) < 0)
      throw const BackupPublicationFailure('file_unavailable');
    final result = _DigestSink();
    final hash = sha256.startChunkedConversion(result);
    final buffer = calloc<Uint8>(65536);
    var total = 0;
    try {
      while (true) {
        final count = read(fd, buffer, 65536);
        if (count < 0) throw const BackupPublicationFailure('file_unavailable');
        if (count == 0) break;
        total += count;
        if (total > 256 * 1024 * 1024) {
          throw const BackupPublicationFailure('file_too_large');
        }
        hash.add(buffer.asTypedList(count));
      }
      hash.close();
      return (total, result.value!.toString());
    } finally {
      buffer.asTypedList(65536).fillRange(0, 65536, 0);
      calloc.free(buffer);
    }
  }

  void writeBytes(int fd, List<int> bytes) {
    final p = calloc<Uint8>(bytes.length);
    try {
      p.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final n = write(fd, p + offset, bytes.length - offset);
        if (n <= 0) throw const BackupPublicationFailure('write_failed');
        offset += n;
      }
    } finally {
      p.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(p);
    }
  }

  void flush(int fd) {
    if (fsync(fd) != 0) throw const BackupPublicationFailure('flush_failed');
  }

  void link(int dir, String from, String to) => name(
    from,
    (a) => name(to, (b) {
      if (linkAt(dir, a, dir, b, 0) != 0)
        throw const BackupPublicationFailure('link_failed');
    }),
  );
  void rename(int fromDir, String from, int toDir, String to) => name(
    from,
    (a) => name(to, (b) {
      if (renameAt(fromDir, a, toDir, b, 4) != 0)
        throw const BackupPublicationFailure('publish_failed');
    }),
  );
  void unlink(int dir, String file) => name(file, (p) {
    if (unlinkAt(dir, p, 0) != 0 && errno().value != 2)
      throw const BackupPublicationFailure('cleanup_failed');
  });
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}
