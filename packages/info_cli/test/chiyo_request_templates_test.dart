import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_command_line.dart';
import 'package:info_cli/chiyo_programs.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  ChiyoCli offline() => ChiyoCli(
    environment: {},
    input: Stream.error(StateError('must not read stdin')),
  );
  test(
    'templates need no App, chat, configuration or stdin; generated exec inputs round-trip',
    () async {
      for (final kind in ['exec', 'ssh', 'fill']) {
        final variants = kind == 'exec'
            ? ['env', 'stdin', 'file']
            : kind == 'fill'
            ? ['ego', 'chrome', 'native']
            : [''];
        for (final via in variants) {
          final result = await offline().run([
            kind,
            'template',
            if (via.isNotEmpty) ...['--via', via],
            '--json',
          ]);
          expect(result.exitCode, 0, reason: result.render());
          final data = result.output['data'] as Map;
          final template = Map<String, dynamic>.from(data['template'] as Map);
          expect(RequestPresentation.fromJson(template).structured, true);
          expect(template, isNot(contains('sessionSecret')));
          if (kind == 'exec') {
            final plan = ChiyoProgramRequest.fromInvocation(
              ChiyoCommandLine().parse(['exec', 'request', '--input', '-']),
              businessInput: template,
            );
            expect(plan.title, template['title']);
            expect(plan.launch.bindings.single.via, via);
          }
        }
      }
    },
  );
  test(
    'out writes plain business JSON and never overwrites an existing request',
    () async {
      final root = await Directory.systemTemp.createTemp('request-template-');
      addTearDown(() => root.delete(recursive: true));
      final path = '${root.path}/request.json';
      expect(
        (await offline().run(['exec', 'template', '--out', path])).exitCode,
        0,
      );
      final file = File(path), original = await File(path).readAsString();
      expect(jsonDecode(original), containsPair('title', '简短的任务标题'));
      expect(
        (await offline().run(['ssh', 'template', '--out', path])).exitCode,
        2,
      );
      expect(await file.readAsString(), original);
      expect(await root.list().length, 1);
    },
  );
  test(
    'flags and business file cannot disagree about display text or launch',
    () {
      final grammar = ChiyoCommandLine();
      for (final args in [
        ['exec', 'request', '--input', 'x', '--title', '检查'],
        ['fill', 'request', '--input', 'x', '--summary', '说明'],
        ['exec', 'request', '--summary', '说明', '--purpose', '另一说明'],
      ]) {
        expect(() => grammar.parse(args), throwsA(isA<ChiyoUsageFailure>()));
      }
    },
  );
}
