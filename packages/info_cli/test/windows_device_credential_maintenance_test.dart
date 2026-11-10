@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:info_cli/device_credential_journal.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_cli/runtime_worker_command.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows credential maintenance keeps live work, cleans an ended unstarted job, and retains an unknown report without server acknowledgement',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'chiyo-credential-maintenance-',
      );
      final folder = await privateDeviceDirectory(
        Directory('${root.path}/journal'),
      );
      final profile = AgentConnectionProfile(
        address: Uri.parse('https://127.0.0.1:1'),
        deviceToken:
            '${base64Url.encode(List.filled(16, 3)).replaceAll('=', '')}.${base64Url.encode(List.filled(32, 7)).replaceAll('=', '')}',
        serverId: 'synthetic-credential-maintenance',
      );
      final helper = File('${root.path}/supervisor.dart');
      await helper.writeAsString(
        "import 'dart:io'; Future<void> main() async { stdout.writeln('ready'); await stdin.drain<void>(); }",
      );
      final command = await RuntimeWorkerCommand.resolve(
        workerExecutable: helper.path,
      );
      final process = await Process.start(
        command.executable,
        command.arguments,
      );
      final errors = utf8.decoder.bind(process.stderr).join();
      expect(
        await utf8.decoder
            .bind(process.stdout)
            .transform(const LineSplitter())
            .first,
        'ready',
      );
      final identity = CredentialProcessIdentity.capture(process.pid)!;
      final lease = ManagedCredentialFiles.reserve(
        ManagedCredentialFiles.create(),
        ['credential.bin'],
      );
      final journal = File(
        '${folder.path}/${sha256.convert(utf8.encode('synthetic-execution'))}.json',
      );
      final job = CredentialProcessJob.nameFor('g' * 32);
      try {
        ManagedCredentialFiles.write(
          lease,
          'credential.bin',
          Uint8List.fromList(utf8.encode('SYNTHETIC_CREDENTIAL_ONLY')),
        );
        await writePrivateDeviceState(journal, {
          'version': 1,
          'deviceScope': sha256
              .convert(
                utf8.encode('${profile.serverId}\n${profile.deviceToken}'),
              )
              .toString(),
          'executionId': 'e' * 43,
          'executionCapability': 'c' * 43,
          'jobName': job,
          'supervisorPid': process.pid,
          'supervisorIdentity': identity.value,
          'workerPid': null,
          'workerIdentity': null,
          'lease': lease.toPrivateJson(),
          'report': null,
          'cleaned': false,
        });
        final maintenance = DeviceCredentialJournal(profile, folder);
        await maintenance.maintain();
        expect((await readPrivateDeviceState(journal))!['cleaned'], false);
        expect(
          await File('${lease.path}/credential.bin').readAsString(),
          'SYNTHETIC_CREDENTIAL_ONLY',
        );
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await errors, isEmpty);
        expect(
          CredentialProcessIdentity.isActive(process.pid, identity.value),
          false,
        );
        expect(CredentialProcessJob.isActive(job), false);
        await maintenance.maintain();
        expect(await Directory(lease.path).exists(), false);
        final state = (await readPrivateDeviceState(journal))!;
        expect(state['cleaned'], true);
        expect((state['report'] as Map)['executionState'], 'unknown');
        expect((state['report'] as Map)['exitCode'], isNull);
        expect(state.containsKey('sessionSecret'), false);
        await maintenance.maintain();
        expect((await readPrivateDeviceState(journal))!['cleaned'], true);
      } finally {
        identity.close();
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 10));
        ManagedCredentialFiles.cleanup(lease);
        await root.delete(recursive: true);
      }
    },
  );
}
