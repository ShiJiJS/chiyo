import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_command_line.dart';
import 'package:info_cli/chiyo_programs.dart';
import 'package:test/test.dart';

void main() {
  final grammar = ChiyoCommandLine();
  final root = Platform.isWindows ? r'C:\synthetic' : '/synthetic';
  List<String> flags(String via) => [
    'exec',
    'request',
    '--credential',
    'saved-a',
    '--version',
    '2',
    '--via',
    via,
    '--executable',
    '$root/tool',
    '--cwd',
    '$root/work',
    '--purpose',
    '查询合成服务',
  ];
  ChiyoProgramRequest request(List<String> args) =>
      ChiyoProgramRequest.fromInvocation(grammar.parse(args));

  test(
    'single credential flags map to real stdin, environment or managed file positions',
    () {
      final reference = {'credentialId': 'saved-a', 'version': 2};
      final env = request([
        ...flags('env'),
        '--variable',
        'DB_PASSWORD',
        '--arg=status',
        '--arg=a,b',
      ]);
      expect(env.launch.argv.map((v) => v.toJson()), ['status', 'a,b']);
      expect(env.launch.env['DB_PASSWORD']!.toJson(), reference);
      final stdin = request(flags('stdin'));
      expect(stdin.launch.stdin!.toJson(), reference);
      expect(stdin.launch.env, isEmpty);
      final file = request([
        ...flags('file'),
        '--arg=--key',
        '--arg=status',
        '--file-argument',
        '1',
      ]);
      expect(file.launch.argv.map((v) => v.toJson()), [
        '--key',
        {'file': reference},
        'status',
      ]);
      final fileEnv = request([...flags('file'), '--variable', 'CLIENT_KEY']);
      expect(fileEnv.launch.env['CLIENT_KEY']!.toJson(), {'file': reference});
      expect(file.toJson().containsKey('protocolVersion'), false);
    },
  );

  test(
    'complex business JSON uses the same model and cannot choose a chat, approval or internal script protocol',
    () {
      final invocation = grammar.parse(['exec', 'request', '--input', '-']);
      final data = <String, dynamic>{
        'purpose': '查询合成服务',
        'launch': {
          'executable': '$root/tool',
          'cwd': '$root/work',
          'argv': <Object?>[],
          'env': {
            'DB_PASSWORD': {'credentialId': 'saved-a', 'version': 2},
          },
        },
      };
      final parsed = ChiyoProgramRequest.fromInvocation(
        invocation,
        businessInput: data,
      );
      expect(
        parsed.toJson(),
        request([...flags('env'), '--variable', 'DB_PASSWORD']).toJson(),
      );
      for (final field in [
        'agentName',
        'sessionSecret',
        'protocolVersion',
        'approved',
        'alias',
      ]) {
        expect(
          () => ChiyoProgramRequest.fromInvocation(
            invocation,
            businessInput: {...data, field: 'forged'},
          ),
          throwsA(isA<ChiyoUsageFailure>()),
        );
      }
      expect(
        () => ChiyoProgramRequest.fromInvocation(invocation),
        throwsA(isA<ChiyoUsageFailure>()),
      );
    },
  );

  test(
    'invalid combinations and output bounds fail in parsing before connection or input reads',
    () {
      for (final args in [
        flags('env'),
        [...flags('env'), '--variable', 'PASSWORD', '--file-argument', '0'],
        [...flags('stdin'), '--variable', 'PASSWORD'],
        flags('file'),
        [...flags('file'), '--variable', 'KEY', '--file-argument', '0'],
        [...flags('file'), '--arg=--key', '--file-argument', '2'],
        [...flags('file'), '--file-argument', '-1'],
        [...flags('stdin'), '--input', '-'],
        ['exec', 'request', '--input', '-', '--arg=x'],
        ['exec', 'output'],
        ['exec', 'output', '--operation', 'one', '--cursor', '-1'],
        ['exec', 'output', '--operation', 'one', '--limit', '17'],
      ]) {
        expect(() => grammar.parse(args), throwsA(isA<ChiyoUsageFailure>()));
      }
      expect(
        grammar.parse([
          'exec',
          'run',
          '--request',
          'r',
          '--input',
          'command.json',
        ]).options['input'],
        'command.json',
      );
      expect(
        grammar.parse([
          'exec',
          'output',
          '--operation',
          'one',
          '--cursor',
          '3',
        ]).options['limit'],
        '16',
      );
    },
  );

  test('program help remains usable with no App, context or stdin', () async {
    for (final verb in ['request', 'run', 'output']) {
      final result = await ChiyoCli(
        environment: {},
        input: Stream<List<int>>.error(StateError('must not read stdin')),
      ).run(['exec', verb, '--help', '--json']);
      expect(result.exitCode, 0);
      expect(result.render(), contains('--operation'));
    }
  });
}
