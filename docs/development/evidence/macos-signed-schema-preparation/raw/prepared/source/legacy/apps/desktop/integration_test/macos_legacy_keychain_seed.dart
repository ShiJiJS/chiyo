// Built against the pinned legacy core/storage source in an isolated QA copy.
// The current native Keychain bridge supplies the missing historical Mac host;
// this is not a claim that a released schema20 Mac app existed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:info_storage/info_storage.dart';

import '../../../scripts/qa/macos-schema-upgrade-probe.dart' as fixture;

const _keysChannel = MethodChannel('agent_info_manage/database_key');
const _desktop = MethodChannel('agent_info_manage/desktop');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final mode = Platform.environment['MAC_SCHEMA_MODE'];
  final owner = Platform.environment['MAC_SCHEMA_OWNER'];
  if (!Platform.isMacOS ||
      !{'seed', 'old-reader', 'cleanup'}.contains(mode) ||
      owner == null ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
    exit(64);
  }
  final supplied = Platform.environment['MAC_SCHEMA_ROOT'];
  final root = supplied == null
      ? await Directory.systemTemp.createTemp('aim-mac-schema-keychain-')
      : Directory(supplied);
  final actual = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  if (!actual.startsWith('$temp/aim-mac-schema-keychain-') ||
      root.path != actual ||
      root.path.split('/').last == 'aim-mac-schema-keychain-') {
    throw StateError('Foreign schema fixture');
  }
  final marker = File('$actual/.qa-owner');
  if (supplied == null) {
    await marker.writeAsString(owner, flush: true);
  } else if (await marker.readAsString() != owner) {
    throw StateError('Foreign schema owner');
  }
  stdout.writeln('MAC_SCHEMA_ROOT=$actual');
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('合成旧版资料：真实钥匙串与 SQLCipher'))),
    ),
  );
  var flutterErrors = 0;
  FlutterError.onError = (details) {
    flutterErrors++;
    FlutterError.presentError(details);
  };
  final facts = <String, Object?>{'mode': mode};
  try {
    final keys = MacOsDatabaseKeyStore(_keysChannel.invokeMethod<Object?>);
    if (mode == 'cleanup') {
      await _keysChannel.invokeMethod<void>('qaDelete');
      if (await keys.read() != null) throw StateError('Owned key still exists');
      facts['ownedKeyDeletedAndAbsenceVerified'] = true;
    } else {
      if (mode == 'seed') {
        if (await File('$actual/library/library.db').exists() ||
            await keys.read() != null) {
          throw StateError('Fresh dedicated fixture required');
        }
        // Let the actual legacy repository create and re-read its real system
        // key. The fixture then seeds this same schema20 library and key.
        final repo = await EncryptedInformationRepository.open(
          '$actual/library',
          keys,
        );
        facts['cipherVersion'] = repo.cipherVersion;
        await repo.close();
      }
      final key = await keys.read();
      if (key == null) throw StateError('Original dedicated key missing');
      final result = await fixture.runSchemaUpgradeFixture(
        mode == 'seed' ? 'create' : 'inspect',
        root,
        List<int>.of(key),
      );
      key.fillRange(0, key.length, 0);
      if (mode == 'seed') {
        if (result['status'] != 'ok' || result['schema'] != 20) {
          throw StateError('Actual legacy schema20 seed failed');
        }
        await File(
          '$actual/legacy-baseline.json',
        ).writeAsString(jsonEncode(result), flush: true);
      } else if (result['status'] != 'failed' ||
          result['storageFailure'] != 'unsupported_schema') {
        throw StateError('Actual old reader did not refuse upgraded schema');
      }
      facts['fixtureResult'] = result;
    }
    await WidgetsBinding.instance.endOfFrame;
    facts['flutterErrors'] = flutterErrors;
    if (flutterErrors != 0) throw StateError('Flutter error in legacy host');
    facts['nativeTerminationRequested'] = true;
    await File('$actual/$mode-result.json').writeAsString(jsonEncode(facts));
    await _desktop.invokeMethod<void>('terminate');
  } catch (error, stack) {
    facts.addAll({
      'failed': true,
      'errorType': error.runtimeType.toString(),
      if (error is StateError) 'checkFailure': error.message,
      'stack': stack.toString(),
    });
    await File('$actual/$mode-result.json').writeAsString(jsonEncode(facts));
    exit(1);
  }
}
