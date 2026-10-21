// Ordinary Release Flutter QA entry, built ONLY in an isolated source copy.
// Actual production key adapter, Security.framework store, SQLCipher and
// startup/lifetime implementations. Driver injects a unique QA identity and
// fixture-only native deletion/malformed/wrong-key methods into that copy.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'support/macos_keychain_backup.dart';

const _channel = MethodChannel('agent_info_manage/database_key');

class _Keys implements DatabaseKeyStore {
  final delegate = MacOsDatabaseKeyStore(_channel.invokeMethod<Object?>);
  int reads = 0, creates = 0;
  @override
  Future<List<int>?> read() {
    reads++;
    return delegate.read();
  }

  @override
  Future<void> create(List<int> key) {
    creates++;
    return delegate.create(key);
  }
}

class _Platform implements DesktopPlatform {
  final native = NativeDesktopPlatform();
  late Future<void> Function(DesktopEvent) event;
  Future<void> Function()? beforeTerminate;
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) {
    event = onEvent;
    return native.initialize(onEvent);
  }

  @override
  String? get openedRequestId => native.openedRequestId;
  @override
  Future<bool> hideWindow() => native.hideWindow();
  @override
  Future<void> showWindow() => native.showWindow();
  @override
  Future<bool> notifyNewRequest(String id) => native.notifyNewRequest(id);
  @override
  Future<bool> notifyTest() => native.notifyTest();
  @override
  Future<DesktopAvailability> readAvailability() => native.readAvailability();
  @override
  Future<DesktopAvailability> requestNotificationPermission() =>
      native.requestNotificationPermission();
  @override
  Future<void> terminate() async {
    await beforeTerminate?.call();
    await native.terminate();
  }
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var flutterErrors = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final mode = Platform.environment['INFO_MAC_KEYCHAIN_MODE'];
  const modes = {
    'create',
    'reopen',
    'missing',
    'malformed',
    'wrong',
    'corrupt',
    'cleanup',
    'upgrade',
    'upgrade-interactive',
    'backup-export',
    'backup-restore',
    'backup-reopen',
    'access-success',
    'access-denied',
    'access-quit',
    'access-close',
    'locked-recover',
    'locked-exit',
    'locked-cleanup',
  };
  final owner = Platform.environment['INFO_MAC_KEYCHAIN_OWNER'];
  if (!Platform.isMacOS ||
      !modes.contains(mode) ||
      owner == null ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
    exit(64);
  }
  final supplied = Platform.environment['INFO_MAC_KEYCHAIN_ROOT'];
  final root = supplied == null
      ? await Directory.systemTemp.createTemp('aim-mac-keychain-')
      : Directory(supplied);
  final canonical = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  _check(
    canonical.startsWith('$temp/aim-mac-keychain-') &&
        root.path.split('/').last.startsWith('aim-mac-keychain-'),
    'Foreign QA root',
  );
  final marker = File('$canonical/.qa-owner');
  if (supplied == null) {
    await marker.writeAsString(owner, flush: true);
  } else {
    _check(await marker.readAsString() == owner, 'Foreign QA owner');
  }
  stdout.writeln('MAC_KEYCHAIN_ROOT=$canonical');
  final report = File('$canonical/$mode-result.json');
  final facts = <String, Object?>{'mode': mode};
  final keys = _Keys();
  final platform = _Platform();
  DesktopBootstrap? bootstrap;
  EncryptedInformationRepository? opened;
  var closes = 0;
  var failureCode = '';
  platform.beforeTerminate = () async {
    // Exercise a pending frame after data closes but before Cocoa terminates.
    if (mode != 'cleanup' && mode != 'locked-cleanup') {
      await WidgetsBinding.instance.endOfFrame;
    }
    _check(
      flutterErrors == 0,
      'Flutter reported an exception during this scenario',
    );
    facts.addAll({
      'flutterErrors': flutterErrors,
      'nativeTerminationRequested': true,
      'libraryCloses': closes,
      'keyReads': keys.reads,
      'keyCreates': keys.creates,
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
  };
  Future<Map<String, dynamic>> privateFixture(String method) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(method, {
      'root': canonical,
      'owner': owner,
    });
    _check(result != null, 'Private Keychain result missing');
    return result!;
  }

  try {
    if (mode == 'locked-cleanup') {
      final result = await privateFixture('qaPrivateCleanup');
      _check(
        result['ownedKeychainDeleted'] == true &&
            result['searchListAndDefaultRestored'] == true,
        'Owned Keychain cleanup incomplete',
      );
      facts.addAll(result);
      await platform.terminate();
      return;
    }
    if (mode == 'cleanup') {
      await _channel.invokeMethod<void>('qaDelete');
      _check(await keys.read() == null, 'QA key still present after cleanup');
      facts['ownedKeyDeletedAndAbsenceVerified'] = true;
      await platform.terminate();
      return;
    }
    final targetBackup = mode == 'backup-restore' || mode == 'backup-reopen';
    final libraryPath = '$canonical/${targetBackup ? 'restored' : 'library'}';
    final db = File('$libraryPath/library.db');
    List<int>? before;
    if (!{
      'create',
      'backup-export',
      'backup-restore',
      'locked-recover',
      'locked-exit',
    }.contains(mode)) {
      _check(await db.exists(), 'Existing database required');
      before = await db.readAsBytes();
    }
    if (mode == 'missing' || mode == 'malformed' || mode == 'wrong') {
      await _channel.invokeMethod<void>(switch (mode) {
        'missing' => 'qaDelete',
        'malformed' => 'qaMalformed',
        _ => 'qaWrong',
      });
    } else if (mode == 'corrupt') {
      final damaged = List<int>.of(before!);
      damaged[0] ^= 0xff;
      await db.writeAsBytes(damaged, flush: true);
    }
    final guarded = await db.exists() ? await db.readAsBytes() : null;
    final interactiveUpgrade = mode == 'upgrade-interactive';
    final ownerAccess = mode!.startsWith('access-') || interactiveUpgrade;
    var actualOwnerAccessAttempts = 0;
    final raw = sql.sqlite3.openInMemory();
    try {
      final version = raw
          .select('PRAGMA cipher_version')
          .single
          .values
          .single
          .toString();
      _check(version.startsWith('4.'), 'SQLCipher 4 unavailable');
      facts['sqlCipherVersion'] = version;
    } finally {
      raw.close();
    }
    if (mode == 'locked-recover' || mode == 'locked-exit') {
      final prepared = await privateFixture('qaPrivatePrepare');
      _check(
        prepared['created'] == true &&
            prepared['unlocked'] == true &&
            prepared['defaultUnchanged'] == true,
        'Private Keychain preparation failed',
      );
      Future<DesktopLibrary> openPrivateLibrary() async {
        final repo = await EncryptedInformationRepository.open(
          libraryPath,
          keys,
        );
        opened = repo;
        return DesktopLibrary(
          service: InformationService(repository: repo),
          close: () async {
            await repo.close();
            closes++;
          },
        );
      }

      bootstrap = DesktopBootstrap(
        platform: platform,
        port: 0,
        openLibrary: openPrivateLibrary,
      );
      final initial = bootstrap.start();
      runApp(DesktopLauncher(bootstrap: bootstrap));
      await initial;
      _check(
        bootstrap.state == DesktopStartupState.ready,
        'Initial private library unavailable',
      );
      final originalKey = List<int>.of((await keys.read())!);
      final service = bootstrap.library!.service;
      final item = await service.owner.createInformation(
        'Locked Keychain fixture',
        '',
        [const FieldInput('Text', '', 'synthetic locked keychain value')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('locked keychain fixture');
      final request = service.agent.request(session, 'synthetic read', [field]);
      service.owner.approve(request.id, [field]);
      final token = service.agent.claim(session, request.id).token;
      _check(
        await service.agent.read(token, field) ==
            'synthetic locked keychain value',
        'Initial approved read failed',
      );
      // Deliberate in-process library restart; not a physical app restart.
      runApp(const SizedBox());
      await WidgetsBinding.instance.endOfFrame;
      await bootstrap.runtime!.stop();
      bootstrap.runtime!.dispose();
      bootstrap.dispose();
      final originalDb = await db.readAsBytes();
      final locked = await privateFixture('qaPrivateLock');
      _check(locked['locked'] == true, 'Private keychain did not really lock');
      facts.addAll({
        'actualPrivateKeychainLocked': true,
        'defaultKeychainUnchanged': true,
      });
      bootstrap = DesktopBootstrap(
        platform: platform,
        port: 0,
        openLibrary: openPrivateLibrary,
      );
      final restarting = bootstrap.start();
      runApp(DesktopLauncher(bootstrap: bootstrap));
      await restarting;
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) await bootstrap.start();
        _check(
          bootstrap.state == DesktopStartupState.failed &&
              bootstrap.systemKeyUnavailable &&
              bootstrap.library == null &&
              bootstrap.runtime == null &&
              bootstrap.boundPort == null &&
              keys.creates == 1 &&
              listEquals(await db.readAsBytes(), originalDb),
          'Locked keychain open/retry changed data or published service',
        );
        _check(
          (await privateFixture('qaPrivateStatus'))['locked'] == true,
          'Read unlocked the private keychain',
        );
        await WidgetsBinding.instance.endOfFrame;
        final texts = <String>[];
        void visit(Element element) {
          if (element.widget case Text(:final data?)) texts.add(data);
          element.visitChildren(visit);
        }

        visit(WidgetsBinding.instance.rootElement!);
        _check(
          texts.any((t) => t.contains('无法访问系统钥匙串')) && texts.contains('重试启动'),
          'Actual locked failure screen missing',
        );
      }
      facts.addAll({
        'lockedStartupAttempts': 2,
        'lockedFailureTextRendered': true,
        'databaseBytesPreservedWhileLocked': true,
        'noReplacementKeyCreated': true,
        'noEndpointPublishedWhileLocked': true,
      });
      if (mode == 'locked-exit') {
        facts['keychainStillLockedBeforeNormalQuit'] = true;
        await platform.event(DesktopEvent.quit);
        return;
      }
      _check(
        (await privateFixture('qaPrivateUnlock'))['unlocked'] == true,
        'Owned password did not unlock private keychain',
      );
      _check(
        listEquals(await keys.read(), originalKey),
        'Original private key changed',
      );
      originalKey.fillRange(0, originalKey.length, 0);
      await bootstrap.start();
      _check(
        bootstrap.state == DesktopStartupState.ready && keys.creates == 1,
        'Unlock retry did not recover original database',
      );
      final restored = bootstrap.library!.service;
      _check(
        restored.owner.information.single.id == item.id &&
            restored.owner.information.single.fields.single.id ==
                field.fieldId &&
            restored.owner.information.single.fields.single.value ==
                'synthetic locked keychain value',
        'Stored information changed after unlock',
      );
      var denied = false;
      try {
        await restored.agent.read(token, field);
      } on AccessFailure {
        denied = true;
      }
      _check(
        denied &&
            opened!.grantHistory.length == 1 &&
            !opened!.grantHistory.single.active &&
            opened!.accessRecords.any(
              (r) => r.outcome == AccessOutcome.allowed,
            ),
        'Old authority or history invalid after unlock',
      );
      facts.addAll({
        'unlockedOriginalKeyPreserved': true,
        'retryRecoveredStoredIdentityAndValue': true,
        'oldAuthorityRefusedAfterUnlock': true,
        'endedGrantAndReadHistoryPreserved': true,
        'port': bootstrap.boundPort,
      });
      await bootstrap.runtime!.quit();
      return;
    }
    bootstrap = DesktopBootstrap(
      platform: platform,
      port: 0,
      openLibraryWithKeyAccess: ownerAccess
          ? () async {
              if (interactiveUpgrade) actualOwnerAccessAttempts++;
              final recovered = MacOsDatabaseKeyStore((method, arguments) {
                _check(method == 'read', 'Recovery tried to replace a key');
                return _channel.invokeMethod<Object?>(
                  'readWithInteraction',
                  arguments,
                );
              });
              final repo = await EncryptedInformationRepository.open(
                libraryPath,
                recovered,
              );
              opened = repo;
              return DesktopLibrary(
                service: InformationService(repository: repo),
                close: () async {
                  await repo.close();
                  closes++;
                },
              );
            }
          : null,
      openLibrary: () async {
        if (ownerAccess && !interactiveUpgrade) {
          throw const StorageFailure('key_unavailable');
        }
        try {
          final repo = await EncryptedInformationRepository.open(
            libraryPath,
            keys,
          );
          opened = repo;
          return DesktopLibrary(
            service: InformationService(
              repository: repo,
              informationDeliveryFiles: mode.startsWith('backup-')
                  ? NativeInformationDeliveryFiles()
                  : null,
            ),
            close: () async {
              await repo.close();
              closes++;
            },
          );
        } on StorageFailure catch (error) {
          failureCode = error.code;
          rethrow;
        }
      },
    );
    final starting = bootstrap.start();
    runApp(DesktopLauncher(bootstrap: bootstrap));
    await starting;
    if (interactiveUpgrade) {
      _check(
        bootstrap.canRequestKeyAccess,
        'Changed signature did not require owner access',
      );
      _check(
        keys.creates == 0 && listEquals(await db.readAsBytes(), guarded),
        'Ordinary failed upgrade replaced original data/key',
      );
      final phaseFile = File('$canonical/interactive-phase.json');
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      var lastPhase = '';
      var failedAttempts = 0;
      var failedCheckedAt = 0;
      while (bootstrap.state != DesktopStartupState.ready) {
        _check(
          DateTime.now().isBefore(deadline),
          'Interactive upgrade deadline',
        );
        if (actualOwnerAccessAttempts > failedCheckedAt &&
            bootstrap.state == DesktopStartupState.failed &&
            !bootstrap.keyAccessPending) {
          _check(
            bootstrap.library == null &&
                bootstrap.boundPort == null &&
                keys.creates == 0 &&
                listEquals(await db.readAsBytes(), guarded),
            'Failed system access changed data/key or published endpoint',
          );
          failedCheckedAt = actualOwnerAccessAttempts;
          failedAttempts++;
        }
        final current = jsonEncode({
          'state': bootstrap.state.name,
          'pending': bootstrap.keyAccessPending,
          'attempts': actualOwnerAccessAttempts,
          'failedAttempts': failedAttempts,
          'canRequestAccess': bootstrap.canRequestKeyAccess,
          'portPublished': bootstrap.boundPort != null,
        });
        if (current != lastPhase) {
          await phaseFile.writeAsString(current, flush: true);
          stdout.writeln('MAC_KEYCHAIN_INTERACTIVE_STATE=$current');
          lastPhase = current;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _check(
        actualOwnerAccessAttempts >= 1,
        'Must observe an actual owner access action before system approval',
      );
      facts.addAll({
        'systemDecisionIsFixture': false,
        'ownerButtonPhysicallyInvoked': true,
        'actualOwnerAccessAttempts': actualOwnerAccessAttempts,
        // A failed return does not reveal which system button the owner used.
        // The owner requested allow-only acceptance, without a denial prerequisite.
        'actualFailedAttempts': failedAttempts,
        'failedUpgradeDatabasePreserved': true,
        'originalDatabaseRecoveredAfterSystemApproval': true,
      });
    } else if (ownerAccess) {
      _check(bootstrap.canRequestKeyAccess, 'Owner recovery not offered');
      await WidgetsBinding.instance.endOfFrame;
      VoidCallback? action;
      void visit(Element element) {
        if (element.widget case TextButton(:final child, :final onPressed)) {
          if (child is Text && child.data == '请求钥匙串访问') action = onPressed;
        }
        element.visitChildren(visit);
      }

      visit(WidgetsBinding.instance.rootElement!);
      _check(action != null, 'Owner recovery button missing');
      action!();
      await WidgetsBinding.instance.endOfFrame;
      if (mode == 'access-quit' || mode == 'access-close') {
        _check(
          bootstrap.keyAccessPending,
          'Simulated authorization did not wait',
        );
        // A separate native channel must still answer while keyQueue waits.
        await platform.readAvailability().timeout(const Duration(seconds: 3));
        _check(
          bootstrap.boundPort == null &&
              bootstrap.library == null &&
              listEquals(await db.readAsBytes(), guarded),
          'Waiting authorization published or changed data',
        );
        facts.addAll({
          'systemDecisionIsFixture': true,
          'ownerButtonInvoked': true,
          'nativeMainQueueResponsive': true,
          'databaseBytesPreserved': true,
          'noEndpointPublished': true,
          'keyAccessPendingAtQuit': true,
        });
        if (mode == 'access-close') {
          await platform.event(DesktopEvent.closeWindow);
        } else {
          await bootstrap.quitKeyAccess();
        }
        return;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (bootstrap.state == DesktopStartupState.starting &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      facts.addAll({
        'systemDecisionIsFixture': true,
        'ownerButtonInvoked': true,
      });
      if (mode == 'access-denied') {
        _check(
          bootstrap.state == DesktopStartupState.failed &&
              bootstrap.canRequestKeyAccess &&
              bootstrap.library == null &&
              bootstrap.boundPort == null &&
              listEquals(await db.readAsBytes(), guarded),
          'Denied recovery altered database or lost retry',
        );
        facts.addAll({
          'deniedRecoveryRetryable': true,
          'databaseBytesPreserved': true,
          'noEndpointPublished': true,
        });
        await platform.event(DesktopEvent.quit);
        return;
      }
    }
    if (mode.startsWith('backup-')) {
      _check(
        bootstrap.state == DesktopStartupState.ready,
        'Backup library failed to start',
      );
      _check(
        keys.creates == (mode == 'backup-reopen' ? 0 : 1),
        'Unexpected backup key creation',
      );
      facts['port'] = bootstrap.boundPort;
      facts.addAll(
        await runMacKeychainBackup(bootstrap, opened!, keys, canonical, mode),
      );
      await bootstrap.runtime!.quit();
      return;
    }
    final negative =
        {'missing', 'malformed', 'wrong', 'corrupt'}.contains(mode) ||
        (mode == 'upgrade' && bootstrap.state == DesktopStartupState.failed);
    if (negative) {
      final expected = {'missing', 'malformed', 'upgrade'}.contains(mode)
          ? 'key_unavailable'
          : 'library_unavailable';
      for (var attempt = 0; attempt < 2; attempt++) {
        if (attempt > 0) await bootstrap.start();
        _check(
          bootstrap.state == DesktopStartupState.failed &&
              failureCode == expected,
          'Expected storage failure was not preserved',
        );
        _check(
          bootstrap.boundPort == null &&
              bootstrap.library == null &&
              bootstrap.runtime == null &&
              !bootstrap.cleanupPending &&
              closes == 0,
          'Failed startup published endpoint or retained resources',
        );
        _check(
          keys.creates == 0 && listEquals(await db.readAsBytes(), guarded),
          'Failed open/retry changed database or created replacement key',
        );
        _check(
          bootstrap.systemKeyUnavailable == (expected == 'key_unavailable'),
          'Failure screen selected wrong diagnosis',
        );
        await WidgetsBinding.instance.endOfFrame;
        final texts = <String>[];
        void visit(Element element) {
          if (element.widget case Text(:final data?)) texts.add(data);
          element.visitChildren(visit);
        }

        visit(WidgetsBinding.instance.rootElement!);
        _check(
          texts.any((s) => s.contains('原有资料不会被重建或覆盖')) &&
              texts.contains('重试启动'),
          'Production error screen did not render',
        );
      }
      facts.addAll({
        if (mode == 'upgrade') 'upgradeAccess': 'denied',
        'startup': 'failed',
        'storageFailure': failureCode,
        'retryAttempts': 2,
        'databaseBytesPreserved': true,
        'noEndpointPublished': true,
        'productionErrorTextRendered': true,
        'noReplacementKeyCreated': true,
      });
      if (mode != 'corrupt') {
        await platform.event(DesktopEvent.quit);
        return;
      }
      // Restore only the bytes we deliberately damaged, inside the owned QA
      // directory. Production code never performs this repair automatically.
      await db.writeAsBytes(before!, flush: true);
      await bootstrap.start();
      facts['controlledBytesRestoredThenRetrySucceeded'] = true;
    }
    _check(
      bootstrap.state == DesktopStartupState.ready &&
          bootstrap.boundPort != null,
      'Startup did not become ready',
    );
    facts['port'] = bootstrap.boundPort;
    final service = bootstrap.library!.service;
    final private = File('$canonical/synthetic-association.json');
    if (mode == 'create') {
      _check(
        keys.creates == 1 && keys.reads == 2,
        'Fresh key was not created and reread',
      );
      final item = await service.owner.createInformation(
        'Synthetic Keychain',
        '',
        [const FieldInput('Text', '', 'synthetic keychain fixture')],
      );
      final field = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('synthetic Keychain QA');
      final request = service.agent.request(session, 'synthetic only', [field]);
      service.owner.approve(request.id, [field]);
      final token = service.agent.claim(session, request.id).token;
      _check(
        await service.agent.read(token, field) == 'synthetic keychain fixture',
        'Approved read failed',
      );
      await private.writeAsString(
        jsonEncode({'token': token, 'item': item.id, 'field': field.fieldId}),
        flush: true,
      );
      _check(
        (await Process.run('/bin/chmod', ['600', private.path])).exitCode == 0,
        'Private fixture permissions unavailable',
      );
      facts['createdInformationAndApprovedRead'] = true;
    } else {
      final old = jsonDecode(await private.readAsString()) as Map;
      final item = service.owner.information.single;
      _check(
        item.id == old['item'] &&
            item.fields.single.id == old['field'] &&
            item.fields.single.value == 'synthetic keychain fixture',
        'Stored identity/value changed',
      );
      var denied = false;
      try {
        await service.agent.read(
          old['token'] as String,
          FieldRef(old['item'] as String, old['field'] as String),
        );
      } on AccessFailure {
        denied = true;
      }
      _check(
        denied &&
            opened!.grantHistory.length == 1 &&
            !opened!.grantHistory.single.active &&
            opened!.grantHistory.single.events.last.kind ==
                GrantEventKind.applicationClosed &&
            opened!.accessRecords.any(
              (r) => r.outcome == AccessOutcome.allowed,
            ),
        'Old authority or history invalid',
      );
      _check(keys.creates == 0, 'Reopen created a replacement key');
      facts.addAll({
        'storedIdentityAndValuePreserved': true,
        'oldAuthorityRefused': true,
        'endedGrantAndAllowedReadPreserved': true,
      });
    }
    if (mode == 'upgrade' || interactiveUpgrade) {
      facts['upgradeAccess'] = interactiveUpgrade
          ? 'owner-approved'
          : 'preserved';
    }
    facts['startupAfterFinalAttempt'] = 'ready';
    await bootstrap.runtime!.quit();
  } catch (error, stack) {
    facts.addAll({
      'failed': true,
      'errorType': error.runtimeType.toString(),
      'stackTrace': stack.toString(),
      if (error is StateError) 'checkFailure': error.message.toString(),
      'storageFailure': failureCode,
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
    stderr.writeln('MAC_KEYCHAIN_FAILED=${error.runtimeType}');
    await bootstrap?.runtime?.stop();
    exit(1);
  }
}
