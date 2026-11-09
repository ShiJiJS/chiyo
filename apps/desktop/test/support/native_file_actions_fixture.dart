import 'dart:async';
import 'dart:io';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/backups.dart';

class SyntheticOutputPicker extends BackupFilePicker {
  String? output;
  bool failRelease = false,
      failBookmark = false,
      requiresAccess = false,
      denyAccess = false;
  int panels = 0, opens = 0, closes = 0;
  Completer<void>? panelStarted, panelDone;
  @override
  Future<String?> backupOutput() async => null;
  @override
  Future<String?> backupInput() async => null;
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> ownerFileOutput(String name) async {
    panels++;
    panelStarted?.complete();
    await panelDone?.future;
    return output;
  }

  @override
  Future<BackupStaging?> prepareStaging(String path) async {
    final d = await Directory(File(path).parent.path).createTemp('own-stage-');
    return BackupStaging(
      d.path,
      'synthetic',
      stagingBookmark: requiresAccess ? 'synthetic-stage' : null,
    );
  }

  @override
  Future<String> outputBookmark(BackupStaging staging) async {
    if (failBookmark) throw const StorageFailure('backup_access_required');
    return 'synthetic-output';
  }

  @override
  Future<String> acquireAccess(
    Map<String, String> args, {
    required bool needsOutput,
  }) async {
    if (denyAccess) throw const StorageFailure('backup_access_required');
    opens++;
    return 'synthetic-lease';
  }

  @override
  Future<void> releaseAccess(String token) async {
    closes++;
  }

  @override
  Future<void> releaseRecordedStaging(Map<String, Object?> dir) async {
    if (failRelease) throw StateError('synthetic release');
  }

  @override
  Future<void> releaseStaging(BackupStaging s) async {
    if (failRelease) throw StateError('synthetic release');
  }

  @override
  Future<String?> reselectOutput(String path) async {
    denyAccess = false;
    return 'synthetic-output';
  }
}

class SyntheticOpenDispatcher implements OwnerFileOpenDispatcher {
  final leases = <core.InformationDeliveryLease>[];
  int launches = 0;
  bool drop = false, loseStatus = false;
  final outcomes = <String, OwnerFileDispatchOutcome>{};
  @override
  Future<OwnerFileDispatchOutcome> open(
    String id,
    String digest,
    core.InformationDeliveryLease copy,
    int length,
    String hash,
  ) async {
    launches++;
    leases.add(copy);
    await core.NativeInformationDeliveryFiles().verify(copy, length, hash);
    outcomes[id] = OwnerFileDispatchOutcome.opened;
    if (drop) throw StateError('synthetic response loss');
    return outcomes[id]!;
  }

  @override
  Future<OwnerFileDispatchOutcome?> status(String id, String digest) async =>
      loseStatus ? null : outcomes[id];
}
