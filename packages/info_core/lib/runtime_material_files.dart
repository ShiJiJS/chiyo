import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:ffi/ffi.dart';

/// Private registry data. Never include this object in a public protocol DTO.
class CredentialMaterialLease {
  CredentialMaterialLease(this.path, this.identity, Map<String, String> files)
    : files = Map.unmodifiable(files);
  final String path, identity;
  final Map<String, String> files;
  CredentialMaterialLease withFiles(Map<String, String> files) =>
      CredentialMaterialLease(path, identity, files);
  Map<String, Object?> toPrivateJson() => {
    'path': path,
    'identity': identity,
    'files': files,
  };
  factory CredentialMaterialLease.fromPrivateJson(Map<String, dynamic> j) =>
      CredentialMaterialLease(
        j['path'] as String,
        j['identity'] as String,
        (j['files'] as Map).cast<String, String>(),
      );
  @override
  String toString() => 'CredentialMaterialLease([private])';
}

class RuntimeMaterialFailure implements Exception {
  const RuntimeMaterialFailure(this.code);
  final String code;
  @override
  String toString() => 'RuntimeMaterialFailure($code)';
}

/// Creates protected objects from birth, checks real file identities/DACLs, and
/// deletes by an opened handle. Cleanup never recursively traverses a path.
class ManagedCredentialFiles {
  static final _windows = _WindowsMaterialFiles();
  static CredentialMaterialLease create() {
    if (!Platform.isWindows) throw const RuntimeMaterialFailure('unsupported');
    final parent = Directory.systemTemp.resolveSymbolicLinksSync();
    if (!RegExp(r'^[A-Za-z]:[/\\]').hasMatch(parent)) {
      throw const RuntimeMaterialFailure('prepare_failed');
    }
    final nonce = base64Url.encode(
      List.generate(24, (_) => Random.secure().nextInt(256)),
    );
    final path = '$parent${Platform.pathSeparator}info-managed-$nonce';
    _windows.createDirectory(path);
    final handle = _windows.open(path, directory: true);
    try {
      return CredentialMaterialLease(
        path,
        _windows.identity(handle, directory: true),
        {},
      );
    } finally {
      _windows.close(handle);
    }
  }

