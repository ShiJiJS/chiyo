import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/bundled_windows_native_fill.dart';

const _abcDigest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File helper;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('chiyo-native-bundle-');
    helper = await File(
      '${directory.path}/info-native-background-broker.exe',
    ).writeAsString('abc');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<Object?> identity() async => {
    'executable': helper.path,
    'sha256': _abcDigest,
  };
  Future<Object?> load([Future<Object?> Function()? read]) =>
      loadBundledWindowsNativeFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
        readIdentity: read ?? identity,
      );
  final unavailable = throwsA(
    isA<CredentialUseFailure>().having(
      (failure) => failure.code,
      'safe code',
      Platform.isWindows ? 'session_unavailable' : 'unsupported_capability',
    ),
  );

  for (final (index, invalid) in [
    null,
    'not a map',
    <String, Object?>{},
    {'executable': r'C:\Outside\helper.exe', 'sha256': 'invalid'},
    {
      'executable': r'C:\Outside\helper.exe',
      'sha256': _abcDigest,
      'extra': true,
    },
  ].indexed) {
    test('malformed native identity fails closed: $index', () async {
      await expectLater(load(() async => invalid), unavailable);
    });
  }
  test('missing channel is a sanitized unavailable result', () async {
    await expectLater(
      loadBundledWindowsNativeFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
      ),
      unavailable,
    );
  });
  test('missing or changed helper is rejected', () async {
    await helper.writeAsString('changed synthetic bytes');
    await expectLater(load(), unavailable);
    await helper.delete();
    await expectLater(load(), unavailable);
  });
  test(
    'same bytes outside the App or at another filename are rejected',
    () async {
      final outsideDirectory = await Directory(
        '${directory.path}/outside',
      ).create();
      final outside = await File(
        '${outsideDirectory.path}/info-native-background-broker.exe',
      ).writeAsString('abc');
      await expectLater(
        load(() async => {'executable': outside.path, 'sha256': _abcDigest}),
        unavailable,
      );
      final renamed = await File(
        '${directory.path}/another.exe',
      ).writeAsString('abc');
      await expectLater(
        load(() async => {'executable': renamed.path, 'sha256': _abcDigest}),
        unavailable,
      );
    },
  );
  test(
    'matching hash without a usable native handshake is unavailable',
    () async {
      await expectLater(load(), unavailable);
    },
  );

  final realHelper = Platform.environment['CHIYO_NATIVE_BUNDLE_TEST_HELPER'];
  test(
    'native channel loads a bound sibling and completes the private handshake',
    () async {
      await helper.delete();
      await File(realHelper!).copy(helper.path);
      final digest = (await sha256.bind(helper.openRead()).first).toString();
      const channel = MethodChannel('agent_info_manage/desktop');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            expect(call.arguments, isNull);
            return {'executable': helper.path, 'sha256': digest};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final driver = await loadBundledWindowsNativeFill(
        applicationExecutable: '${directory.path}/info_desktop.exe',
      );
      try {
        expect(
          driver.helper.executable.toLowerCase(),
          (await helper.resolveSymbolicLinks()).toLowerCase(),
        );
        expect(driver.helper.sha256, digest);
        expect(calls, ['nativeBackgroundFillHelper']);
      } finally {
        await driver.dispose();
        await driver.dispose();
      }
      await expectLater(driver.initialize(), unavailable);
    },
    skip: !Platform.isWindows || realHelper == null,
  );
}
