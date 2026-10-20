part of 'runtime_material_files.dart';

// Darwin's 144-byte, 64-bit stat layout, shared by arm64 and x86_64.
final class _DarwinStat extends Struct {
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
  external Array<Int64> accessModificationChange;
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

/// Descriptor-relative, nonrecursive operations on owner-only Darwin files.
/// Never follows a symlink or writes a file whose identity changed. POSIX unlink
/// removes a name even when an existing reader still holds the old inode; it
/// cannot retract bytes already opened or copied (ADR 0002).
class _MacOsMaterialFiles {
  static const _noFollow = 0x100, _closeOnExec = 0x1000000;
  static const _directory = 0x100000, _create = 0x200, _exclusive = 0x800;
  final _lib = DynamicLibrary.open('/usr/lib/libSystem.B.dylib');
  late final _open = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(Pointer<Utf8>, int, int)
      >('open');
  late final _openAt = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32, VarArgs<(Int32,)>),
        int Function(int, Pointer<Utf8>, int, int)
      >('openat');
  late final _mkdirAt = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Uint16),
        int Function(int, Pointer<Utf8>, int)
      >('mkdirat');
  late final _unlinkAt = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Utf8>, Int32),
        int Function(int, Pointer<Utf8>, int)
      >('unlinkat');
  late final _stat = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<_DarwinStat>),
        int Function(int, Pointer<_DarwinStat>)
      >('fstat${Abi.current() == Abi.macosX64 ? r'$INODE64' : ''}');
  late final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  late final _uid = _lib.lookupFunction<Uint32 Function(), int Function()>(
    'geteuid',
  );
  late final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__error',
      );
  late final _write = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  late final _sync = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  late final _getAcl = _lib
      .lookupFunction<
        Pointer<Void> Function(Int32, Int32),
        Pointer<Void> Function(int, int)
      >('acl_get_fd_np');
  late final _validAcl = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_valid');
  late final _aclEntry = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('acl_get_entry');
  late final _freeAcl = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('acl_free');

  T _name<T>(String value, T Function(Pointer<Utf8>) action) {
    final native = value.toNativeUtf8();
    try {
      return action(native);
    } finally {
      calloc.free(native);
    }
  }

  int _directoryAt(int parent, String name) => _name(name, (n) {
    final fd = _openAt(parent, n, _directory | _noFollow | _closeOnExec, 0);
    if (fd < 0) throw const RuntimeMaterialFailure('identity_mismatch');
    return fd;
  });

  int _canonicalDirectory(String path) {
    if (!path.startsWith('/') ||
        path.contains('\x00') ||
        Directory(path).resolveSymbolicLinksSync() != path) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    return _name(path, (n) {
      final fd = _open(n, _directory | _noFollow | _closeOnExec, 0);
      if (fd < 0) throw const RuntimeMaterialFailure('identity_mismatch');
      return fd;
    });
  }

  void _privateAcl(int fd) {
    _errno().value = 0;
    final acl = _getAcl(fd, 0x100);
    if (acl == nullptr) {
      // Darwin reports ENOENT when this existing descriptor has no extended
      // ACL. Other lookup errors are not evidence that access is private.
      if (_errno().value == 2) return;
      throw const RuntimeMaterialFailure('permissions');
    }
    final entry = calloc<Pointer<Void>>();
    try {
      if (_validAcl(acl) != 0) {
        throw const RuntimeMaterialFailure('permissions');
      }
      _errno().value = 0;
      final result = _aclEntry(acl, 0, entry);
      // On Darwin, an empty, valid extended ACL reports EINVAL at FIRST_ENTRY.
      if (result != -1 || _errno().value != 22) {
        throw const RuntimeMaterialFailure('permissions');
      }
    } finally {
      calloc.free(entry);
      _freeAcl(acl);
    }
  }

  String _identity(int fd, {bool directory = false, bool empty = false}) {
    final value = calloc<_DarwinStat>();
    try {
      if (_stat(fd, value) != 0) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      final info = value.ref;
      if (info.uid != _uid() ||
          info.mode & 0xf000 != (directory ? 0x4000 : 0x8000) ||
          info.mode & 0xfff != (directory ? 0x1c0 : 0x180) ||
          !directory && info.links != 1 ||
          empty && info.bytes != 0) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      _privateAcl(fd);
      return 'macos:${info.device}:${info.inode}:${info.birthSeconds}:${info.birthNanos}:${info.generation}';
    } finally {
      calloc.free(value);
    }
  }

  String _basename(CredentialMaterialLease lease) {
    final name = Directory(
      lease.path,
    ).uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!RegExp(r'^info-managed-[A-Za-z0-9_-]{32}$').hasMatch(name)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    return name;
  }

  int _parent(CredentialMaterialLease lease) {
    final name = _basename(lease);
    final parent = _canonicalDirectory(Directory(lease.path).parent.path);
    try {
      final fd = _directoryAt(parent, name);
      try {
        if (_identity(fd, directory: true) != lease.identity) {
          throw const RuntimeMaterialFailure('identity_mismatch');
        }
        return fd;
      } on Object {
        _close(fd);
        rethrow;
      }
    } finally {
      _close(parent);
    }
  }

  int _file(
    int parent,
    CredentialMaterialLease lease,
    String name, {
    bool create = false,
    bool writing = false,
  }) {
    ManagedCredentialFiles._path(lease, name); // Shared basename allowlist.
    return _name(name, (n) {
      final fd = _openAt(
        parent,
        n,
        _noFollow |
            _closeOnExec |
            (create
                ? _create | _exclusive | 2
                : writing
                ? 2
                : 0),
        0x180,
      );
      if (fd < 0) {
        throw RuntimeMaterialFailure(
          create ? 'prepare_failed' : 'identity_mismatch',
        );
      }
      return fd;
    });
  }

  CredentialMaterialLease create() {
    final directory = Directory.systemTemp.resolveSymbolicLinksSync();
    final parent = _canonicalDirectory(directory);
    final nonce = base64Url.encode(
      List.generate(24, (_) => Random.secure().nextInt(256)),
    );
    final name = 'info-managed-$nonce';
    try {
      if (_name(name, (n) => _mkdirAt(parent, n, 0x1c0)) != 0) {
        throw const RuntimeMaterialFailure('prepare_failed');
      }
      final fd = _directoryAt(parent, name);
      try {
        return CredentialMaterialLease(
          '$directory/$name',
          _identity(fd, directory: true),
          {},
        );
      } finally {
        _close(fd);
      }
    } finally {
      _close(parent);
    }
  }

  CredentialMaterialLease reserve(
    CredentialMaterialLease lease,
    List<String> names,
  ) {
    final parent = _parent(lease);
    final files = Map<String, String>.from(lease.files);
    try {
      for (final name in names) {
        final fd = _file(parent, lease, name, create: true);
        try {
          files[name] = _identity(fd, empty: true);
        } finally {
          _close(fd);
        }
      }
      return lease.withFiles(files);
    } on Object {
      // Only newly created empty files are removed on a failed reservation.
      for (final name in files.keys.where((n) => !lease.files.containsKey(n))) {
        try {
          _delete(parent, lease.withFiles(files), name);
        } on Object {
          /* Retain uncertain objects. */
        }
      }
      rethrow;
    } finally {
      _close(parent);
    }
  }

  void verify(CredentialMaterialLease lease, {bool allowMissing = false}) {
    final parent = _parent(lease);
    try {
      for (final name in lease.files.keys) {
        if (allowMissing &&
            FileSystemEntity.typeSync(
                  ManagedCredentialFiles._path(lease, name),
                  followLinks: false,
                ) ==
                FileSystemEntityType.notFound) {
          continue;
        }
        final fd = _file(parent, lease, name);
        try {
          if (_identity(fd) != lease.files[name]) {
            throw const RuntimeMaterialFailure('identity_mismatch');
          }
        } finally {
          _close(fd);
        }
      }
    } finally {
      _close(parent);
    }
  }

  void write(CredentialMaterialLease lease, String name, List<int> bytes) {
    if (!lease.files.containsKey(name)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final parent = _parent(lease);
    try {
      final fd = _file(parent, lease, name, writing: true);
      final data = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      try {
        if (_identity(fd, empty: true) != lease.files[name]) {
          throw const RuntimeMaterialFailure('identity_mismatch');
        }
        data.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final count = _write(fd, data + offset, bytes.length - offset);
          if (count < 0 && _errno().value == 4) continue;
          if (count <= 0) throw const RuntimeMaterialFailure('prepare_failed');
          offset += count;
        }
        if (_sync(fd) != 0) {
          throw const RuntimeMaterialFailure('prepare_failed');
        }
      } finally {
        data
            .asTypedList(bytes.isEmpty ? 1 : bytes.length)
            .fillRange(0, bytes.isEmpty ? 1 : bytes.length, 0);
        calloc.free(data);
        _close(fd);
      }
    } finally {
      _close(parent);
    }
  }

  void _delete(int parent, CredentialMaterialLease lease, String name) {
    ManagedCredentialFiles._path(lease, name);
    final fd = _name(
      name,
      (n) => _openAt(parent, n, _noFollow | _closeOnExec, 0),
    );
    if (fd < 0) {
      if (_errno().value == 2) return;
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    try {
      if (_identity(fd) != lease.files[name]) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      if (_name(name, (n) => _unlinkAt(parent, n, 0)) != 0) {
        throw const RuntimeMaterialFailure('cleanup_failed');
      }
    } finally {
      _close(fd);
    }
  }

  void cleanup(CredentialMaterialLease lease) {
    if (FileSystemEntity.typeSync(lease.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final parent = _parent(lease);
    try {
      final names = Directory(lease.path)
          .listSync(followLinks: false)
          .map((f) => f.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toSet();
      if (names.any((n) => !lease.files.containsKey(n))) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      // Verify all identities before deleting any of the registered names.
      verify(lease, allowMissing: true);
      for (final name in lease.files.keys) {
        _delete(parent, lease, name);
      }
      final grandparent = _canonicalDirectory(
        Directory(lease.path).parent.path,
      );
      try {
        final current = _directoryAt(grandparent, _basename(lease));
        try {
          if (_identity(current, directory: true) != lease.identity) {
            throw const RuntimeMaterialFailure('identity_mismatch');
          }
          if (_name(_basename(lease), (n) => _unlinkAt(grandparent, n, 0x80)) !=
              0) {
            throw const RuntimeMaterialFailure('cleanup_failed');
          }
        } finally {
          _close(current);
        }
      } finally {
        _close(grandparent);
      }
    } finally {
      _close(parent);
    }
  }
}
