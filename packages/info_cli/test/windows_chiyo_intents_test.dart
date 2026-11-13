@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_intents.dart';
import 'package:info_core/info_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  const scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  setUp(() async {
    final base = Directory('../../build/windows-intents-tests').absolute;
    await base.create(recursive: true);
    root = await Directory(
      await base.resolveSymbolicLinks(),
    ).createTemp('意图 QA 空格 ');
  });
  tearDown(() async {
    final base = await Directory(
      '../../build/windows-intents-tests',
    ).resolveSymbolicLinks();
    if (!(await root.resolveSymbolicLinks()).startsWith('$base\\')) {
      throw StateError('Intent fixture escaped build root');
    }
    await root.delete(recursive: true);
  });
  Future<ProcessResult> child(Directory folder, String variant) => Process.run(
    Platform.resolvedExecutable,
    [
      '--packages=${File('.dart_tool/package_config.json').absolute.path}',
      'test/support/chiyo_intent_child.dart',
      folder.path,
      scope,
      'first-send',
      variant,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  test(
    'independent first sender processes publish one DPAPI intent in a Unicode/space path',
    () async {
      final folder = Directory('${root.path}/私有 意图');
      final results = await Future.wait(
        List.generate(4, (_) => child(folder, 'same')),
      );
      for (final result in results) {
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
      final dates = results
          .map((r) => (jsonDecode(r.stdout as String) as Map)['createdAt'])
          .toSet();
      expect(dates, hasLength(1));
      final store = ChiyoIntentStore(folder, scope);
      expect(await store.list(), hasLength(1));
      final file = (await Directory(
        '${folder.path}/$scope',
      ).list().where((e) => e is File).toList()).single;
      WindowsPrivateFiles.verify(folder.path, directory: true);
      WindowsPrivateFiles.verify(file.path);
      expect(
        utf8.decode(await File(file.path).readAsBytes(), allowMalformed: true),
        isNot(contains('Synthetic 私有 意图')),
      );
      expect(
        (await store.read('first-send'))!.payload['purpose'],
        'Synthetic 私有 意图',
      );
      final changed = await child(folder, 'changed');
      expect(changed.exitCode, 2);
      expect(
        (jsonDecode(changed.stdout as String) as Map)['code'],
        'operation_conflict',
      );
      expect(
        (await store.read('first-send'))!.createdAt.toIso8601String(),
        dates.single,
      );
      expect(await ChiyoIntentStore(folder, 'b' * 64).read('first-send'), null);
    },
  );
  test(
    'a general readable folder is refused without changing its ACL or writing intent',
    () async {
      final folder = await Directory('${root.path}/ordinary').create();
      final grant = await Process.run('icacls', [
        folder.path,
        '/grant',
        '*S-1-5-32-545:(OI)(CI)(RX)',
      ]);
      expect(grant.exitCode, 0);
      final before = await Process.run('icacls', [folder.path]);
      await expectLater(
        ChiyoIntentStore(folder, scope).remember('access-request', {
          'purpose': 'Synthetic',
        }, operationId: 'ordinary'),
        throwsA(isA<ChiyoIntentFailure>()),
      );
      final after = await Process.run('icacls', [folder.path]);
      expect(after.stdout, before.stdout);
      expect(await folder.list().toList(), isEmpty);
    },
  );
}
