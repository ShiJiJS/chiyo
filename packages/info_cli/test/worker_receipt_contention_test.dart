import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  for (final phase in ['ready', 'started']) {
    test(
      'a Windows reader retaining the $phase receipt cannot delay or lose completion or repeat the target',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'worker-receipt-contention-',
        );
        final state = File('${root.path}/worker-state.json'),
            marker = File('${root.path}/target-started');
        final target = File('${root.path}/target.dart');
        await target.writeAsString(
          "import 'dart:io'; Future<void> main() => File('target-started').writeAsString('started\\n',mode:FileMode.append);",
        );
        final vm =
            '${File(Platform.resolvedExecutable).parent.path}/dartvm.exe';
        final worker = await Process.start(
          vm,
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
        RandomAccessFile? reader;
        addTearDown(() async {
          await reader?.close();
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
            throw StateError('Unexpected receipt fixture');
          }
          await root.delete(recursive: true);
        });
        worker.stdin.writeln(
          jsonEncode({
            'executable': vm,
            'argv': [target.path],
            'cwd': root.path,
            'statePath': state.path,
            'jobName':
                r'Local\AgentInfoRuntime-01234567890123456789012345678902',
          }),
        );
        await worker.stdin.flush();
        final end = DateTime.now().add(const Duration(seconds: 8));
        while (!await state.exists()) {
          expect(DateTime.now().isBefore(end), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          (jsonDecode(await state.readAsString()) as Map)['state'],
          'ready',
        );
        if (phase == 'ready') reader = await state.open();
        worker.stdin.writeln('start');
        await worker.stdin.flush();
        if (phase == 'started') {
          final started = File('${state.path}.started');
          while (!await started.exists()) {
            expect(DateTime.now().isBefore(end), isTrue);
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          reader = await started.open();
        }
        await worker.stdin.close();
        while (!await marker.exists()) {
          expect(DateTime.now().isBefore(end), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // Keep the actual Windows read handle open through completion, beyond
        // the old two-second rename retry window. Observing readiness must not
        // prevent a later phase from being published.
        expect(await worker.exitCode.timeout(const Duration(seconds: 5)), 0);
        await reader!.close();
        reader = null;
        final receipt =
            jsonDecode(await File('${state.path}.finished').readAsString())
                as Map;
        expect(receipt['state'], 'exited');
        expect(receipt['exitCode'], 0);
        expect(await marker.readAsLines(), ['started']);
      },
      skip: !Platform.isWindows,
    );
  }
}
