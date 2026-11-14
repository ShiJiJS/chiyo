import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/macos_native_background_fill.dart';

final _scope = List.filled(64, 'a').join();
final _snapshot = <String, Object?>{
  'targetId': '11111111-1111-1111-1111-111111111111',
  'helperInstanceId': '22222222-2222-2222-2222-222222222222',
  'windowId': '33333333-3333-3333-3333-333333333333',
  'platform': 'macos',
  'controlKind': 'appkit_secure_text',
  'application': {
    'executable': '/synthetic/App',
    'sha256': List.filled(64, 'b').join(),
  },
  'appId': 'synthetic.app',
  'appName': 'Synthetic',
  'windowTitle': 'Synthetic login',
  'fieldLabel': 'Password',
};
const _lease = '44444444-4444-4444-4444-444444444444';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('agent_info_manage/native_background_fill');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late List<String> owners;
  late Future<Object?> Function(MethodCall) handler;
  MacOSNativeBackgroundFillDriver driver() => MacOSNativeBackgroundFillDriver(
    channel: channel,
    timeout: const Duration(milliseconds: 100),
  );
  Future<PreparedNativeFill> prepare() => driver().prepare(
    scope: _scope,
    targetId: _snapshot['targetId'] as String,
  );
  setUp(() {
    calls = [];
    owners = [];
    handler = (call) async => switch (call.method) {
      'discover' => {
        'format': 1,
        'state': 'ready',
        'targets': [_snapshot],
      },
      'prepare' => {
        'format': 1,
        'state': 'prepared',
        'target': _snapshot,
        'leaseId': _lease,
      },
      'setValue' => {'format': 1, 'state': 'sent'},
      'close' => {'format': 1, 'state': 'closed'},
      'release' => {'format': 1, 'state': 'released'},
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (call) {
      final envelope = call.arguments as Map;
      expect(envelope.keys.toSet(), {'owner', 'request'});
      expect(envelope['owner'], matches(RegExp(r'^[0-9a-f]{32}$')));
      owners.add(envelope['owner'] as String);
      final request = MethodCall(call.method, envelope['request']);
      calls.add(request);
      return handler(request);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'discovery carries scope and metadata; construction does not contact helper',
    () async {
      final d = driver();
      expect(calls, isEmpty);
      final found = await d.discover(scope: _scope, appId: 'synthetic.app');
      expect(found.single.targetId, _snapshot['targetId']);
      expect((calls.single.arguments as Map).keys.toSet(), {
        'format',
        'command',
        'scope',
        'appId',
      });
    },
  );
  test('full UTF8 value follows preflight and callback, only once', () async {
    final p = await prepare();
    var approved = false;
    Uint8List? sent;
    final old = handler;
    handler = (call) async {
      if (call.method == 'setValue') {
        expect(approved, isTrue);
        sent = (call.arguments as Map)['bytes'] as Uint8List;
        expect(utf8.decode(sent!), ' 假🙂e\u0301 ');
      }
      return old(call);
    };
    final result = await p.setValue(
      utf8.encode(' 假🙂e\u0301 '),
      beforeDispatch: () async {
        expect(calls.last.method, 'prepare');
        approved = true;
      },
    );
    expect(result.state, NativeFillState.sent);
    expect(
      (await p.setValue(
        utf8.encode('another'),
        beforeDispatch: () async {},
      )).state,
      NativeFillState.refused,
    );
    expect(calls.where((c) => c.method == 'setValue'), hasLength(1));
  });
  test(
    'callback failure and close during callback never dispatch a setter',
    () async {
      final p = await prepare();
      final result = await p.setValue(
        utf8.encode('synthetic'),
        beforeDispatch: () async {
          throw const CredentialUseFailure('grant_revoked');
        },
      );
      expect(result.errorCode, 'grant_revoked');
      final q = await prepare();
      expect(
        (await q.setValue(
          utf8.encode('synthetic'),
          beforeDispatch: q.close,
        )).state,
        NativeFillState.refused,
      );
      expect(calls.where((c) => c.method == 'setValue'), isEmpty);
    },
  );
  test('timeout after setter dispatch is unknown and never replayed', () async {
    final p = await prepare();
    final old = handler;
    handler = (call) =>
        call.method == 'setValue' ? Completer<Object?>().future : old(call);
    expect(
      (await p.setValue(
        utf8.encode('synthetic'),
        beforeDispatch: () async {},
      )).state,
      NativeFillState.unknown,
    );
    await p.setValue(utf8.encode('synthetic'), beforeDispatch: () async {});
    expect(calls.where((c) => c.method == 'setValue'), hasLength(1));
  });
  test(
    'changed snapshot or helper incarnation refuses before callback',
    () async {
      final target = NativeFillTarget.fromJson(
        Map<String, dynamic>.from(_snapshot),
      );
      final old = handler;
      handler = (call) async => call.method == 'prepare'
          ? {
              'format': 1,
              'state': 'prepared',
              'target': {
                ..._snapshot,
                'helperInstanceId': '99999999-9999-9999-9999-999999999999',
              },
              'leaseId': _lease,
            }
          : old(call);
      await expectLater(
        driver().prepare(
          scope: _scope,
          targetId: target.targetId,
          expected: target,
        ),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(calls.where((c) => c.method == 'setValue'), isEmpty);
    },
  );
  test(
    'close is idempotent and does not release the retained target',
    () async {
      final p = await prepare();
      await p.close();
      await p.close();
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
      expect(calls.where((c) => c.method == 'release'), isEmpty);
      await driver().release(
        scope: _scope,
        targetId: _snapshot['targetId'] as String,
      );
      expect(calls.last.method, 'release');
    },
  );
  test(
    'malformed UTF8, empty values and invalid scopes have no input dispatch',
    () async {
      for (final bytes in <List<int>>[
        [],
        [255],
        [300],
        utf8.encode('line\nbreak'),
      ]) {
        final p = await prepare();
        expect(
          (await p.setValue(bytes, beforeDispatch: () async {})).errorCode,
          'unsupported_secret',
        );
        await p.close();
      }
      await expectLater(
        driver().discover(scope: 'raw-chat-id', appId: 'synthetic.app'),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(calls.where((c) => c.method == 'setValue'), isEmpty);
    },
  );
  test(
    'disposing one driver leaves another driver on the same scope usable',
    () async {
      final a = driver(), b = driver();
      await a.discover(scope: _scope, appId: 'synthetic.app');
      final aOwner = owners.last;
      await b.discover(scope: _scope, appId: 'synthetic.app');
      final bOwner = owners.last;
      expect(aOwner, isNot(bOwner));
      final p = await b.prepare(
        scope: _scope,
        targetId: _snapshot['targetId'] as String,
      );
      await a.dispose();
      expect(owners.last, aOwner);
      final result = await p.setValue(
        utf8.encode('synthetic'),
        beforeDispatch: () async {},
      );
      expect(result.state, NativeFillState.sent);
      expect(owners.last, bOwner);
      expect(owners[calls.indexWhere((c) => c.method == 'setValue')], bOwner);
    },
  );
  test(
    'owned dispose closes its scopes once and cancels old preparations',
    () async {
      final d = driver();
      await d.discover(scope: _scope, appId: 'synthetic.app');
      final p = await d.prepare(
        scope: _scope,
        targetId: _snapshot['targetId'] as String,
      );
      await d.dispose();
      await d.dispose();
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      expect((calls.last.arguments as Map).keys.toSet(), {'format', 'command'});
      expect(
        (await p.setValue(
          utf8.encode('synthetic'),
          beforeDispatch: () async {},
        )).state,
        NativeFillState.refused,
      );
      await expectLater(
        d.discover(scope: _scope, appId: 'synthetic.app'),
        throwsA(isA<CredentialUseFailure>()),
      );
      expect(calls.where((c) => c.method == 'setValue'), isEmpty);
    },
  );
}
