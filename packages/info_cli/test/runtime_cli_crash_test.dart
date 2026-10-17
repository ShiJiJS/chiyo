import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:info_core/info_core.dart';
import 'support/runtime_harness.dart';

void main() {
  final compiled = Platform.environment['D6_COMPILED_CLI'];
  test(
    'compiled CLI death does not stop its worker draining a running approved process',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'runtime-cli-crash-',
      );
      final release = File('${folder.path}/release');
      final heartbeat = File('${folder.path}/heartbeat');
      final finished = File('${folder.path}/finished');
      final identity = File('${folder.path}/worker.json');
      await File('${folder.path}/api').writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final state = jsonDecode(await File('${Platform.environment['TEMP']}/worker-state.json').readAsString());
  await File('worker.json').writeAsString(jsonEncode({'workerPid':state['workerPid']}));
  final end = DateTime.now().add(const Duration(seconds: 15));
  var count = 0;
  while (!await File('release').exists()) {
    if (DateTime.now().isAfter(end)) exit(70);
    stdout.add(List<int>.filled(8192, 120));
    await stdout.flush();
    await File('heartbeat').writeAsString('${++count}', flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await File('finished').writeAsString('finished');
}
''');
      final h = await RuntimeHarness.create();
      final cli = await Process.start(compiled!, [
        '--port',
        '${h.server.port}',
      ]);
      final lines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = cli.stderr.drain<void>();
      addTearDown(() async {
        await release.writeAsString('release');
        cli.kill();
        await cli.exitCode;
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!await finished.exists() && DateTime.now().isBefore(end)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await lines.cancel();
        await errors;
        await h.close();
        // Preserve a failed fixture rather than deleting an active process cwd.
        if (await finished.exists()) {
          final released = DateTime.now().add(const Duration(seconds: 5));
          while (true) {
            try {
              await folder.delete(recursive: true);
              break;
            } on FileSystemException {
              if (DateTime.now().isAfter(released)) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
        }
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        cli.stdin.writeln(jsonEncode(input));
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(lines.current) as Map<String, dynamic>;
      }

      await command({'command': 'session', 'chatLabel': 'Compiled CLI crash'});
      final r = await command({
        'command': 'request-use',
        'purpose': 'Controlled crash recovery',
        'credentials': [
          {'alias': 'token', 'credentialId': h.credential.id, 'version': 1},
        ],
        'launch': {
          'receiver': 'gh_token',
          'executable': Platform.resolvedExecutable,
          'argv': ['api', 'user'],
          'cwd': folder.path,
          'env': {
            'GH_TOKEN': {'secret': 'token'},
          },
        },
      });
      expect(r['status'], 'pending');
      await h.service.owner.decideCredentialUse(
        r['requestId'] as String,
        approveCredential: true,
      );
      expect(
        (await command({
          'command': 'run-use',
          'requestId': r['requestId'],
        }))['status'],
        'accepted',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await identity.exists() || !await heartbeat.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Controlled compiled task did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final before = int.parse(await heartbeat.readAsString());
      expect(cli.kill(), isTrue);
      await cli.exitCode;
      final end = DateTime.now().add(const Duration(seconds: 2));
      var progressed = false;
      while (DateTime.now().isBefore(end)) {
        try {
          progressed = int.parse(await heartbeat.readAsString()) > before + 5;
        } on FormatException {
          // The controlled process may be replacing its heartbeat file.
        }
        if (progressed) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        progressed,
        isTrue,
        reason:
            'Worker must discard output after its CLI pipe closes and continue draining the approved process.',
      );
      await release.writeAsString('release');
    },
    skip: !Platform.isWindows || compiled == null,
  );
}
