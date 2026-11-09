import 'dart:io';
import 'dart:convert';
import 'package:info_desktop/backups.dart';
import 'package:info_storage/info_storage.dart';

/// Only the OS panels/leases are substituted. The production SQLCipher
/// journal, native no-overwrite publisher and TLS backup service still run.
class SyntheticBackupPicker extends BackupFilePicker {
  String? keyOutput, archiveOutput, archiveInput, keyInput;
  int stages = 0, keyPicks = 0;
  bool scoped = false, failBookmark = false, cancelReselect = false;
  int leases = 0, stopped = 0, reselections = 0;
  @override
  Future<String?> recoveryKeyOutput() async {
    keyPicks++;
    return keyOutput;
  }

  @override
  Future<String?> backupOutput() async => archiveOutput;
  @override
  Future<String?> backupInput() async => archiveInput;
  @override
  Future<String?> recoveryKeyInput() async => keyInput;
  @override
  Future<BackupStaging?> prepareStaging(String path) async {
    stages++;
    final dir = await File(path).parent.createTemp('.synthetic-backup-');
    if ((await Process.run('/bin/chmod', ['700', dir.path])).exitCode != 0) {
      throw StateError('Synthetic staging unavailable');
    }
    return BackupStaging(
      dir.path,
      'synthetic-$stages',
      stagingBookmark: scoped ? base64Encode([1, 2, 3]) : null,
    );
  }

  @override
  Future<void> releaseStaging(BackupStaging staging) async {
    if (await Directory(staging.directory).exists()) {
      await Directory(staging.directory).delete(recursive: true);
    }
  }

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> directory) async {}
  @override
  Future<String> outputBookmark(BackupStaging staging) async {
    if (failBookmark) throw const StorageFailure('backup_access_required');
    return base64Encode([4, 5, 6]);
  }

  @override
  Future<String> acquireAccess(
    Map<String, String> access, {
    required bool needsOutput,
  }) async {
    if (needsOutput && access['outputBookmark']!.isEmpty) {
      throw const StorageFailure('backup_access_required');
    }
    leases++;
    return 'lease-$leases';
  }

  @override
  Future<void> releaseAccess(String token) async {
    stopped++;
  }

  @override
  Future<String?> reselectOutput(String path) async {
    reselections++;
    if (!await File(path).exists()) {
      throw const StorageFailure('backup_access_required');
    }
    return cancelReselect ? null : base64Encode([7, 8, 9]);
  }
}
