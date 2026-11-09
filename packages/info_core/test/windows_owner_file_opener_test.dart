@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  final executable = Platform.environment['CHIYO_NATIVE_FILE_OPENER_CHECK'];
  test(
    'actual Windows native opener checks protected lease and never repeats an accepted intent',
    () async {
      expect(File(executable!).existsSync(), isTrue);
      final driver = NativeInformationDeliveryFiles();
      final lease = await driver.reserve('attachment.txt');
      final bytes = Uint8List.fromList(utf8.encode('Windows 本机打开核对；无个人内容。\n'));
      final digest = sha256.convert(bytes).toString();
      try {
        await driver.write(lease, bytes);
        await driver.verify(lease, bytes.length, digest);
        final process = await Process.start(executable, []);
        final output = utf8.decoder.bind(process.stdout).join();
        final errors = utf8.decoder.bind(process.stderr).join();
        for (final field in [
          'owner-open-native-check',
          'a' * 64,
          lease.path,
          lease.directoryIdentity,
          lease.name,
          lease.fileIdentity,
          '${bytes.length}',
          digest,
        ]) {
          process.stdin.writeln(field);
        }
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 30)), 0);
        expect(await errors, isEmpty);
        final result = jsonDecode(await output) as Map;
        expect(result, {
          'validatedLease': true,
          'firstIntentLaunchCount': 1,
          'mismatchesRefused': true,
          'unknownNotReplayed': true,
          'reopenMissing': true,
          'capacity': 256,
          'overflowRefused': true,
        });
        await driver.verify(lease, bytes.length, digest);
      } finally {
        await driver.cleanup(lease);
      }
    },
    skip: executable == null,
  );
}
