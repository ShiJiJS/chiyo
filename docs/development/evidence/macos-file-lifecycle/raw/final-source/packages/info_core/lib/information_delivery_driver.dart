import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'runtime_material_files.dart';

/// Private registry identity, never a public delivery response or bearer.
final class InformationDeliveryLease {
  InformationDeliveryLease(
    this.path,
    this.directoryIdentity,
    this.name,
    this.fileIdentity,
  ) {
    if (path.isEmpty ||
        path.length > 32768 ||
        path.contains('\x00') ||
        !RegExp(r'^attachment\.[a-z0-9]{1,12}$').hasMatch(name) ||
        directoryIdentity.isEmpty ||
        directoryIdentity.length > 200 ||
        fileIdentity.isEmpty ||
        fileIdentity.length > 200) {
      throw const FormatException('Invalid file delivery registry');
    }
  }
  final String path, directoryIdentity, name, fileIdentity;
  String get filePath => '$path${Platform.pathSeparator}$name';
  Map<String, Object?> toPrivateJson() => {
    'path': path,
    'directoryIdentity': directoryIdentity,
    'name': name,
    'fileIdentity': fileIdentity,
  };
  factory InformationDeliveryLease.fromPrivateJson(Map<String, dynamic> j) {
    if (j.length != 4 ||
        !j.keys.toSet().containsAll({
          'path',
          'directoryIdentity',
          'name',
          'fileIdentity',
        }) ||
        j.values.any((v) => v is! String)) {
      throw const FormatException('Invalid file delivery registry');
    }
    return InformationDeliveryLease(
      j['path'] as String,
      j['directoryIdentity'] as String,
      j['name'] as String,
      j['fileIdentity'] as String,
    );
  }
  @override
  String toString() => 'InformationDeliveryLease([private])';
}

/// Reserve only empty files. The caller durably registers the lease before
/// write, and verifies a complete original before disclosing its path.
abstract interface class InformationDeliveryFiles {
  Future<InformationDeliveryLease> reserve(String safeName);
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes);
  Future<void> verify(
    InformationDeliveryLease lease,
    int byteLength,
    String digest,
  );
  Future<void> cleanup(InformationDeliveryLease lease);
}

/// Reuses the current platform's protected objects, real identity/permission
/// checks and nonrecursive cleanup already used by credential materials.
class NativeInformationDeliveryFiles implements InformationDeliveryFiles {
  CredentialMaterialLease _native(InformationDeliveryLease lease) =>
      CredentialMaterialLease(lease.path, lease.directoryIdentity, {
        lease.name: lease.fileIdentity,
      });
  @override
  Future<InformationDeliveryLease> reserve(String safeName) async {
    if (!RegExp(r'^attachment\.[a-z0-9]{1,12}$').hasMatch(safeName)) {
      throw const RuntimeMaterialFailure('identity_mismatch');
    }
    final directory = ManagedCredentialFiles.create();
    try {
      final result = ManagedCredentialFiles.reserve(directory, [safeName]);
      return InformationDeliveryLease(
        result.path,
        result.identity,
        safeName,
        result.files[safeName]!,
      );
    } on Object {
      try {
        ManagedCredentialFiles.cleanup(directory);
      } on Object {
        /* Empty unknown objects are retained. */
      }
      rethrow;
    }
  }

  @override
  Future<void> write(InformationDeliveryLease lease, Uint8List bytes) async =>
      ManagedCredentialFiles.write(_native(lease), lease.name, bytes);
  @override
  Future<void> verify(
    InformationDeliveryLease lease,
    int byteLength,
    String digest,
  ) async {
    ManagedCredentialFiles.verify(_native(lease), allowConcurrentReaders: true);
    final file = await File(lease.filePath).open();
    try {
      if (await file.length() != byteLength ||
          byteLength < 0 ||
          byteLength > 10 * 1024 * 1024) {
        throw const RuntimeMaterialFailure('integrity_failed');
      }
      final result = _DeliveryDigest();
      final input = sha256.startChunkedConversion(result);
      var read = 0;
      try {
        while (read < byteLength) {
          final bytes = await file.read(
            byteLength - read > 1024 * 1024 ? 1024 * 1024 : byteLength - read,
          );
          if (bytes.isEmpty) {
            throw const RuntimeMaterialFailure('integrity_failed');
          }
          input.add(bytes);
          read += bytes.length;
        }
      } finally {
        input.close();
      }
      if (await file.length() != byteLength ||
          result.value?.toString() != digest) {
        throw const RuntimeMaterialFailure('integrity_failed');
      }
    } finally {
      await file.close();
    }
    ManagedCredentialFiles.verify(_native(lease), allowConcurrentReaders: true);
  }

  @override
  Future<void> cleanup(InformationDeliveryLease lease) async =>
      ManagedCredentialFiles.cleanup(_native(lease));
}

/// Retained for existing Windows callers. The implementation now dispatches
/// through ManagedCredentialFiles without changing Windows file semantics.
final class WindowsInformationDeliveryFiles
    extends NativeInformationDeliveryFiles {}

final class _DeliveryDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}
