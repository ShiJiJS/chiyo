// Owner-requested offline export verification. Input paths arrive on stdin;
// recovery material, data values, filenames, counts and digests never leave RAM.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';

class _MemoryKeys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value == null ? null : List.of(value!);
  @override
  Future<void> create(List<int> bytes) async => value = List.of(bytes);
}

void _require(bool condition) {
  if (!condition) throw const StorageFailure('export_verification_failed');
}

List<String> _rows(Iterable<Object?> values) =>
    values.map(jsonEncode).toList()..sort();

// Private in-memory comparison only. Never use a test matcher or print these
// values: assertion diagnostics could otherwise disclose real owner material.
String _snapshot(EncryptedInformationRepository r) => jsonEncode({
  'information': _rows(r.items.map(informationToJson)),
  'credentials': _rows(r.managedCredentials.map((v) => v.toJson())),
  'materials': _rows(r.credentialMaterials.map((v) => v.toStorageJson())),
  'revisions': _rows(
    r.informationRevisions.map(
      (v) => {
        'item': informationToJson(v.item),
        'at': v.replacedAt.toUtc().toIso8601String(),
      },
    ),
  ),
  'recycle': _rows(r.recycleEntries.map((v) => v.toJson())),
  'grants': _rows(r.grantHistory.map((v) => v.toJson())),
  'requests': _rows(r.requestHistory.map((v) => v.toJson())),
  'accesses': _rows(r.accessRecords.map((v) => v.toJson())),
  'deliveries': _rows(
    r.informationFileDeliveries.map((v) => v.toArchiveJson()),
  ),
  'directories': _rows(
    r.directories.map((v) => [v.id, v.name, v.parentId, v.version]),
  ),
  'tags': _rows(r.tags.map((v) => [v.id, v.name, v.version])),
});

Future<List<int>> _digest(File file) =>
    sha256.bind(file.openRead()).first.then((value) => value.bytes);

Future<void> main() async {
  Directory? root;
  EncryptedInformationRepository? repo;
  InformationService? service;
  File? backup, keyFile;
  List<int>? backupBefore, keyBefore;
  final keys = _MemoryKeys();
  var verified = false, unchanged = false, cleaned = false;
  var status = 'verification_failed';
  try {
    _require(Platform.isMacOS);
    final input = await stdin.transform(utf8.decoder).join();
    _require(input.length <= 32768);
    final paths = jsonDecode(input) as Map<String, dynamic>;
    _require(
      paths.length == 2 &&
          paths.keys.toSet().containsAll(['backup', 'recoveryKey']),
    );
    backup = File(paths['backup'] as String).absolute;
    keyFile = File(paths['recoveryKey'] as String).absolute;
    for (final file in [backup, keyFile]) {
      _require(
        await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file,
      );
      _require(await file.resolveSymbolicLinks() == file.path);
    }
    _require(backup.path != keyFile.path && await keyFile.length() <= 256);
    backupBefore = await _digest(backup);
    keyBefore = await _digest(keyFile);
    root = await Directory.systemTemp.createTemp('aim-owner-export-verify-');
    _require((await root.stat()).mode & 0x3f == 0);
    final now = DateTime.now().toUtc();
    final target = '${root.path}/target';
    repo = await EncryptedInformationRepository.open(
      target,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
    final recovery = await repo.backups.readRecoveryKeyFrom(keyFile.path);
    late BackupContents restored;
    await service.owner.restoreLibrary(() async {
      restored = await repo!.backups.restoreFrom(backup!.path, recovery);
    });
    final attachmentRefs = restored.attachments
        .where((v) => v.available)
        .map((v) => v.reference)
        .toList();
    for (final ref in attachmentRefs) {
      await service.owner.readInformationAttachment(ref);
    }
    final snapshot = _snapshot(repo);
    _require(
      service.owner.sessions.isEmpty && !repo.grantHistory.any((v) => v.active),
    );
    _require(
      repo.informationFileDeliveries.every(
        (v) => !v.runtime && v.lease == null && !v.holdsCopy,
      ),
    );
    await service.close();
    service = null;
    await repo.close();
    repo = null;
    repo = await EncryptedInformationRepository.open(
      target,
      keys,
      clock: () => now,
    );
    service = InformationService(repository: repo, clock: () => now);
    _require(_snapshot(repo) == snapshot);
    for (final ref in attachmentRefs) {
      await service.owner.readInformationAttachment(ref);
    }
    _require(
      service.owner.sessions.isEmpty && !repo.grantHistory.any((v) => v.active),
    );
    verified = true;
  } on StorageFailure catch (error) {
    // Only known public error codes; no exception strings/stack traces/paths.
    status =
        {
          'invalid_backup',
          'invalid_recovery_key',
          'unsupported_backup',
          'backup_capacity_exceeded',
          'attachment_integrity_failed',
        }.contains(error.code)
        ? error.code
        : 'verification_failed';
  } on Object {
    status = 'verification_failed';
  } finally {
    try {
      await service?.close();
      await repo?.close();
      if (backupBefore != null && keyBefore != null) {
        unchanged =
            base64Encode(await _digest(backup!)) ==
                base64Encode(backupBefore) &&
            base64Encode(await _digest(keyFile!)) == base64Encode(keyBefore);
      }
      if (root != null) {
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        _require(
          !await FileSystemEntity.isLink(root.path) &&
              (await root.resolveSymbolicLinks()).startsWith(
                '$parent/aim-owner-export-verify-',
              ),
        );
        await root.delete(recursive: true);
        cleaned = !await root.exists();
      } else {
        cleaned = true;
      }
    } on Object {
      cleaned = false;
    }
    keys.value?.fillRange(0, keys.value!.length, 0);
  }
  final passed = verified && unchanged && cleaned;
  stdout.writeln(
    jsonEncode({
      'status': passed ? 'verified' : status,
      'restoredAndReopened': verified,
      'inputsUnchanged': unchanged,
      'temporaryLibraryRemoved': cleaned,
      'originalLibraryOpened': false,
      'keychainAccessed': false,
      'contentReported': false,
    }),
  );
  if (!passed) exitCode = 1;
}
