import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'a real CLI accepts the owner-registered Unicode material path even when its TEMP differs from the desktop',
    () async {
      final root = await Directory.systemTemp.createTemp('文件 交付 fixture ');
      final serviceTemp = await Directory('${root.path}/桌面 材料目录').create();
      final cwd = await Directory('${root.path}/工作 位置').create();
      final support = File(
        'test/support/credential_file_child.dart',
      ).absolute.uri;
      await File('${cwd.path}/ssm').writeAsString(
        "import 'dart:io'; import 'dart:convert'; import '$support' as receiver; Future<void> main(List<String> args) async {stdout.writeln(jsonEncode({'unicodeMaterialPath':Platform.environment['AWS_SHARED_CREDENTIALS_FILE']!.contains('桌面 材料目录')})); await receiver.main(args);}",
      );
      final owner = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'test/support/file_service_fixture.dart'],
        workingDirectory: Directory.current.path,
        environment: {'TEMP': serviceTemp.path, 'TMP': serviceTemp.path},
      );
      final ownerLines = StreamIterator(
        owner.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final ownerErrors = owner.stderr.drain<void>();
      expect(
        await ownerLines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      final ready = jsonDecode(ownerLines.current) as Map<String, dynamic>;
      final cli = await Process.start(Platform.resolvedExecutable, [
        'run',
        'bin/info.dart',
        '--port',
        '${ready['port']}',
      ], workingDirectory: Directory.current.path);
      final cliLines = StreamIterator(
        cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final cliErrors = cli.stderr.drain<void>();
      addTearDown(() async {
        await cli.stdin.close();
        await cliLines.cancel();
        await cli.exitCode.timeout(const Duration(seconds: 10));
        await cliErrors;
        await owner.stdin.close();
        await ownerLines.cancel();
        await owner.exitCode.timeout(const Duration(seconds: 10));
        await ownerErrors;
        // Only this newly created fixture is removed, and only when empty.
        await File('${cwd.path}/ssm').delete();
        await cwd.delete();
        if (await serviceTemp.list().isEmpty) {
          await serviceTemp.delete();
          await root.delete();
        }
      });
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        cli.stdin.writeln(jsonEncode(input));
        await cli.stdin.flush();
        expect(
          await cliLines.moveNext().timeout(const Duration(seconds: 10)),
          isTrue,
        );
        return jsonDecode(cliLines.current) as Map<String, dynamic>;
      }

      await command({'command': 'session', 'chatLabel': 'Isolated file CLI'});
      final request = await command({
        'command': 'request-use',
        'purpose': 'Verify a scoped file path',
        'credentials': [
          {
            'alias': 'token',
            'credentialId': ready['credentialId'],
            'version': ready['version'],
          },
        ],
        'launch': {
          'receiver': 'aws_shared_credentials',
          'executable': ready['executable'],
          'argv': [
            'ssm',
            'get-parameter',
            '--name',
            '{{file:token}}',
            '--region',
            'us-east-1',
          ],
          'cwd': cwd.path,
          'env': {
            'AWS_SHARED_CREDENTIALS_FILE': {'file': 'token'},
          },
        },
      });
      expect(request['status'], 'pending');
      owner.stdin.writeln(
        jsonEncode({'command': 'approve', 'requestId': request['requestId']}),
      );
      await owner.stdin.flush();
      expect(
        await ownerLines.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      expect(jsonDecode(ownerLines.current), {'status': 'ok'});
      final run = await command({
        'command': 'run-use',
        'requestId': request['requestId'],
      });
      expect(run['status'], 'accepted');
      late Map<String, dynamic> status;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (true) {
        status = await command({
          'command': 'execution-status',
          'executionId': run['executionId'],
        });
        if (!{'preparing', 'running'}.contains(status['executionState']) &&
            status['cleanupState'] != 'pending') {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          fail('Controlled file task did not finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(
        status['executionState'],
        'exited',
        reason: '${status['errorCode']}',
      );
      expect(status['exitCode'], 0);
      expect(status['cleanupState'], 'complete');
      final output = await command({
        'command': 'execution-output',
        'executionId': run['executionId'],
      });
      final bytes = (output['chunks'] as List)
          .where((c) => c['stream'] == 'stdout')
          .expand<int>((c) => base64Decode(c['dataBase64'] as String))
          .toList();
      final messages = const LineSplitter()
          .convert(utf8.decode(bytes))
          .map(jsonDecode)
          .toList();
      expect(messages.first, {'unicodeMaterialPath': true});
      expect(messages.last, {
        'materialMatches': true,
        'configEmpty': true,
        'privateAcl': true,
        'literalPreserved': true,
        'otherAuthAbsent': true,
      });
      expect(await serviceTemp.list().isEmpty, isTrue);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
