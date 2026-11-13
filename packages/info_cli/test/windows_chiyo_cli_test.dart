@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:test/test.dart';

void main() {
  final delivery = Platform.environment['INFO_TEST_DELIVERY'];
  final executable = delivery == null
      ? Platform.environment['CHIYO_TEST_EXECUTABLE']
      : '$delivery/cli/chiyo.exe';

  group(
    'compiled chiyo on Windows',
    () {
      late Directory root;
      late String binary;
      late InformationService service;
      late AgentServer server;
      late File profile;
      final inherited = Map<String, String>.from(Platform.environment)
        ..removeWhere(
          (key, _) => key.startsWith('CHIYO_') || key.startsWith('CODEX_'),
        );

      Future<ProcessResult> run(
        List<String> args, {
        File? context,
        Map<String, String> environment = const {},
        String? input,
      }) async {
        final process = await Process.start(
          binary,
          args,
          workingDirectory: root.path,
          environment: {
            ...inherited,
            if (context != null) 'CHIYO_CONTEXT': context.path,
            ...environment,
          },
          includeParentEnvironment: false,
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        if (input != null) process.stdin.write(input);
        await process.stdin.close();
        final code = await process.exitCode.timeout(
          const Duration(seconds: 15),
        );
        return ProcessResult(process.pid, code, await output, await errors);
      }

      Map<String, dynamic> json(ProcessResult result) {
        expect(result.stderr, isEmpty);
        return jsonDecode(result.stdout as String) as Map<String, dynamic>;
      }

      setUp(() async {
        final base = Directory('../../build/wcli').absolute;
        await base.create(recursive: true);
        root = await Directory(
          await base.resolveSymbolicLinks(),
        ).createTemp('终端 ctx ');
        final cli = await Directory(
          '${root.path}/安装 包/cli',
        ).create(recursive: true);
        binary = (await File(executable!).copy('${cli.path}/chiyo.exe')).path;
        service = InformationService(
          repository: MemoryInformationRepository([
            InformationItem('fixture', 'Synthetic Windows fixture', '', 1, [
              const InformationField(
                'host',
                'Host',
                '',
                'synthetic.invalid',
                1,
              ),
            ]),
          ]),
        );
        final token = '${'A' * 22}.${'B' * 43}';
        server = await AgentServer.start(
          service.agent,
          port: 0,
          connectionToken: token,
          libraryId: 'windows-chiyo-library',
        );
        profile = await AgentConnectionProfile.local(
          port: server.port,
          deviceToken: token,
          libraryId: 'windows-chiyo-library',
        ).saveIn(Directory('${root.path}/profile'));
      });
      tearDown(() async {
        await server.close();
        await service.close();
        final base = Directory('../../build/wcli').absolute;
        final resolved = await root.resolveSymbolicLinks();
        if (!resolved.startsWith('${await base.resolveSymbolicLinks()}\\')) {
          throw StateError('CLI fixture escaped its build directory');
        }
        await root.delete(recursive: true);
      });

      Future<File> start(String folder) async {
        final context = File('${root.path}/$folder/私有 聊天.json');
        final result = await run([
          'chat',
          'start',
          '--agent',
          'Windows QA',
          '--id',
          'same-public-chat-id',
          '--label',
          'Windows 合成终端',
          '--connection',
          profile.path,
          '--context-out',
          context.path,
          '--json',
        ]);
        expect(result.exitCode, 0, reason: result.stdout as String);
        expect(json(result)['ok'], true);
        final saved = await ChiyoContext.load(context, environment: {});
        expect(result.stdout, isNot(contains(saved.secret)));
        expect(result.stdout, isNot(contains(saved.endCapability!)));
        expect(result.stdout, isNot(contains(context.path)));
        return context;
      }

      test(
        'Unicode/space executable emits UTF-8 help and context errors',
        () async {
          for (final args in [
            ['--help'],
            ['fill', '--help'],
            ['fill', 'request', '--help'],
            ['chat', 'start', '--help'],
            ['doctor', '--help'],
          ]) {
            final result = await run([...args, '--json']);
            expect(result.exitCode, 0);
            final value = json(result);
            expect(value['schemaVersion'], 1);
            expect(value['ok'], true);
            expect((value['data'] as Map)['help'], contains('用法：chiyo'));
          }
          final noContext = await run(
            ['requests', 'list', '--json'],
            environment: {'CODEX_THREAD_ID': 'same-public-chat-id'},
          );
          expect(noContext.exitCode, 3);
          expect((json(noContext)['error'] as Map)['code'], 'context_required');
        },
      );

      test(
        'a fresh SDK-free PowerShell discovers chiyo through only its PATH',
        () async {
          final windows = Platform.environment['SystemRoot']!;
          final result = await Process.run(
            '$windows/System32/WindowsPowerShell/v1.0/powershell.exe',
            [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$command = Get-Command chiyo.exe -CommandType Application -ErrorAction Stop
$helpText = & chiyo.exe fill request --help --json
if ($LASTEXITCODE -ne 0) { throw 'Compiled help command failed.' }
@{ resolved=$command.Source; help=($helpText | ConvertFrom-Json) } | ConvertTo-Json -Depth 6 -Compress
''',
            ],
            workingDirectory: root.path,
            environment: {
              ...inherited,
              'PATH':
                  '${File(binary).parent.path};$windows/System32;$windows;$windows/System32/WindowsPowerShell/v1.0',
            },
            includeParentEnvironment: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(result.exitCode, 0, reason: result.stderr as String);
          final observed = json(result);
          expect(
            (observed['resolved'] as String)
                .replaceAll('\\', '/')
                .toLowerCase(),
            binary.replaceAll('\\', '/').toLowerCase(),
          );
          expect((observed['help'] as Map)['ok'], true);
          expect(
            ((observed['help'] as Map)['data'] as Map)['help'],
            contains('--selector'),
          );
        },
      );

      test(
        'separate terminals keep private chats apart after reopening and ending one',
        () async {
          final a = await start('terminal A');
          final b = await start('terminal B');
          final ca = await ChiyoContext.load(a, environment: {});
          final cb = await ChiyoContext.load(b, environment: {});
          expect(ca.chatId, cb.chatId);
          expect(ca.secret, isNot(cb.secret));
          final ra = service.agent.request(ca.secret, 'Windows A only', [
            const FieldRef('fixture', 'host'),
          ], operationId: 'terminal-a-request');
          final rb = service.agent.request(cb.secret, 'Windows B only', [
            const FieldRef('fixture', 'host'),
          ], operationId: 'terminal-b-request');
          final lists = await Future.wait([
            run(['requests', 'list', '--json'], context: a),
            run(['requests', 'list', '--json'], context: b),
          ]);
          for (var index = 0; index < lists.length; index++) {
            expect(lists[index].exitCode, 0);
            final records =
                (json(lists[index])['data'] as Map)['records'] as List;
            expect(records.map((row) => (row as Map)['id']).toList(), [
              index == 0 ? ra.id : rb.id,
            ]);
            expect(
              lists[index].stdout,
              isNot(contains(index == 0 ? rb.id : ra.id)),
            );
          }
          final reopened = await run(['chat', 'show', '--json'], context: a);
          expect(reopened.exitCode, 0);
          expect(
            (json(reopened)['data'] as Map)['libraryId'],
            'windows-chiyo-library',
          );
          final ended = await run(['chat', 'end', '--json'], context: a);
          expect(ended.exitCode, 0);
          expect(json(ended)['ok'], true);
          expect(
            (await run(['chat', 'show', '--json'], context: a)).exitCode,
            3,
          );
          expect(
            (await run(['chat', 'show', '--json'], context: b)).exitCode,
            0,
          );
        },
      );

      test(
        'independent stdin selects only the supplied synthetic context',
        () async {
          final context = await start('stdin terminal');
          final saved = await ChiyoContext.load(context, environment: {});
          final result = await run([
            '--context-stdin',
            'chat',
            'show',
            '--json',
          ], input: jsonEncode({'association': context.path}));
          expect(result.exitCode, 0);
          expect(json(result)['ok'], true);
          expect(result.stdout, isNot(contains(context.path)));
          expect(result.stdout, isNot(contains(saved.secret)));
          final mismatch = await run(
            ['chat', 'show', '--json'],
            context: context,
            environment: {'CHIYO_CHAT_ID': 'another-chat'},
          );
          expect(mismatch.exitCode, 3);
          expect(json(mismatch)['ok'], false);
        },
      );
    },
    skip: executable == null
        ? 'Set CHIYO_TEST_EXECUTABLE or INFO_TEST_DELIVERY for the compiled entry.'
        : false,
  );
}
