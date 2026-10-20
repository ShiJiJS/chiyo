import 'dart:convert';
import 'dart:io';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory compiled;
  late String executable;
  setUpAll(() async {
    if (!Platform.isMacOS) return;
    compiled = await Directory.systemTemp.createTemp('mac-worker-aot-');
    executable = '${compiled.path}/info-runtime-worker';
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/runtime_worker.dart',
      '-o',
      executable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
  tearDownAll(() async {
    if (Platform.isMacOS) await compiled.delete(recursive: true);
  });

  for (final mode in [
    'before-gate',
    'after-gate',
    'worker-crash',
    'short-zero',
    'short-signal',
  ]) {
    final admitted = mode != 'before-gate', crashed = mode == 'worker-crash';
    final short = mode.startsWith('short-');
    test('Darwin AOT worker lifetime: $mode', () async {
      final created = await Directory.systemTemp.createTemp('mac-worker-gate-');
      final root = Directory(await created.resolveSymbolicLinks());
      final state = File('${root.path}/worker-state.json');
      final marker = File('${root.path}/ran');
      final group = CredentialProcessJob.nameFor('0' * 32);
      final worker = await Process.start(
        executable,
        [],
        workingDirectory: root.path,
        environment: {
          'TMPDIR': root.path,
          'HOME': root.path,
          'PATH': '/usr/bin:/bin',
        },
        includeParentEnvironment: false,
      );
      final output = worker.stdout.drain<void>();
      final error = worker.stderr.transform(utf8.decoder).join();
      final identity = CredentialProcessIdentity.capture(worker.pid)!;
      try {
        worker.stdin.writeln(
          jsonEncode({
            'statePath': state.path,
            'jobName': group,
            'executable': '/bin/sh',
            'argv': [
              '-c',
              switch (mode) {
                'short-zero' => '/usr/bin/touch ran; exit 0',
                'short-signal' => r'/usr/bin/touch ran; kill -TERM $$',
                _ =>
                  '/usr/bin/touch ran; /bin/sleep ${crashed ? 2 : 0.6} & exit 7',
              },
            ],
          }),
        );
        await worker.stdin.flush();
        Future<void> receipt(File file) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!await file.exists()) {
            if (!DateTime.now().isBefore(deadline)) {
              fail('Worker receipt missing');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }

        await receipt(state);
        expect(await marker.exists(), isFalse);
        if (admitted) {
          worker.stdin.writeln('start');
          await worker.stdin.flush();
          await receipt(File('${state.path}.started'));
          // The second gate protects the identity of even a very short target.
          expect(await marker.exists(), isFalse);
        }
        await worker.stdin.close();
        if (admitted) {
          await receipt(marker);
        }
        if (admitted && !short) {
          expect(
            CredentialProcessJob.isActive(
              group,
              workerPid: worker.pid,
              workerCreatedAt: identity.value,
            ),
            isTrue,
          );
          expect(await File('${state.path}.finished').exists(), isFalse);
        }
        if (crashed) expect(worker.kill(ProcessSignal.sigkill), isTrue);
        expect(
          await worker.exitCode.timeout(const Duration(seconds: 10)),
          crashed
              ? -9
              : admitted
              ? 0
              : 70,
        );
        if (crashed) {
          // A dead group leader does not prove that its descendants ended.
          expect(
            CredentialProcessJob.isActive(
              group,
              workerPid: worker.pid,
              workerCreatedAt: identity.value,
            ),
            isTrue,
          );
        }
        await output;
        expect(await error, isEmpty);
        expect(await marker.exists(), admitted);
        if (!crashed) {
          expect(
            jsonDecode(
              await File('${state.path}.finished').readAsString(),
            )['state'],
            admitted ? 'exited' : 'start_failed',
          );
        }
        if (admitted && !crashed) {
          expect(
            jsonDecode(
              await File('${state.path}.finished').readAsString(),
            )['exitCode'],
            switch (mode) {
              'short-zero' => 0,
              'short-signal' => -15,
              _ => 7,
            },
          );
        }
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (CredentialProcessJob.isActive(
                  group,
                  workerPid: worker.pid,
                  workerCreatedAt: identity.value,
                ) ==
                true &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          CredentialProcessJob.isActive(
            group,
            workerPid: worker.pid,
            workerCreatedAt: identity.value,
          ),
          isFalse,
        );
      } finally {
        identity.close();
        // This test owns every child and generated file. Preserve failures
        // rather than traversing anything outside its canonical fixture root.
        if (await worker.exitCode.timeout(
              const Duration(seconds: 10),
              onTimeout: () => -999,
            ) !=
            -999) {
          await root.delete(recursive: true);
        }
      }
    }, skip: !Platform.isMacOS);
  }
}
