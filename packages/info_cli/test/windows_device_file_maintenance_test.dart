@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_cli/device_information_files.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_cli/runtime_worker_command.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows maintenance finds its journal, preserves a live worker, and cleans an exited worker without read proof',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-device-copy-maintenance-',
      );
      final folder = await privateDeviceDirectory(
        Directory('${root.path}/journal'),
      );
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://127.0.0.1:1'),
        deviceToken:
            '${base64Url.encode(List.filled(16, 3)).replaceAll('=', '')}.${base64Url.encode(List.filled(32, 7)).replaceAll('=', '')}',
        serverId: 'synthetic-maintenance-server',
      );
      final driver = NativeInformationDeliveryFiles();
      final copy = await driver.reserve('attachment.txt');
      final helper = File('${root.path}/wait-for-stdin.dart');
      await helper.writeAsString(
        "import 'dart:io'; Future<void> main() async { stdout.writeln('ready'); await stdin.drain<void>(); }",
      );
      final command = await RuntimeWorkerCommand.resolve(
        workerExecutable: helper.path,
      );
      final child = await Process.start(command.executable, command.arguments);
      final errors = utf8.decoder.bind(child.stderr).join();
      final ready = await utf8.decoder
          .bind(child.stdout)
          .transform(const LineSplitter())
          .first;
      expect(ready, 'ready');
      final identity = CredentialProcessIdentity.capture(child.pid)!;
      final journal = File(
        '${folder.path}/${sha256.convert(utf8.encode('delivery'))}.json',
      );
      final bytes = Uint8List.fromList(
        utf8.encode('Only this Windows development copy may be cleaned.'),
      );
      try {
        await driver.write(copy, bytes);
        await writePrivateDeviceState(journal, {
          'version': 1,
          'deviceScope': sha256
              .convert(
                utf8.encode('${profile.serverId}\n${profile.deviceToken}'),
              )
              .toString(),
          'phase': 'ready',
          'workerPid': child.pid,
          'workerIdentity': identity.value,
          'lease': copy.toPrivateJson(),
          'manifest': {
            'deliveryId': 'delivery',
            'cleanupCapability': 'synthetic-cleanup-only',
          },
        });
        final unrelated = File('${folder.path}/unrelated.json');
        await writePrivateDeviceState(unrelated, {'phase': 'unrelated'});
        final files = DeviceInformationFiles(profile, folder);
        await files.maintain();
        expect(await File(copy.filePath).readAsBytes(), bytes);
        expect((await readPrivateDeviceState(journal))!['phase'], 'ready');
        await child.stdin.close();
        expect(await child.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await errors, isEmpty);
        final observer = File('${root.path}/first-observation.dart');
        await observer.writeAsString(
          "import 'dart:convert'; import 'dart:io'; import 'package:info_core/info_core.dart'; Future<void> main() async { final v = jsonDecode(await utf8.decoder.bind(stdin).join()); stdout.writeln(CredentialProcessIdentity.isActive(v['pid'], v['identity'])); }",
        );
        final observing = await RuntimeWorkerCommand.resolve(
          workerExecutable: observer.path,
        );
        final observed = await Process.start(
          observing.executable,
          observing.arguments,
        );
        final observation = utf8.decoder.bind(observed.stdout).join();
        final observationErrors = utf8.decoder.bind(observed.stderr).join();
        observed.stdin.writeln(
          jsonEncode({'pid': child.pid, 'identity': identity.value}),
        );
        await observed.stdin.close();
        expect(await observed.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await observationErrors, isEmpty);
        // No earlier live-process observation may initialize native helpers
        // inside this separate process. Its first check must confirm death.
        expect((await observation).trim(), 'false');
        expect(
          CredentialProcessIdentity.isActive(child.pid, identity.value),
          false,
        );
        await files.maintain();
        expect(await File(copy.filePath).exists(), false);
        expect(await Directory(copy.path).exists(), false);
        final state = (await readPrivateDeviceState(journal))!;
        // Physical cleanup succeeded; this deliberately unavailable server has
        // not acknowledged it. Never invent a terminal acknowledged result.
        expect(state['phase'], 'cleanup_pending');
        expect(state['lease'], isNull);
        expect(state.containsKey('sessionSecret'), false);
        expect(
          (await readPrivateDeviceState(unrelated))!['phase'],
          'unrelated',
        );
        await files.maintain();
        expect(
          (await readPrivateDeviceState(journal))!['phase'],
          'cleanup_pending',
        );
      } finally {
        identity.close();
        await child.stdin.close();
        await child.exitCode.timeout(const Duration(seconds: 10));
        await driver.cleanup(copy);
        await root.delete(recursive: true);
      }
    },
  );
}
