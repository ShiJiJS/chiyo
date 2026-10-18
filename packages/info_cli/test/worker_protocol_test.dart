import 'dart:io';
import 'package:info_cli/agent_client.dart';
import 'package:test/test.dart';
import 'support/runtime_harness.dart';

void main() {
  test(
    'an incompatible worker is rejected before launch acknowledgement without hanging or replay',
    () async {
      final root = await Directory.systemTemp.createTemp('worker-protocol-');
      final source = File('${root.path}/old_worker.dart');
      final marker = File('${root.path}/launch-acknowledged');
      await source.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
Future<void> main() async {
  final input = StreamIterator(stdin.transform(utf8.decoder).transform(const LineSplitter()));
  if (!await input.moveNext()) exit(70);
  final plan = jsonDecode(input.current) as Map;
  final job = CredentialProcessJob.createForCurrentWorker(plan['jobName'] as String);
  await File(plan['statePath'] as String).writeAsString(jsonEncode({'state':'ready','workerPid':pid,'jobName':job.name}));
  if (await input.moveNext() && input.current == 'start') {
    await File('launch-acknowledged').writeAsString('unexpected release');
  }
  job.close();
  exit(0);
}
''');
      final executable = '${root.path}/old_worker.exe';
      final compile = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'exe',
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        source.path,
        '-o',
        executable,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final h = await RuntimeHarness.create();
      final client = AgentClient(
        h.server.port,
        sessionSecret: h.client.sessionSecret,
        runtimeWorkerExecutable: executable,
      );
      addTearDown(() async {
        await client.drainCredentialExecutions();
        client.close();
        await h.close();
        final actual = await root.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
            !actual.toLowerCase().startsWith(
              '${temp.toLowerCase()}${Platform.pathSeparator}',
            )) {
          throw StateError('Unexpected protocol fixture');
        }
        await root.delete(recursive: true);
      });
      final request = await h.approve(cwd: root.path);
      final accepted = await client.execute({
        'command': 'run-use',
        'requestId': request,
      });
      expect(accepted['status'], 'accepted');
      await client.drainCredentialExecutions().timeout(
        const Duration(seconds: 8),
      );
      expect(await marker.exists(), isFalse);
      final status = await client.execute({
        'command': 'execution-status',
        'executionId': accepted['executionId'],
      });
      expect(status['executionState'], 'start_failed');
      expect(status['processStarted'], isFalse);
      expect(
        (await client.execute({
          'command': 'run-use',
          'requestId': request,
        }))['errorCode'],
        'attempt_consumed',
      );
    },
    skip: !Platform.isWindows,
  );
}
