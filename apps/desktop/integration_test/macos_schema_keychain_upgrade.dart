// Current signed Flutter host: production startup, real dedicated Keychain,
// and actual migration of a library seeded by pinned schema20 source.
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

import '../../../scripts/qa/macos-schema-upgrade-probe.dart' as fixture;

const _channel = MethodChannel('agent_info_manage/database_key');

class _Keys implements DatabaseKeyStore {
  _Keys({this.interactive = false});
  final bool interactive;
  int reads = 0, creates = 0;
  List<int>? last;
  @override
  Future<List<int>?> read() async {
    reads++;
    final value = await MacOsDatabaseKeyStore((method, arguments) {
      return _channel.invokeMethod<Object?>(
        interactive && method == 'read' ? 'readWithInteraction' : method,
        arguments,
      );
    }).read();
    if (value != null) last = List<int>.of(value);
    return value;
  }

  @override
  Future<void> create(List<int> key) async {
    creates++;
    throw StateError('Upgrade must never create a replacement key');
  }

  void clear() {
    last?.fillRange(0, last!.length, 0);
    last = null;
  }
}

class _Platform extends NativeDesktopPlatform {
  Future<void> Function()? beforeTerminate;
  @override
  Future<void> terminate() async {
    await beforeTerminate?.call();
    await super.terminate();
  }
}

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = Platform.environment['MAC_SCHEMA_MODE'];
  final owner = Platform.environment['MAC_SCHEMA_OWNER'];
  final supplied = Platform.environment['MAC_SCHEMA_ROOT'];
  _check(
    Platform.isMacOS &&
        {'upgrade', 'reopen'}.contains(mode) &&
        owner != null &&
        RegExp(r'^[a-f0-9]{32}$').hasMatch(owner) &&
        supplied != null,
    'Dedicated schema upgrade environment required',
  );
  final root = Directory(supplied!);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  _check(
    actual == root.path &&
        actual.startsWith('$temp/aim-mac-schema-keychain-') &&
        await File('$actual/.qa-owner').readAsString() == owner,
    'Foreign schema upgrade root',
  );
  final report = File('$actual/$mode-result.json');
  final db = File('$actual/library/library.db');
  final originalBytes = await db.readAsBytes();
  final baseline =
      jsonDecode(await File('$actual/legacy-baseline.json').readAsString())
          as Map;
  var flutterErrors = 0, closes = 0, attempts = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final ordinary = _Keys(), interactive = _Keys(interactive: true);
  final platform = _Platform();
  final facts = <String, Object?>{'mode': mode, 'complete': false};
  EncryptedInformationRepository? repository;
  DesktopBootstrap? bootstrap;
  Future<DesktopLibrary> open(_Keys keys) async {
    final repo = await EncryptedInformationRepository.open(
      '$actual/library',
      keys,
    );
    repository = repo;
    return DesktopLibrary(
      service: InformationService(repository: repo),
      close: () async {
        await repo.close();
        closes++;
      },
    );
  }

  platform.beforeTerminate = () async {
    await WidgetsBinding.instance.endOfFrame;
    ordinary.clear();
    interactive.clear();
    facts.addAll({
      'flutterErrors': flutterErrors,
      'libraryCloses': closes,
      'keyCreates': ordinary.creates + interactive.creates,
      'actualOwnerAccessAttempts': attempts,
      'nativeTerminationRequested': true,
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
  };
  try {
    bootstrap = DesktopBootstrap(
      platform: platform,
      port: 0,
      openLibrary: () => open(ordinary),
      openLibraryWithKeyAccess: () {
        attempts++;
        return open(interactive);
      },
    );
    final starting = bootstrap.start();
    runApp(DesktopLauncher(bootstrap: bootstrap));
    await starting;
    if (mode == 'upgrade') {
      _check(
        bootstrap.canRequestKeyAccess &&
            bootstrap.library == null &&
            bootstrap.boundPort == null &&
            ordinary.creates == 0 &&
            listEquals(await db.readAsBytes(), originalBytes),
        'Signature change must preserve original library before owner access',
      );
      facts['initialAccessFailurePreservedDatabaseAndNoEndpoint'] = true;
      final deadline = DateTime.now().add(const Duration(minutes: 30));
      var previous = '';
      while (bootstrap.state != DesktopStartupState.ready) {
        _check(
          DateTime.now().isBefore(deadline),
          'Actual owner access deadline',
        );
        if (bootstrap.state == DesktopStartupState.failed &&
            !bootstrap.keyAccessPending) {
          _check(
            listEquals(await db.readAsBytes(), originalBytes) &&
                ordinary.creates + interactive.creates == 0 &&
                bootstrap.boundPort == null,
            'Failed owner access altered original data or created authority',
          );
        }
        final phase = jsonEncode({
          'state': bootstrap.state.name,
          'pending': bootstrap.keyAccessPending,
          'attempts': attempts,
          'canRequestAccess': bootstrap.canRequestKeyAccess,
        });
        if (phase != previous) {
          await File('$actual/phase.json').writeAsString(phase, flush: true);
          stdout.writeln('MAC_SCHEMA_PHASE=$phase');
          previous = phase;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _check(
        attempts >= 1,
        'Actual owner action required; no injected approval',
      );
    }
    _check(
      bootstrap.state == DesktopStartupState.ready &&
          ordinary.creates + interactive.creates == 0,
      'Original-key startup did not succeed',
    );
    facts['port'] = bootstrap.boundPort;
    final key = interactive.last ?? ordinary.last;
    _check(key != null, 'Real dedicated Keychain key was not read');
    // Snapshot only: no second repository open or hidden migration/repair.
    final snapshot = await fixture.runSchemaUpgradeFixture(
      'snapshot',
      root,
      List<int>.of(key!),
    );
    _check(
      snapshot['schema'] == 21 &&
          snapshot['marker'] == 21 &&
          snapshot['integrity'] == 'ok',
      'Current production startup did not migrate to schema21',
    );
    final tables = snapshot['tables'] as Map;
    for (final entry in (baseline['tables'] as Map).entries) {
      if (entry.key == 'information_draft_commits') continue;
      _check(
        jsonEncode(tables[entry.key]) == jsonEncode(entry.value),
        'Durable legacy table changed: ${entry.key}',
      );
    }
    _check(
      (tables['information_draft_commits'] as Map)['rows'] == 0 &&
          (tables['information_deliveries'] as Map)['rows'] == 0,
      'Transient drafts or new delivery registry invalid',
    );
    final old =
        jsonDecode(
              await File('$actual/.private-association.json').readAsString(),
            )
            as Map;
    var refused = false;
    try {
      await bootstrap.library!.service.agent.read(
        old['token'] as String,
        FieldRef(old['item'] as String, old['field'] as String),
      );
    } on AccessFailure {
      refused = true;
    }
    _check(refused, 'Legacy authority revived');
    final item = repository!.items.singleWhere(
      (i) => i.name == 'Synthetic legacy file',
    );
    final versions = await repository!.informationAttachmentVersions(
      item.fields.single.attachment!.attachmentId,
    );
    _check(versions.length == 2, 'Attachment version relationships changed');
    for (final version in versions) {
      final original = await File(
        '$actual/source-${version.reference.attachmentVersion}.bin',
      ).readAsBytes();
      final bytes = <int>[];
      for (var offset = 0; offset < original.length; offset += 65536) {
        final remaining = original.length - offset;
        bytes.addAll(
          await repository!.readInformationAttachmentChunk(
            version.reference,
            offset,
            remaining > 65536 ? 65536 : remaining,
          ),
        );
      }
      _check(listEquals(bytes, original), 'Legacy attachment original changed');
    }
    facts.addAll({
      'complete': true,
      'snapshotBeforeVerificationOperations': snapshot,
      'allDurableLegacyRowsPreserved': true,
      'transientDraftsClearedAsDesigned': true,
      'twoAttachmentOriginalsAndRelationshipsPreserved': true,
      'oldAuthorityRefused': true,
      'cipherVersion': repository!.cipherVersion,
      'systemDecisionIsFixture': false,
      'productionStartupPerformedMigration': true,
    });
    _check(flutterErrors == 0, 'Flutter reported an exception');
    await bootstrap.runtime!.quit();
  } catch (error, stack) {
    ordinary.clear();
    interactive.clear();
    facts.addAll({
      'failed': true,
      'errorType': error.runtimeType.toString(),
      if (error is StateError) 'checkFailure': error.message,
      'stack': stack.toString(),
    });
    await report.writeAsString(jsonEncode(facts), flush: true);
    await bootstrap?.runtime?.stop();
    exit(1);
  }
}
