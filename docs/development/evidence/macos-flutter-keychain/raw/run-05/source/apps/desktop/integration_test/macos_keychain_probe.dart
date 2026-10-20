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
    await WidgetsBinding.instance.endOfFrame;
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
  try {
    if (mode == 'cleanup') {
      await _channel.invokeMethod<void>('qaDelete');
      _check(await keys.read() == null, 'QA key still present after cleanup');
      facts['ownedKeyDeletedAndAbsenceVerified'] = true;
      await platform.terminate();
      return;
    }
    final db = File('$canonical/library/library.db');
    List<int>? before;
    if (mode != 'create') {
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
    bootstrap = DesktopBootstrap(
      platform: platform,
      port: 0,
      openLibrary: () async {
        try {
          final repo = await EncryptedInformationRepository.open(
            '$canonical/library',
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
        } on StorageFailure catch (error) {
          failureCode = error.code;
          rethrow;
        }
      },
    );
    final starting = bootstrap.start();
    runApp(DesktopLauncher(bootstrap: bootstrap));
    await starting;
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
    if (mode == 'upgrade') facts['upgradeAccess'] = 'preserved';
    facts['startupAfterFinalAttempt'] = 'ready';
    await bootstrap.runtime!.quit();
  } catch (error) {
    facts.addAll({
      'failed': true,
      'errorType': error.runtimeType.toString(),
      if (error is StateError) 'checkFailure': error.message.toString(),
      'storageFailure': failureCode,
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
    stderr.writeln('MAC_KEYCHAIN_FAILED=${error.runtimeType}');
    await bootstrap?.runtime?.stop();
    exit(1);
  }
}
