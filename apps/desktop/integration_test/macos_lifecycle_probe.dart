// Ordinary signed Flutter application probe, driven by macos-lifecycle.py.
// Controlled inputs: synthetic database keys, startup gates and event triggers.
// Real boundaries: Cocoa channel, SQLCipher, app processes and loopback sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'support/macos_worker_recovery.dart';
import 'support/macos_backup_recovery.dart';

class _Keys implements DatabaseKeyStore {
  _Keys({this.missing = false});
  final bool missing;
  int reads = 0;
  int creates = 0;
  @override
  Future<List<int>?> read() async {
    reads++;
    return missing ? null : List.filled(32, 117);
  }

  @override
  Future<void> create(List<int> key) async {
    creates++;
    throw StateError('Synthetic key must already exist');
  }
}

class _Platform implements DesktopPlatform {
  final native = NativeDesktopPlatform();
  late Future<void> Function(DesktopEvent) event;
  bool terminateRequested = false;
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
    terminateRequested = true;
    await beforeTerminate?.call();
    await native.terminate();
  }
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = Platform.environment['INFO_MAC_LIFECYCLE_MODE'];
  const modes = {
    'normal',
    'hold',
    'duplicate',
    'recover',
    'key-failure',
    'port-busy',
    'quit-opening',
    'audit-failure',
    'worker-hold',
    'worker-recover',
    'backup-prepare',
    'backup-interrupt',
    'backup-recover',
  };
  if (!Platform.isMacOS || !modes.contains(mode)) exit(64);
  final supplied = Platform.environment['INFO_MAC_LIFECYCLE_ROOT'];
  final owner = Platform.environment['INFO_MAC_LIFECYCLE_OWNER'];
  if (owner == null || !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) exit(64);
  final root = supplied == null
      ? await Directory.systemTemp.createTemp('aim-mac-lifecycle-')
      : Directory(supplied);
  final canonical = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  _check(
    canonical.startsWith('$temp/aim-mac-lifecycle-') &&
        root.path.split('/').last.startsWith('aim-mac-lifecycle-'),
    'Only an owned synthetic temporary directory is accepted',
  );
  final marker = File('$canonical/.qa-owner');
  if (supplied == null) {
    await marker.writeAsString(owner, flush: true);
  } else {
    _check(await marker.readAsString() == owner, 'Foreign QA directory');
  }
  stdout.writeln('MAC_LIFECYCLE_ROOT=$canonical');
  final report = File('$canonical/$mode-result.json');
  final keys = _Keys(missing: mode == 'key-failure');
  final platform = _Platform();
  ServerSocket? occupied;
  DesktopBootstrap? bootstrap;
  EncryptedInformationRepository? opened;
  final entered = Completer<void>(), releaseOpen = Completer<void>();
  var closes = 0;
  var failureCode = '';
  try {
    final rollback = mode == 'backup-recover'
        ? checkMacBackupRollback(canonical)
        : null;
    if (mode == 'key-failure') {
      final seed = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      await seed.close();
    }
    if (mode == 'port-busy') {
      occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 47125);
    }
    bootstrap = DesktopBootstrap(
      platform: platform,
      port: occupied?.port ?? 0,
      openLibrary: () async {
        if (mode == 'quit-opening') {
          entered.complete();
          await releaseOpen.future;
        }
        try {
          final repository = await EncryptedInformationRepository.open(
            '$canonical/library',
            keys,
          );
          opened = repository;
          return DesktopLibrary(
            service: InformationService(
              repository: repository,
              informationDeliveryFiles: mode!.startsWith('worker-')
                  ? NativeInformationDeliveryFiles()
                  : null,
            ),
            close: () async {
              await repository.close();
              closes++;
            },
          );
        } on StorageFailure catch (e) {
          failureCode = e.code;
          rethrow;
        }
      },
    );
    platform.beforeTerminate = () async {
      final facts = await report.exists()
          ? jsonDecode(await report.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{'mode': mode};
      facts['nativeTerminationRequested'] = true;
      facts['libraryCloses'] = closes;
      await report.writeAsString(jsonEncode(facts), flush: true);
    };
    // Start explicitly so a real window cannot initiate a second startup.
    final starting = bootstrap.start();
    runApp(DesktopLauncher(bootstrap: bootstrap));
    Future<void>? pendingQuit;
    if (mode == 'quit-opening') {
      await entered.future;
      pendingQuit = platform.event(DesktopEvent.quit);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      _check(!platform.terminateRequested, 'Quit raced unfinished opening');
      await report.writeAsString(
        jsonEncode({'mode': mode, 'quitWaitedForOpening': true}),
      );
      releaseOpen.complete();
    }
    await starting;
    if (mode == 'quit-opening') {
      await pendingQuit;
      return;
    }
    if (mode == 'key-failure' || mode == 'duplicate' || mode == 'port-busy') {
      _check(bootstrap.state == DesktopStartupState.failed, 'Expected refusal');
      _check(
        bootstrap.library == null && !bootstrap.cleanupPending,
        'Failure retained owned resources',
      );
      if (mode == 'duplicate') {
        _check(
          keys.reads == 0 && keys.creates == 0,
          'Duplicate reached key store before exclusive lock',
        );
      }
      if (mode == 'key-failure') {
        _check(
          bootstrap.systemKeyUnavailable && keys.creates == 0,
          'Missing key did not fail closed',
        );
      }
      if (mode == 'port-busy') {
        _check(closes == 1, 'Owned library was not closed');
      }
      await occupied?.close();
      occupied = null;
      await report.writeAsString(
        jsonEncode({
          'mode': mode,
          'startup': 'failed',
          'cleanupPending': false,
          'keyReads': keys.reads,
          'keyCreates': keys.creates,
          'libraryCloses': closes,
          'storageFailure': failureCode,
        }),
      );
      await platform.event(DesktopEvent.quit);
      return;
    }
    _check(bootstrap.state == DesktopStartupState.ready, 'Startup not ready');
    if (mode!.startsWith('backup-')) {
      await runMacBackupRecovery(
        bootstrap,
        opened!,
        canonical,
        mode,
        report,
        rollback,
      );
      return;
    }
    if (mode.startsWith('worker-')) {
      await runMacWorkerRecovery(bootstrap, canonical, mode, report);
      return;
    }
    final service = bootstrap.library!.service;
    final stateFile = File('$canonical/synthetic-association.json');
    if (mode == 'recover') {
      final old = jsonDecode(await stateFile.readAsString()) as Map;
      _check(
        service.owner.information.single.fields.single.value == 'synthetic',
        'Stored information did not survive',
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
      _check(denied, 'Old authority revived');
      _check(
        opened!.grantHistory.length == 1 &&
            !opened!.grantHistory.single.active &&
            opened!.grantHistory.single.events.last.kind ==
                GrantEventKind.applicationClosed &&
            opened!.accessRecords.any(
              (r) => r.outcome == AccessOutcome.allowed,
            ),
        'Persisted grant/access history mismatch',
      );
      await report.writeAsString(
        jsonEncode({
          'mode': mode,
          'startup': 'ready',
          'port': bootstrap.boundPort,
          'oldAuthorityRefused': true,
          'storedInformationPreserved': true,
          'endedGrantAndAllowedReadPreserved': true,
        }),
      );
      await bootstrap.runtime!.quit();
      return;
    }
    final item = await service.owner.createInformation('Synthetic', '', [
      const FieldInput('Text', '', 'synthetic'),
    ]);
    final field = FieldRef(item.id, item.fields.single.id);
    final session = service.agent.openSession('synthetic lifecycle');
    final request = service.agent.request(session, 'synthetic only', [field]);
    service.owner.approve(request.id, [field]);
    final token = service.agent.claim(session, request.id).token;
    _check(
      await service.agent.read(token, field) == 'synthetic',
      'Read failed',
    );
    await stateFile.writeAsString(
      jsonEncode({'token': token, 'item': item.id, 'field': field.fieldId}),
      flush: true,
    );
    // JSON is private QA coordination, never included in published evidence.
    _check(
      (await Process.run('/bin/chmod', ['600', stateFile.path])).exitCode == 0,
      'Private fixture permissions unavailable',
    );
    if (mode == 'audit-failure') {
      final lock = sql.sqlite3.open('$canonical/library/library.db');
      try {
        lock.execute('PRAGMA key = "x\'${'75' * 32}\'"');
        lock.execute('BEGIN IMMEDIATE');
        await bootstrap.runtime!.quit();
        _check(
          bootstrap.runtime!.shutdownFailed &&
              !platform.terminateRequested &&
              closes == 0,
          'Quit acknowledged unsaved audit facts',
        );
        var refused = false;
        try {
          await service.agent.read(token, field);
        } on AccessFailure {
          refused = true;
        }
        _check(refused, 'Failed quit revived authority');
        await report.writeAsString(
          jsonEncode({
            'mode': mode,
            'auditFailurePreventedTermination': true,
            'libraryRetainedForRetry': true,
            'oldAuthorityRefused': true,
          }),
        );
        lock.execute('ROLLBACK');
      } finally {
        lock.close();
      }
      await bootstrap.runtime!.quit();
      return;
    }
    await report.writeAsString(
      jsonEncode({
        'mode': mode,
        'startup': 'ready',
        'port': bootstrap.boundPort,
        'tray': bootstrap.runtime!.availability.tray,
        'syntheticGrantRead': true,
      }),
    );
    stdout.writeln('MAC_LIFECYCLE_READY=$mode');
    final finish = File('$canonical/finish-$mode');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!await finish.exists()) {
      _check(DateTime.now().isBefore(deadline), 'Driver did not finish');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await bootstrap.runtime!.quit();
  } catch (e) {
    await report.writeAsString(
      jsonEncode({
        'mode': mode,
        'failed': true,
        'errorType': e.runtimeType.toString(),
        if (e is StateError) 'checkFailure': e.message.toString(),
        'storageFailure': failureCode,
      }),
    );
    stderr.writeln('MAC_LIFECYCLE_FAILED=${e.runtimeType}');
    // Failure cleanup is not counted as a successful native quit.
    await bootstrap?.runtime?.stop();
    await occupied?.close();
    exit(1);
  }
}
