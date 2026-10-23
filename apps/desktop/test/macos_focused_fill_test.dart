import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/macos_focused_fill.dart';

final _application = FocusedFillApplication.fromJson({
  'executable': '/Applications/合成 App.app/Contents/MacOS/Test',
  'sha256': List.filled(64, 'a').join(),
});
Map<String, Object?> _ready(String state) => {
  'format': 1,
  'state': state,
  'application': _application.toJson(),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_info_manage/focused_fill');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handle;
  MacOSFocusedFillDriver driver() => MacOSFocusedFillDriver(
    channel: channel,
    timeout: const Duration(milliseconds: 40),
  );
  setUp(() {
    calls = [];
    handle = (call) async => switch (call.method) {
      'inspect' => _ready('ready'),
      'prepare' => _ready('prepared'),
      'send' => {'format': 1, 'state': 'sent'},
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handle(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'construction has no platform calls; discovery releases its local connection',
    () async {
      final adapter = driver();
      expect(calls, isEmpty);
      final result = await adapter.inspectTarget();
      expect(result.application!.matches(_application), isTrue);
      expect(calls.map((c) => c.method), ['inspect', 'close']);
      expect(calls.first.arguments, calls.last.arguments);
      expect((calls.first.arguments as Map).keys, ['connection']);
    },
  );
  test(
    'prepared input carries only bounded UTF16 bytes and close is idempotent',
    () async {
      final prepared = await driver().prepare(_application);
      final units = '合成🦊'.codeUnits;
      handle = (call) async {
        if (call.method == 'send') {
          final args = call.arguments as Map;
          expect(args.keys.toSet(), {'connection', 'bytes'});
          final bytes = args['bytes'] as Uint8List;
          expect(
            List.generate(
              units.length,
              (i) =>
                  ByteData.sublistView(bytes).getUint16(i * 2, Endian.little),
            ),
            units,
          );
          return {'format': 1, 'state': 'sent'};
        }
        return null;
      };
      expect((await prepared.sendBatch(units)).state, FocusedFillState.sent);
      expect((await prepared.sendBatch(units)).state, FocusedFillState.sent);
      await prepared.close();
      await prepared.close();
      expect((await prepared.sendBatch(units)).state, FocusedFillState.refused);
      expect(calls.map((c) => c.method), ['prepare', 'send', 'send', 'close']);
      final id = (calls.first.arguments as Map)['connection'];
      expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(
        calls.every((call) => (call.arguments as Map)['connection'] == id),
        isTrue,
      );
    },
  );
  test(
    'foreign platform is refused before native access; changed echo is refused and closed',
    () async {
      final windows = FocusedFillApplication.fromJson({
        'executable': r'C:\Synthetic\Test.exe',
        'sha256': _application.sha256,
      });
      await expectLater(
        driver().prepare(windows),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(calls, isEmpty);
      handle = (call) async => call.method == 'prepare'
          ? {
              ..._ready('prepared'),
              'application': {
                ..._application.toJson(),
                'executable': _application.executable.toLowerCase(),
              },
            }
          : null;
      await expectLater(
        driver().prepare(_application),
        throwsA(
          isA<CredentialUseFailure>().having(
            (e) => e.code,
            'code',
            'application_changed',
          ),
        ),
      );
      expect(calls.map((c) => c.method), ['prepare', 'close']);
    },
  );
  for (final state in ['refused', 'partial', 'unknown']) {
    test('$state is terminal and does not permit a follow-up send', () async {
      final prepared = await driver().prepare(_application);
      handle = (call) async => call.method == 'send'
          ? {
              'format': 1,
              'state': state,
              'errorCode': state == 'unknown'
                  ? 'fill_unknown'
                  : 'focus_changed',
            }
          : null;
      final result = await prepared.sendBatch([65]);
      expect(result.state.name, state);
      expect((await prepared.sendBatch([66])).state, FocusedFillState.refused);
      expect(calls.map((c) => c.method), ['prepare', 'send', 'close']);
    });
  }
  test(
    'lost send reply is unknown, closes once and never retries even after a late reply',
    () async {
      final prepared = await driver().prepare(_application);
      final late = Completer<Object?>();
      handle = (call) async => call.method == 'send' ? late.future : null;
      final result = await prepared.sendBatch([65]);
      expect(result.state, FocusedFillState.unknown);
      expect(result.errorCode, 'fill_unknown');
      late.complete({'format': 1, 'state': 'sent'});
      await Future<void>.delayed(Duration.zero);
      expect((await prepared.sendBatch([65])).state, FocusedFillState.refused);
      expect(calls.map((c) => c.method), ['prepare', 'send', 'close']);
    },
  );
  test(
    'concurrent send refuses busy and preserves the original send result',
    () async {
      final prepared = await driver().prepare(_application);
      final pending = Completer<Object?>();
      final started = Completer<void>();
      handle = (call) async {
        if (call.method == 'send') {
          started.complete();
          return pending.future;
        }
        return null;
      };
      final first = prepared.sendBatch([65]);
      await started.future;
      expect((await prepared.sendBatch([66])).errorCode, 'busy');
      pending.complete({'format': 1, 'state': 'sent'});
      expect((await first).state, FocusedFillState.sent);
      await prepared.close();
      expect(calls.map((c) => c.method), ['prepare', 'send', 'close']);
    },
  );
  test('invalid UTF16 is refused before any input message', () async {
    for (final units in <List<int>>[
      [],
      [0],
      [10],
      [127],
      [-1],
      [0x10000],
      [0xd800],
      [0xdc00],
      List.filled(17, 65),
    ]) {
      calls.clear();
      final prepared = await driver().prepare(_application);
      expect((await prepared.sendBatch(units)).errorCode, 'unsupported_secret');
      expect(calls.map((c) => c.method), ['prepare', 'close']);
    }
  });
  test(
    'malformed post replies are unknown without projecting native details',
    () async {
      for (final raw in [
        null,
        'raw private exception detail',
        {'format': 1, 'state': 'sent', 'pid': 123},
        {
          'format': 1,
          'state': 'refused',
          'errorCode': 'raw private exception detail',
        },
      ]) {
        handle = (call) async => call.method == 'prepare'
            ? _ready('prepared')
            : call.method == 'send'
            ? raw
            : null;
        final prepared = await driver().prepare(_application);
        final result = await prepared.sendBatch([65]);
        expect(result.state, FocusedFillState.unknown);
        expect(result.errorCode, 'fill_unknown');
      }
    },
  );
  test(
    'prepare timeout cancels the same connection before any secret is sent',
    () async {
      final pending = Completer<Object?>();
      handle = (call) async => call.method == 'prepare' ? pending.future : null;
      await expectLater(
        driver().prepare(_application),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(calls.map((c) => c.method), ['prepare', 'close']);
      expect(
        (calls.first.arguments as Map)['connection'],
        (calls.last.arguments as Map)['connection'],
      );
      pending.complete(_ready('prepared'));
    },
  );
}
