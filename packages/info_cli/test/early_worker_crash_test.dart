import 'dart:convert';
import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'worker death after launch acknowledgement but before target identity keeps the attempt unknown and preserves live material',
    () async {
      final root = await Directory.systemTemp.createTemp('early-worker-crash-');
      final release = File('${root.path}/release'),
          ready = File('${root.path}/target-ready'),
          finished = File('${root.path}/target-finished');
      final worker = File('${root.path}/early-worker.exe');
      final built = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        'test/support/early_crash_worker.dart',
        '-o',
        worker.path,
      ]);
      expect(built.exitCode, 0, reason: '${built.stderr}');
      await File('${root.path}/sts').writeAsString(
        r'''import 'dart:convert'; import 'dart:io';
Future<void> main()async{
  await File('target-ready').writeAsString(jsonEncode({'temp':Platform.environment['TEMP']}),flush:true);
  final deadline=DateTime.now().add(const Duration(seconds:20));
  while(!await File('release').exists()&&DateTime.now().isBefore(deadline)){await Future<void>.delayed(const Duration(milliseconds:10));}
  await File('target-finished').writeAsString('finished');
}''',
      );
      final h = await RuntimeHarness.create(
        executablePath:
            '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe',
        fileBytes: utf8.encode(
          '[default]\naws_access_key_id = TEST\naws_secret_access_key = SYNTHETIC_ONLY\n',
        ),
      );
      final client = AgentClient(
        h.server.port,
        sessionSecret: h.client.sessionSecret,
        runtimeWorkerExecutable: worker.path,
      );
      addTearDown(() async {
        await release.writeAsString('release');
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (!await finished.exists() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await client.drainCredentialExecutions();
        client.close();
        await h.close();
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Unexpected early crash fixture');
        }
        await root.delete(recursive: true);
      });
      final request = await h.approve(
        cwd: root.path,
        argv: ['sts', 'get-caller-identity', '--region', 'us-east-1'],
      );
      final run = await client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(run['status'], 'accepted');
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists() ||
          h.service.owner.credentialExecutions.single.state == 'preparing') {
        expect(
          DateTime.now().isBefore(end),
          isTrue,
          reason: 'Early-crash fixture did not reach a reported state',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final record = h.service.owner.credentialExecutions.single;
      expect(record.state, 'unknown');
      expect(record.processStarted, isFalse);
      expect(record.finishedAt, isNull);
      expect(CredentialProcessJob.isActive(record.jobName!), isTrue);
      expect(await Directory(record.materialLease!.path).exists(), isTrue);
      final home =
          (jsonDecode(await ready.readAsString()) as Map)['temp'] as String;
      expect(await Directory(home).exists(), isTrue);
      expect(
        await client
            .drainCredentialExecutions()
            .then((_) => true)
            .timeout(const Duration(milliseconds: 150), onTimeout: () => false),
        isFalse,
      );
      await release.writeAsString('release');
      await client.drainCredentialExecutions();
      final cleaned = h.service.owner.credentialExecutions.single;
      expect(cleaned.state, 'unknown');
      expect(cleaned.exitCode, isNull);
      expect(cleaned.cleanupState, 'complete');
      expect(await Directory(cleaned.materialLease!.path).exists(), isFalse);
      expect(await Directory(home).exists(), isFalse);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
