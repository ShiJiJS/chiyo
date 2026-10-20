import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  for (final releaseTarget in [false, true]) {
    test(
      'worker waits for durable registration and ${releaseTarget ? 'starts after acknowledgement' : 'does not start when the supervisor disconnects'}',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'worker-start-gate-',
        );
        final state = File('${root.path}/worker-state.json'),
            marker = File('${root.path}/target-started');
        final script = File('${root.path}/target.dart');
        await script.writeAsString(
          "import 'dart:io'; Future<void> main() => File('target-started').writeAsString('started');",
        );
        final runtime =
            '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe';
        final worker = await Process.start(
          runtime,
          [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            File('lib/runtime_worker.dart').absolute.path,
          ],
          workingDirectory: root.path,
          environment: {'TEMP': root.path, 'TMP': root.path},
          includeParentEnvironment: false,
        );
        final out = worker.stdout.drain<void>(),
            err = worker.stderr.drain<void>();
        addTearDown(() async {
          await worker.stdin.close();
          await worker.exitCode;
          await out;
          await err;
          final actual = await root.resolveSymbolicLinks(),
              temp = await Directory.systemTemp.resolveSymbolicLinks();
          if (actual.toLowerCase() != root.absolute.path.toLowerCase() ||
              !actual.toLowerCase().startsWith(
                '${temp.toLowerCase()}${Platform.pathSeparator}',
              )) {
            throw StateError('Unexpected worker fixture');
          }
          await root.delete(recursive: true);
        });
        worker.stdin.writeln(
          jsonEncode({
            'executable': runtime,
            'argv': [script.path],
            'cwd': root.path,
            'statePath': state.path,
            'jobName':
                r'Local\AgentInfoRuntime-01234567890123456789012345678901',
          }),
        );
        await worker.stdin.flush();
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!await state.exists() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          (jsonDecode(await state.readAsString()) as Map)['state'],
          'ready',
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(await marker.exists(), isFalse);
        if (releaseTarget) {
          worker.stdin.writeln('start');
          await worker.stdin.flush();
        }
        await worker.stdin.close();
        expect(await worker.exitCode, releaseTarget ? 0 : 70);
        if (releaseTarget) {
          expect(await marker.readAsString(), 'started');
        } else {
          expect(await marker.exists(), isFalse);
        }
      },
      skip: !Platform.isWindows,
    );
  }
}
