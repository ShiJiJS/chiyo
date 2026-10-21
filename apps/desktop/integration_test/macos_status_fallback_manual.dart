// Actual close buttons with a real status item made unavailable in a QA copy.
// Native observation never activates the window; no system Keychain is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/desktop_bootstrap.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<List<int>?> read() async => List.filled(32, 157);
  @override
  Future<void> create(List<int> key) async => throw StateError('QA key exists');
}

class _ObservedPlatform extends NativeDesktopPlatform {
  final events = <String>[];
  final hides = <bool>[];
  @override
  Future<DesktopAvailability> initialize(
    Future<void> Function(DesktopEvent) onEvent,
  ) => super.initialize((event) async {
    events.add(event.name);
    await onEvent(event);
  });
  @override
  Future<bool> hideWindow() async {
    final result = await super.hideWindow();
    hides.add(result);
    return result;
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> until(FutureOr<bool> Function() ready, String phase) async {
  stdout.writeln('STATUS_FALLBACK_PHASE=$phase');
  final deadline = DateTime.now().add(const Duration(minutes: 20));
  while (!await ready()) {
    check(DateTime.now().isBefore(deadline), 'Deadline: $phase');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final mode = env['MAC_STATUS_MODE']!;
  final owner = env['MAC_STATUS_OWNER']!;
  final regression = env['MAC_STATUS_EXPECT_REGRESSION'] == '1';
  check({'close', 'reopen'}.contains(mode), 'QA mode');
  check(RegExp(r'^[a-f0-9]{32}$').hasMatch(owner), 'QA owner');
  final root = env['MAC_STATUS_ROOT'] == null
      ? await Directory.systemTemp.createTemp('aim-status-fallback-')
      : Directory(env['MAC_STATUS_ROOT']!);
  final canonical = await root.resolveSymbolicLinks();
  check(
    canonical.startsWith(
      '${await Directory.systemTemp.resolveSymbolicLinks()}/aim-status-fallback-',
    ),
    'Owned root',
  );
  final marker = File('$canonical/.qa-owner');
  if (mode == 'close') await marker.writeAsString(owner);
  check(await marker.readAsString() == owner, 'Foreign root');
  stdout.writeln('STATUS_FALLBACK_ROOT=$canonical');
  final report = File('$canonical/$mode.json');
  final facts = <String, Object?>{
    'mode': mode,
    'complete': false,
    'expectRegression': regression,
    'systemKeychainUsed': false,
  };
  final platform = _ObservedPlatform();
  var closes = 0, flutterErrors = 0;
  Future<void> save() async {
    facts.addAll({
      'libraryCloses': closes,
      'flutterErrors': flutterErrors,
      'nativeEvents': platform.events,
      'nativeHideResults': platform.hides,
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
  }

  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  late EncryptedInformationRepository repository;
  final bootstrap = DesktopBootstrap(
    port: 0,
    platform: platform,
    openLibrary: () async {
      repository = await EncryptedInformationRepository.open(
        '$canonical/library',
        _Keys(),
      );
      return DesktopLibrary(
        service: InformationService(repository: repository),
        backups: repository.backups,
        close: () async {
          await repository.close();
          closes++;
          await save();
        },
      );
    },
  );
  const channel = MethodChannel('agent_info_manage/desktop');
  Future<Map<Object?, Object?>> observe() async => (await channel
      .invokeMapMethod<Object?, Object?>('qaObserveStatusWindow'))!;
  Future<void> visible(bool value) =>
      channel.invokeMethod<void>('qaSetStatusVisible', value);
  try {
    await bootstrap.start();
    check(bootstrap.state == DesktopStartupState.ready, 'Bootstrap failed');
    runApp(DesktopLauncher(bootstrap: bootstrap));
    final service = bootstrap.library!.service;
    final private = File('$canonical/old-authority.json');
    facts['port'] = bootstrap.boundPort;
    if (mode == 'reopen') {
      final old = jsonDecode(await private.readAsString()) as Map;
      var refused = false;
      try {
        await service.agent.read(
          old['token'] as String,
          FieldRef(old['item'] as String, old['field'] as String),
        );
      } on AccessFailure {
        refused = true;
      }
      check(refused, 'Old authority revived');
      check(
        service.owner.information.single.fields.single.value == 'synthetic',
        'Stored value changed',
      );
      check(
        repository.grantHistory.isNotEmpty &&
            repository.grantHistory.every((g) => !g.active),
        'History revived',
      );
      facts.addAll({
        'oldAuthorityRefused': true,
        'storedValueAndHistoryPreserved': true,
      });
    } else {
      final item = await service.owner.createInformation('菜单栏回退合成资料', '', [
        const FieldInput('合成字段', '', 'synthetic'),
      ]);
      final ref = FieldRef(item.id, item.fields.single.id);
      final session = service.agent.openSession('菜单栏回退合成验收');
      final request = service.agent.request(session, '合成资料', [ref]);
      service.owner.approve(request.id, [ref]);
      final token = service.agent.claim(session, request.id).token;
      await private.writeAsString(
        jsonEncode({'token': token, 'item': item.id, 'field': ref.fieldId}),
      );
      check(
        (await Process.run('/bin/chmod', ['600', private.path])).exitCode == 0,
        'Private permissions',
      );
      await visible(false);
      facts['unavailableBeforeClose'] = await observe();
      check(
        (facts['unavailableBeforeClose'] as Map)['buttonPresent'] == true,
        'Expected retained native status button',
      );
      await save();
      await until(
        () => platform.hides.isNotEmpty,
        'actual-close-with-invisible-status',
      );
      facts['afterUnavailableClose'] = await observe();
      if (regression) {
        check(
          platform.hides.single &&
              (facts['afterUnavailableClose'] as Map)['windowVisible'] == false,
          'Baseline regression not reproduced',
        );
        facts['regressionReproduced'] = true;
      } else {
        check(
          !platform.hides.single &&
              (facts['afterUnavailableClose'] as Map)['windowVisible'] ==
                  true &&
              !bootstrap.runtime!.availability.tray,
          'Unavailable close hid window',
        );
        facts['unavailableClosePreservedWindow'] = true;
        await visible(true);
        await until(
          () => bootstrap.runtime!.availability.tray,
          'availability-restored-without-restarting',
        );
        await save();
        await until(
          () => platform.hides.length == 2,
          'actual-close-with-available-status',
        );
        check(
          platform.hides.last && (await observe())['windowVisible'] == false,
          'Available close did not hide',
        );
        facts['actualCloseHidWindow'] = true;
        // Fault injection only: no show/open event or CUA activation here.
        await visible(false);
        await until(
          () async =>
              (await observe())['windowVisible'] == true &&
              !bootstrap.runtime!.availability.tray,
          'native-visibility-loss-restores-hidden-window',
        );
        facts['visibilityLossRestoredWindowWithoutActivation'] = true;
        facts['afterHiddenStatusLoss'] = await observe();
        await visible(true);
        await until(
          () => bootstrap.runtime!.availability.tray,
          'availability-restored-after-fallback',
        );
      }
      check(
        await service.agent.read(token, ref) == 'synthetic',
        'Close or fallback ended original authorization',
      );
      facts['originalGrantStillReadable'] = true;
    }
    facts['complete'] = true;
    await save();
    stdout.writeln('STATUS_FALLBACK_COMPLETE=$mode');
  } catch (error) {
    facts.addAll({'failed': true, 'error': error.toString()});
    await save();
    stderr.writeln('STATUS_FALLBACK_FAILED=$error');
    await bootstrap.runtime?.stop();
    exit(1);
  }
}
