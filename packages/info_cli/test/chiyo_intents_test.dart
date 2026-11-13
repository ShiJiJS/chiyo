import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_intents.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ChiyoIntentStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('chiyo-intent-');
    store = ChiyoIntentStore(Directory('${root.path}/intents'), 'a' * 64);
  });
  tearDown(() => root.delete(recursive: true));
  Map<String, dynamic> payload() => {
    'command': 'request',
    'purpose': 'Synthetic check',
    'fields': [
      {'itemId': 'synthetic-item', 'fieldId': 'host'},
    ],
  };
  test(
    'parallel first sends publish one complete immutable intent; changed content conflicts',
    () async {
      final records = await Future.wait(
        List.generate(
          4,
          (_) => store.remember(
            'access-request',
            payload(),
            operationId: 'stable-id',
          ),
        ),
      );
      expect(records.map((r) => r.createdAt).toSet(), hasLength(1));
      expect(await store.list(), hasLength(1));
      final reordered = {
        'fields': payload()['fields'],
        'purpose': 'Synthetic check',
        'command': 'request',
      };
      expect(
        (await store.remember(
          'access-request',
          reordered,
          operationId: 'stable-id',
        )).createdAt,
        records.first.createdAt,
      );
      await expectLater(
        store.remember('access-request', {
          ...payload(),
          'purpose': 'Changed',
        }, operationId: 'stable-id'),
        throwsA(
          isA<ChiyoIntentFailure>().having(
            (e) => e.code,
            'code',
            'operation_conflict',
          ),
        ),
      );
      await expectLater(
        store.remember('fill-request', payload(), operationId: 'stable-id'),
        throwsA(isA<ChiyoIntentFailure>()),
      );
      expect((await store.read('stable-id'))!.payload, payload());
      final other = ChiyoIntentStore(store.root, 'b' * 64);
      expect(await other.read('stable-id'), null);
      expect(await other.list(), isEmpty);
      expect(
        jsonEncode(records.first.summary),
        isNot(contains('Synthetic check')),
      );
    },
  );
  test(
    'generated IDs are distinct; corrupt, redirected, oversized and public records cannot be adopted',
    () async {
      final first = await store.remember('access-request', payload());
      final second = await store.remember('access-request', payload());
      expect(first.operationId, isNot(second.operationId));
      expect(ChiyoIntentStore.validId(first.operationId), true);
      final files = await Directory(
        '${store.root.path}/${store.scope}',
      ).list().where((e) => e is File).toList();
      final file = File(files.first.path);
      final saved = await file.readAsBytes();
      await file.writeAsString('{"role":"not-an-intent"}');
      await expectLater(store.list(), throwsA(isA<ChiyoIntentFailure>()));
      await file.writeAsBytes(saved);
      if (!Platform.isWindows) {
        await Process.run('/bin/chmod', ['644', file.path]);
        await expectLater(store.list(), throwsA(isA<ChiyoIntentFailure>()));
        expect((await file.stat()).mode & 0x1FF, 0x1A4);
        await Process.run('/bin/chmod', ['600', file.path]);
        final redirect = Directory('${root.path}/redirect');
        await redirect.create();
        await Link('${root.path}/linked').create(redirect.path);
        final linked = ChiyoIntentStore(
          Directory('${root.path}/linked'),
          'c' * 64,
        );
        await expectLater(
          linked.remember('access-request', payload()),
          throwsA(isA<ChiyoIntentFailure>()),
        );
        expect(await redirect.list().toList(), isEmpty);
      }
      await expectLater(
        store.remember('access-request', {'oversized': 'x' * (101 * 1024)}),
        throwsA(
          isA<ChiyoIntentFailure>().having(
            (e) => e.code,
            'code',
            'intent_too_large',
          ),
        ),
      );
      expect(await store.list(), hasLength(2));
    },
  );
}
