@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_cli/private_device_state.dart';
import 'package:info_cli/ssh_session_host.dart';
import 'package:info_cli/ssh_session_macos.dart';
import 'package:info_cli/ssh_session_transport.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  final helper = Platform.environment['CHIYO_SSH_TEST_HELPER'];
  test(
    'SIGKILL of native broker preserves key lease until the actual consumer group ends',
    () async {
      final root = await Directory.systemTemp.createTemp('ssh-group-life-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/fixture.c');
      await source.writeAsString(
        '#include <stdio.h>\n#include <unistd.h>\nint main(){printf("%d\\n",getpid());fflush(stdout);sleep(3);return 0;}\n',
      );
      final binary = '${root.path}/synthetic-ssh';
      final compile = await Process.run('/usr/bin/clang', [
        source.path,
        '-o',
        binary,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      var lease = ManagedCredentialFiles.create();
      lease = ManagedCredentialFiles.reserve(lease, ['credential.bin']);
      ManagedCredentialFiles.write(
        lease,
        'credential.bin',
        utf8.encode('synthetic-private-key'),
      );
      final folder = await privateDeviceDirectory(
        Directory('${root.path}/journal'),
      );
      final file = File('${folder.path}/lease.json');
      final name = CredentialProcessJob.nameFor('A' * 32);
      final host = CredentialProcessIdentity.capture(pid)!;
      final record = <String, dynamic>{
        'hostPid': pid,
        'hostIdentity': host.value,
        'jobName': name,
        'lease': lease.toPrivateJson(),
      };
      host.close();
      await writePrivateDeviceState(file, record);
      final transport = await MacOsSshTransportLauncher(helperPath: helper!)
          .start(
            SshTransportLaunch(
              executable: binary,
              arguments: const ['-T'],
              environment: const {'PATH': '/usr/bin:/bin'},
              onLoginChallenge: (_) async => null,
              onProcessCreated: (process, identity) async {
                final deadline = DateTime.now().add(const Duration(seconds: 2));
                while (true) {
                  try {
                    CredentialProcessJob.observe(
                      name,
                      process,
                      workerPid: process,
                    ).close();
                    break;
                  } on Object {
                    if (DateTime.now().isAfter(deadline)) rethrow;
                    await Future<void>.delayed(
                      const Duration(milliseconds: 10),
                    );
                  }
                }
                record['brokerPid'] = process;
                record['brokerIdentity'] = identity;
                await writePrivateDeviceState(file, record);
              },
            ),
          );
      unawaited(transport.diagnostics.drain<void>());
      final consumer = int.parse(
        await transport.output
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
      );
      final consumerIdentity = CredentialProcessIdentity.capture(consumer)!;
      final manager = SshSessionHost(
        AgentConnectionProfile.local(
          port: 1,
          deviceToken:
              'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
          libraryId: 'synthetic-ssh-test',
        ),
        folder,
      );
      addTearDown(manager.close);
      expect(
        CredentialProcessIdentity.isActive(
          record['brokerPid'] as int,
          record['brokerIdentity'] as String,
        ),
        isTrue,
      );
      expect(
        Process.killPid(record['brokerPid'] as int, ProcessSignal.sigkill),
        isTrue,
      );
      await transport.exitCode;
      expect(
        CredentialProcessIdentity.isActive(consumer, consumerIdentity.value),
        isTrue,
      );
      await manager.maintain();
      expect(File('${lease.path}/credential.bin').existsSync(), isTrue);
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (CredentialProcessJob.isActive(
            name,
            workerPid: record['brokerPid'] as int,
            workerCreatedAt: record['brokerIdentity'] as String,
          ) !=
          false) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Owned consumer group remained active');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      consumerIdentity.close();
      await manager.maintain();
      expect(Directory(lease.path).existsSync(), isFalse);
    },
    skip: helper == null
        ? 'Requires the explicitly built native helper.'
        : false,
  );
}
