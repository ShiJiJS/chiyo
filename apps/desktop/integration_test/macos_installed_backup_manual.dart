// Restore an actual ordinary-app export through production UI/native panels.
// The target/reference use separate memory keys; no system Keychain access.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'support/macos_keychain_backup.dart';

class _Keys implements DatabaseKeyStore {
  _Keys(this.byte);
  final int byte;
  @override
  Future<List<int>?> read() async => List.filled(32, byte);
  @override
  Future<void> create(List<int> key) async =>
      throw StateError('Existing QA key');
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() done, String phase) async {
  stdout.writeln('INSTALLED_BACKUP_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 25));
  while (!await done()) {
    check(DateTime.now().isBefore(deadline), 'UI deadline: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment, mode = env['MAC_INSTALLED_BACKUP_MODE']!;
  final owner = env['MAC_INSTALLED_BACKUP_OWNER']!;
  check({'restore', 'reopen'}.contains(mode), 'QA mode');
  final root = env['MAC_INSTALLED_BACKUP_ROOT'] == null
      ? await Directory.systemTemp.createTemp('aim-installed-backup-')
      : Directory(env['MAC_INSTALLED_BACKUP_ROOT']!);
  final canonical = await root.resolveSymbolicLinks();
  check(
    canonical.startsWith(
      '${await Directory.systemTemp.resolveSymbolicLinks()}/aim-installed-backup-',
    ),
    'Owned root',
  );
  final marker = File('$canonical/.qa-owner');
  if (mode == 'restore') await marker.writeAsString(owner);
  check(await marker.readAsString() == owner, 'Foreign root');
  stdout.writeln('INSTALLED_BACKUP_ROOT=$canonical');
  final report = File('$canonical/$mode.json');
  final facts = <String, Object?>{
    'mode': mode,
    'complete': false,
    'systemKeychainUsed': false,
  };
  Future<void> save() => report.writeAsString(jsonEncode(facts), flush: true);
  var flutterErrors = 0, closes = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  late EncryptedInformationRepository repository;
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: NativeDesktopPlatform(),
    openLibrary: () async {
      repository = await EncryptedInformationRepository.open(
        '$canonical/recipient',
        _Keys(155),
      );
      return DesktopLibrary(
        service: InformationService(repository: repository),
        backups: repository.backups,
        close: () async {
          await repository.close();
          closes++;
          facts.addAll({
            'libraryCloses': closes,
            'flutterErrors': flutterErrors,
          });
          await save();
        },
      );
    },
  );
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Bootstrap failed');
    final service = bootstrap.library!.service;
    runApp(DesktopLauncher(bootstrap: bootstrap));
    final privateBackup = File('$canonical/selected-backup.aimbackup');
    final privateKey = File('$canonical/selected-recovery.txt');
    await save();
    if (mode == 'restore') {
      check(
        await repository.backups.recipientEmpty(),
        'Nonempty initial target',
      );
      facts['initialTargetEmpty'] = true;
      await save();
      await until(
        () => service.owner.information.isNotEmpty,
        'restore-through-actual-settings-and-native-panels',
      );
      // These files become readable through actual owner selection. The env
      // paths do not grant access and are never passed to a path-grant channel.
      await File(env['MAC_INSTALLED_BACKUP_FILE']!).copy(privateBackup.path);
      await File(env['MAC_INSTALLED_BACKUP_KEY_FILE']!).copy(privateKey.path);
      facts['actualUiRestoreObserved'] = true;
    }
    final recovery = await repository.backups.readRecoveryKeyFrom(
      privateKey.path,
    );
    final preview = await repository.backups.inspect(
      privateBackup.path,
      recovery,
    );
    check(
      preview.formatVersion == 9 &&
          preview.informationCount == 2 &&
          preview.attachmentBytes == 3073,
      'Unexpected ordinary export',
    );
    final reference = await EncryptedInformationRepository.open(
      '$canonical/reference',
      _Keys(156),
    );
    final referenceService = InformationService(repository: reference);
    try {
      final contents = await reference.backups.inspect(
        privateBackup.path,
        recovery,
      );
      await referenceService.owner.restoreLibrary(
        () => reference.backups.restore(contents),
      );
      facts['comparison'] = await compareMacBackupRecipients(
        service,
        repository,
        referenceService,
        reference,
        preview,
      );
    } finally {
      await referenceService.close();
      await reference.close();
      await Directory('$canonical/reference').delete(recursive: true);
    }
    final database = File('$canonical/recipient/library.db');
    final before = await database.readAsBytes();
    var nonempty = '';
    try {
      await repository.backups.restoreFrom(privateBackup.path, recovery);
    } on StorageFailure catch (error) {
      nonempty = error.code;
    }
    check(
      nonempty == 'recipient_not_empty' &&
          listEquals(before, await database.readAsBytes()),
      'Nonempty restore changed target',
    );
    facts['nonemptyTargetRefusedWithoutByteChange'] = true;
    if (mode == 'reopen') {
      final item = service.owner.information.firstWhere(
        (i) => i.fields.any((f) => f.kind != FieldKind.file),
      );
      final field = item.fields.firstWhere((f) => f.kind != FieldKind.file);
      final session = service.agent.openSession('Mac 普通备份恢复后重新申请');
      if (repository.requestHistory.isNotEmpty) {
        var denied = false;
        try {
          service.agent.claim(session, repository.requestHistory.first.id);
        } on AccessFailure {
          denied = true;
        }
        check(denied, 'Historical request claim revived');
        facts['historicalRequestRejectedInNewSession'] = true;
      }
      final request = service.agent.request(session, '恢复后重新申请合成字段', [
        FieldRef(item.id, field.id),
      ]);
      facts['waitingForActualApproval'] = true;
      await save();
      await until(
        () =>
            service.owner.requests
                .singleWhere((r) => r.id == request.id)
                .state !=
            AccessRequestState.pending,
        'fresh-field-request-approved-in-actual-ui',
      );
      final grant = service.agent.claim(session, request.id);
      check(
        await service.agent.read(grant.token, FieldRef(item.id, field.id)) ==
            field.value,
        'Fresh approved value differs',
      );
      service.owner.revoke(request.id);
      facts.remove('waitingForActualApproval');
      facts['freshUiApprovalReadAndRevoke'] = true;
    }
    facts['complete'] = true;
    await save();
    stdout.writeln('INSTALLED_BACKUP_COMPLETE=$mode');
  } catch (error) {
    facts.addAll({'failed': true, 'error': error.toString()});
    await save();
    stderr.writeln('INSTALLED_BACKUP_FAILED=$error');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