  static int _parent(CredentialMaterialLease lease, {bool deleting = false}) {
    final parent = Directory(lease.path).parent.path.toLowerCase();
    // The desktop, not the invoking CLI's TEMP environment, chose this path.
    // Its immutable registry entry and OS identity/DACL are the authority.
    final canonicalParent = Directory(
      lease.path,
    ).parent.resolveSymbolicLinksSync().toLowerCase();
    final name = Directory(
      lease.path,
    ).uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (!RegExp(r'^[A-Za-z]:[/\\]').hasMatch(lease.path) ||
        parent != canonicalParent ||
        !RegExp(r'^info-managed-[A-Za-z0-9_-]{32}$').hasMatch(name)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final handle = _windows.open(
      lease.path,
      directory: true,
      deleting: deleting,
    );
    try {
      if (_windows.identity(handle, directory: true) != lease.identity) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      return handle;
    } on Object {
      _windows.close(handle);
      rethrow;
    }
  }

  static String _path(CredentialMaterialLease lease, String name) {
    if (!{
      'credential.bin',
      'aws-config',
      'ssh-config',
      'known-hosts',
      'global-known-hosts',
    }.contains(name)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    return '${lease.path}${Platform.pathSeparator}$name';
  }

  static CredentialMaterialLease reserve(
    CredentialMaterialLease lease,
    List<String> names,
  ) {
    final parent = _parent(lease);
    final files = Map<String, String>.from(lease.files);
    try {
      for (final name in names) {
        final handle = _windows.createFile(_path(lease, name));
        try {
          files[name] = _windows.identity(handle);
        } finally {
          _windows.close(handle);
        }
      }
      return lease.withFiles(files);
    } on Object {
      // Only empty files exist before registration; retain unknown objects.
      for (final entry in files.entries) {
        try {
          _deleteFile(lease, entry.key, entry.value);
        } on Object {
          /* registry retains failures */
        }
      }
      rethrow;
    } finally {
      _windows.close(parent);
    }
  }

  static void verify(CredentialMaterialLease lease) {
    final parent = _parent(lease);
    try {
      for (final entry in lease.files.entries) {
        final handle = _windows.open(_path(lease, entry.key));
        try {
          if (_windows.identity(handle) != entry.value) {
            throw const RuntimeMaterialFailure('identity_mismatch');
          }
        } finally {
          _windows.close(handle);
        }
      }
    } finally {
      _windows.close(parent);
    }
  }

  static void write(
    CredentialMaterialLease lease,
    String name,
    List<int> bytes,
  ) {
    if (!lease.files.containsKey(name)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final parent = _parent(lease);
    try {
      final handle = _windows.open(_path(lease, name), writing: true);
      try {
        if (_windows.identity(handle) != lease.files[name]) {
          throw const RuntimeMaterialFailure('identity_mismatch');
        }
        _windows.writeEmpty(handle, bytes);
      } finally {
        _windows.close(handle);
      }
    } finally {
      _windows.close(parent);
    }
  }

  static void _deleteFile(
    CredentialMaterialLease lease,
    String name,
    String identity,
  ) {
    final path = _path(lease, name);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final handle = _windows.open(path, deleting: true);
    try {
      if (_windows.identity(handle) != identity) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      _windows.delete(handle);
    } finally {
      _windows.close(handle);
    }
  }

  static void cleanup(CredentialMaterialLease lease) {
    if (FileSystemEntity.typeSync(lease.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final parent = _parent(lease, deleting: true);
    try {
      final names = Directory(lease.path)
          .listSync(followLinks: false)
          .map((f) => f.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toSet();
      if (names.any((n) => !lease.files.containsKey(n))) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      for (final entry in lease.files.entries) {
        _deleteFile(lease, entry.key, entry.value);
      }
      _windows.delete(parent);
    } finally {
      _windows.close(parent);
    }
  }
}

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int length;
  external Pointer<Void> descriptor;
  @Int32()
  external int inherit;
}

class _WindowsMaterialFiles {
  final kernel = DynamicLibrary.open('kernel32.dll'),
      security = DynamicLibrary.open('advapi32.dll');
  late final _lastError = kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  late final free = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final _open = kernel
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<_SecurityAttributes>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<_SecurityAttributes>,
          int,
          int,
          int,
        )
      >('CreateFileW');
  late final _mkdir = kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<_SecurityAttributes>),
        int Function(Pointer<Utf16>, Pointer<_SecurityAttributes>)
      >('CreateDirectoryW');
  late final _sddl = security
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Utf16>,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('ConvertStringSecurityDescriptorToSecurityDescriptorW');
  late final _fileInfo = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >('GetFileInformationByHandle');
  late final _token = security
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
        int Function(int, int, Pointer<IntPtr>)
      >('OpenProcessToken');
  late final _tokenInfo = security
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  late final _sidText = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>),
        int Function(Pointer<Void>, Pointer<Pointer<Utf16>>)
      >('ConvertSidToStringSidW');
  late final _securityInfo = security
      .lookupFunction<
        Uint32 Function(
          IntPtr,
          Uint32,
          Uint32,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          int,
          int,
          int,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
          Pointer<Pointer<Void>>,
        )
      >('GetSecurityInfo');
  late final _control = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>),
        int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>)
      >('GetSecurityDescriptorControl');
  late final _ace = security
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>),
        int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      >('GetAce');
  late final _write = kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      >('WriteFile');
  late final _flush = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'FlushFileBuffers',
      );
  late final _set = kernel
      .lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)
      >('SetFileInformationByHandle');
  late final currentSid = _currentSid();
  String _sid(Pointer<Void> value) {
    final result = calloc<Pointer<Utf16>>();
    try {
      if (_sidText(value, result) == 0) {
        throw const RuntimeMaterialFailure('permissions');
      }
      try {
        return result.value.toDartString();
      } finally {
        free(result.value.cast());
      }
    } finally {
      calloc.free(result);
    }
  }

  String _currentSid() {
    final token = calloc<IntPtr>(), length = calloc<Uint32>();
    try {
      if (_token(-1, 8, token) == 0) {
        throw const RuntimeMaterialFailure('permissions');
      }
      _tokenInfo(token.value, 1, nullptr, 0, length);
      if (length.value < sizeOf<IntPtr>() || length.value > 65536) {
        throw const RuntimeMaterialFailure('permissions');
      }
      final data = calloc<Uint8>(length.value);
      try {
        if (_tokenInfo(token.value, 1, data.cast(), length.value, length) ==
            0) {
          throw const RuntimeMaterialFailure('permissions');
        }
        return _sid(data.cast<Pointer<Void>>().value);
      } finally {
        calloc.free(data);
      }
    } finally {
      if (token.value != 0) close(token.value);
      calloc.free(token);
      calloc.free(length);
    }
  }

  T _withSecurity<T>(
    bool directory,
    T Function(Pointer<_SecurityAttributes>) action,
  ) {
    final text =
        'O:$currentSid'
                'D:P(A;${directory ? 'OICI' : ''};FA;;;SY)(A;${directory ? 'OICI' : ''};FA;;;$currentSid)'
            .toNativeUtf16();
    final descriptor = calloc<Pointer<Void>>(),
        attributes = calloc<_SecurityAttributes>();
    try {
      if (_sddl(text, 1, descriptor, nullptr) == 0) {
        throw const RuntimeMaterialFailure('permissions');
      }
      attributes.ref
        ..length = sizeOf<_SecurityAttributes>()
        ..descriptor = descriptor.value
        ..inherit = 0;
      return action(attributes);
    } finally {
      if (descriptor.value != nullptr) free(descriptor.value);
      calloc.free(descriptor);
      calloc.free(attributes);
      calloc.free(text);
    }
  }

  void createDirectory(String path) {
    final native = path.toNativeUtf16();
    try {
      _withSecurity(true, (attributes) {
        if (_mkdir(native, attributes) == 0) {
          throw const RuntimeMaterialFailure('prepare_failed');
        }
      });
    } finally {
      calloc.free(native);
    }
  }

  int createFile(String path) {
    final native = path.toNativeUtf16();
    try {
      return _withSecurity(false, (attributes) {
        final h = _open(native, 0x40020080, 0, attributes, 1, 0x00200080, 0);
        if (h == -1) throw const RuntimeMaterialFailure('prepare_failed');
        return h;
      });
    } finally {
      calloc.free(native);
    }
  }

  int open(
    String path, {
    bool directory = false,
    bool writing = false,
    bool deleting = false,
  }) {
    final native = path.toNativeUtf16();
    try {
      final handle = _open(
        native,
        0x20080 | (writing ? 0x40000000 : 0) | (deleting ? 0x10000 : 0),
        directory ? 3 : 0,
        nullptr,
        3,
        0x00200000 | (directory ? 0x02000000 : 0),
        0,
      );
      // Capture before allocating collections or making another native call.
      final error = _lastError();
      if (handle == -1) {
        if (deleting && {32, 33}.contains(error)) {
          throw const RuntimeMaterialFailure('cleanup_failed');
        }
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      return handle;
    } finally {
      calloc.free(native);
    }
  }

  void _privateAcl(int handle) {
    final owner = calloc<Pointer<Void>>(),
        acl = calloc<Pointer<Void>>(),
        descriptor = calloc<Pointer<Void>>(),
        ace = calloc<Pointer<Void>>();
    final control = calloc<Uint16>(), revision = calloc<Uint32>();
    try {
      if (_securityInfo(
                handle,
                1,
                5,
                owner,
                nullptr,
                acl,
                nullptr,
                descriptor,
              ) !=
              0 ||
          acl.value == nullptr ||
          _control(descriptor.value, control, revision) == 0 ||
          control.value & 0x1000 == 0 ||
          _sid(owner.value) != currentSid) {
        throw const RuntimeMaterialFailure('permissions');
      }
      if ((acl.value.cast<Uint8>() + 4).cast<Uint16>().value != 2) {
        throw const RuntimeMaterialFailure('permissions');
      }
      final trustees = <String>{};
      for (var i = 0; i < 2; i++) {
        if (_ace(acl.value, i, ace) == 0) {
          throw const RuntimeMaterialFailure('permissions');
        }
        final bytes = ace.value.cast<Uint8>();
        if (bytes.value != 0 ||
            (bytes + 1).value & 0x10 != 0 ||
            (bytes + 4).cast<Uint32>().value != 0x1f01ff) {
          throw const RuntimeMaterialFailure('permissions');
        }
        trustees.add(_sid((bytes + 8).cast()));
      }
      if (trustees.length != 2 ||
          !trustees.contains(currentSid) ||
          !trustees.contains('S-1-5-18')) {
        throw const RuntimeMaterialFailure('permissions');
      }
    } finally {
      if (descriptor.value != nullptr) free(descriptor.value);
      calloc.free(owner);
      calloc.free(acl);
      calloc.free(descriptor);
      calloc.free(ace);
      calloc.free(control);
      calloc.free(revision);
    }
  }

  String identity(int handle, {bool directory = false}) {
    final info = calloc<Uint8>(52);
    try {
      if (_fileInfo(handle, info) == 0) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      final attributes = info.cast<Uint32>().value;
      if (attributes & 0x400 != 0 ||
          (attributes & 0x10 != 0) != directory ||
          !directory && (info + 40).cast<Uint32>().value != 1) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      _privateAcl(handle);
      return '${(info + 28).cast<Uint32>().value}:${(info + 44).cast<Uint32>().value}:${(info + 48).cast<Uint32>().value}';
    } finally {
      calloc.free(info);
    }
  }

  void writeEmpty(int handle, List<int> bytes) {
    final info = calloc<Uint8>(52),
        written = calloc<Uint32>(),
        data = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (_fileInfo(handle, info) == 0 ||
          (info + 32).cast<Uint32>().value != 0 ||
          (info + 36).cast<Uint32>().value != 0) {
        throw const RuntimeMaterialFailure('identity_mismatch');
      }
      data.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        if (_write(
                  handle,
                  data + offset,
                  bytes.length - offset,
                  written,
                  nullptr,
                ) ==
                0 ||
            written.value == 0) {
          throw const RuntimeMaterialFailure('prepare_failed');
        }
        offset += written.value;
      }
      if (_flush(handle) == 0) {
        throw const RuntimeMaterialFailure('prepare_failed');
      }
    } finally {
      data
          .asTypedList(bytes.isEmpty ? 1 : bytes.length)
          .fillRange(0, bytes.isEmpty ? 1 : bytes.length, 0);
      calloc.free(data);
      calloc.free(info);
      calloc.free(written);
    }
  }

  void delete(int handle) {
    final disposition = calloc<Uint32>()..value = 1;
    try {
      if (_set(handle, 4, disposition.cast(), 4) == 0) {
        throw const RuntimeMaterialFailure('cleanup_failed');
      }
    } finally {
      calloc.free(disposition);
    }
  }
}
