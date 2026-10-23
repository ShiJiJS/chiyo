import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:info_core/macos_desktop_control.dart';
import 'package:test/test.dart';

void main() {
  test('other platforms return unsupported Mac control', () async {
    expect(
      (await MacDesktopControl.execute(
        quit: true,
        executable: '/absent',
      ))['status'],
      'unsupported_platform',
    );
  }, skip: Platform.isMacOS);

  group('Darwin owner-only process control', () {
    late Directory root;
    late String executable;
    final children = <_Child>[];
    var fixture = 0;
    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('mac-control-中文 空格-');
      executable = '${root.path}/native-control-host';
      final dart = File(
        '${File(Platform.resolvedExecutable).parent.path}/dart',
      );
      final compiled = await Process.run(dart.path, [
        'compile',
        'exe',
        'test/support/macos_desktop_control_host.dart',
        '-o',
        executable,
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}\n${compiled.stderr}',
      );
    });
    tearDown(() async {
      for (final child in children) {
        await child.close();
      }
      children.clear();
    });
    tearDownAll(() async {
      await root.delete(recursive: true);
    });
    Future<_Child> start([String mode = 'normal', String? image]) async {
      final directory = Directory('${root.path}/fixture-${fixture++}/control');
      final process = await Process.start(
        image ?? executable,
        [directory.path, mode],
        environment: const {'PATH': '/usr/bin:/bin'},
        includeParentEnvironment: false,
      );
      final child = _Child(process, directory);
      children.add(child);
      final ready = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      expect(jsonDecode(ready)['ready'], isTrue);
      return child;
    }

    Future<Map<String, Object?>> control(
      _Child child, {
      bool quit = false,
      int? target,
      int milliseconds = 3000,
    }) => MacDesktopControl.execute(
      quit: quit,
      executable: executable,
      processId: target,
      directory: child.directory,
      timeout: Duration(milliseconds: milliseconds),
    );

    test(
      'status is read-only; a committed normal quit waits for the original process',
      () async {
        final child = await start();
        expect((await control(child))['status'], 'running');
        expect(
          await File('${child.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
        final result = await control(child, quit: true);
        expect(result['status'], 'exited');
        expect(result['processId'], child.process.pid);
        expect(
          result['exitCode'],
          isNull,
        ); // Non-child Darwin exit status is unavailable.
        expect(
          await child.process.exitCode,
          0,
        ); // This test separately owns the child.
        expect(
          await File('${child.directory.path}/quit-count.txt').readAsString(),
          '1',
        );
        expect((await control(child, quit: true))['status'], 'not_running');
      },
    );

    test(
      'save failure is explicit and only a new CLI call retries it',
      () async {
        final child = await start('fail-once');
        expect((await control(child, quit: true))['status'], 'shutdown_failed');
        expect(child.ended, isFalse);
        expect((await control(child))['status'], 'shutdown_failed');
        expect(
          await File('${child.directory.path}/quit-count.txt').readAsString(),
          '1',
        );
        expect((await control(child, quit: true))['status'], 'exited');
        expect(
          await File('${child.directory.path}/quit-count.txt').readAsString(),
          '2',
        );
      },
    );

    test(
      'a live registered image removed from disk is never silently called stopped',
      () async {
        final image = await File(executable).copy('${root.path}/removed-image');
        final child = await start('normal', image.path);
        await image.delete();
        final result = await MacDesktopControl.execute(
          quit: false,
          executable: image.path,
          directory: child.directory,
        );
        expect(result['status'], isIn({'running', 'target_unavailable'}));
        expect(child.ended, isFalse);
        expect(
          await File('${child.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
      },
    );

    test('uncommitted disappearance is not a successful normal quit', () async {
      final child = await start('unexpected');
      expect((await control(child, quit: true))['status'], 'unexpected_exit');
      expect(await child.process.exitCode, 7);
    });

    test(
      'timeout preserves the live receiver and never resends the quit',
      () async {
        final child = await start('hang');
        expect(
          (await control(child, quit: true, milliseconds: 250))['status'],
          'timeout',
        );
        expect(child.ended, isFalse);
        expect((await control(child))['status'], 'exiting');
        expect(
          await File('${child.directory.path}/quit-count.txt').readAsString(),
          '1',
        );
      },
    );

    test('a startup failure can still be normally closed', () async {
      final child = await start('startup-failed');
      expect((await control(child))['status'], 'startup_failed');
      expect((await control(child, quit: true))['status'], 'exited');
    });

    test(
      'explicit unrelated PID and ambiguous matching executables receive no quit',
      () async {
        final first = await start();
        expect(
          (await control(first, quit: true, target: pid))['status'],
          'target_mismatch',
        );
        final second = await start();
        expect(
          (await control(first, quit: true))['status'],
          'ambiguous_target',
        );
        expect(
          await File('${first.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
        expect(
          await File('${second.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
        expect(
          (await control(
            first,
            quit: true,
            target: first.process.pid,
          ))['status'],
          'exited',
        );
        expect(second.ended, isFalse);
      },
    );

    test(
      'malformed, oversized and unauthenticated frames cannot reach quit',
      () async {
        final child = await start();
        final registry =
            jsonDecode(
                  await File(
                    '${child.directory.path}/endpoint.json',
                  ).readAsString(),
                )
                as Map;
        for (final body in [
          'x' * 3000,
          jsonEncode({
            'controlVersion': 1,
            'processId': child.process.pid,
            'token': 'f' * 64,
            'command': 'quit',
            'operationId': 'a' * 64,
          }),
          jsonEncode({...registry, 'command': 'quit'}),
        ]) {
          final socket = await Socket.connect(
            InternetAddress.loopbackIPv4,
            registry['port'] as int,
          );
          try {
            socket.writeln(body);
            await socket.flush();
            await socket.drain<void>().timeout(const Duration(seconds: 3));
          } finally {
            socket.destroy();
          }
        }
        expect((await control(child))['status'], 'running');
        expect(
          await File('${child.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
      },
    );

    test(
      'private permissions, record identity and symlink checks fail closed',
      () async {
        final child = await start();
        final file = File('${child.directory.path}/endpoint.json');
        final original = await file.readAsString();
        final record = jsonDecode(original) as Map;
        await file.writeAsString(
          jsonEncode({...record, 'createdAt': 'macos:1:1'}),
        );
        expect(
          (await control(child, quit: true))['status'],
          'target_unavailable',
        );
        await file.writeAsString(original);
        await Process.run('/bin/chmod', ['644', file.path]);
        expect(
          (await control(child, quit: true))['status'],
          'control_unavailable',
        );
        await Process.run('/bin/chmod', ['600', file.path]);
        final held = await file.rename('${file.path}.held');
        await Link(file.path).create(held.path);
        expect(
          (await control(child, quit: true))['status'],
          'control_unavailable',
        );
        await Link(file.path).delete();
        await held.rename(file.path);
        expect((await control(child))['status'], 'running');
        expect(
          await File('${child.directory.path}/quit-count.txt').exists(),
          isFalse,
        );
      },
    );
  }, skip: !Platform.isMacOS);
}

class _Child {
  _Child(this.process, this.directory) {
    unawaited(
      process.exitCode.then((_) {
        ended = true;
      }),
    );
    errors = process.stderr.listen((_) {});
  }
  final Process process;
  final Directory directory;
  bool ended = false;
  late final StreamSubscription<List<int>> errors;
  Future<void> close() async {
    // Only this test's synthetic headless receiver, never an installed app.
    if (!ended) process.kill();
    await process.exitCode;
    await errors.cancel();
  }
}
