// Synthetic local acceptance. Control files contain actions/public facts only.
// Receiver reads its own fake input; neither production broker nor UI reads it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/bundled_focused_fill.dart';
import 'package:info_desktop/main.dart';
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const lockedOnly = bool.fromEnvironment('FILL_LOCKED_ONLY');
  // Preserve the default accessibility regression. A separate baseline can
  // omit the test-created handle; platform-requested semantics still applies.
  const testSemantics = bool.fromEnvironment(
    'FILL_TEST_SEMANTICS',
    defaultValue: true,
  );
  testWidgets(
    lockedOnly
        ? 'trusted bundle and encrypted bootstrap refuse a locked desktop without input'
        : 'trusted bundled helper, SQLCipher, real approval UI and independent CLI native input (test semantics: $testSemantics)',
    (tester) => runFocusedFillNative(
      tester,
      mount: tester.pumpWidget,
      verifyFrameworkErrors: () => expect(tester.takeException(), isNull),
      lockedOnly: lockedOnly,
      testSemanticsRequested: testSemantics,
    ),
    timeout: const Timeout(Duration(minutes: 6)),
    semanticsEnabled: testSemantics,
  );
}

/// The same assertions can also run under the production WidgetsBinding.
/// This separates testWidgets' native semantics lifetime from app behavior.
Future<void> runFocusedFillNative(
  WidgetController tester, {
  required Future<void> Function(Widget) mount,
  required void Function() verifyFrameworkErrors,
  required bool lockedOnly,
  bool? testSemanticsRequested,
  String harness = 'testWidgets',
}) async {
  const cliPath = String.fromEnvironment('FILL_CLI'),
      receiverPath = String.fromEnvironment('FILL_RECEIVER'),
      evidence = String.fromEnvironment('FILL_EVIDENCE');
  expect(cliPath, isNotEmpty);
  expect(receiverPath, isNotEmpty);
  expect(evidence, isNotEmpty);
  final folder = Directory(evidence);
  await folder.create(recursive: true);
  final random = Random.secure();
  final secret =
      '  A1b2C3d4E5f6G7h8${base64Url.encode(List.generate(24, (_) => random.nextInt(256)))}中文🧭  ';
  void scan(String text) {
    if (text.contains(secret) ||
        text.contains(
          jsonEncode(secret).substring(1, jsonEncode(secret).length - 1),
        )) {
      throw StateError('Synthetic secret escaped its private channel');
    }
  }

  Future<void> record(Map<String, Object?> value) async {
    final text = jsonEncode(value);
    scan(text);
    await File('${folder.path}/state.json').writeAsString(text, flush: true);
    await File(
      '${folder.path}/events.jsonl',
    ).writeAsString('$text\n', mode: FileMode.append, flush: true);
  }

  final driver = await loadBundledFocusedFill();
  final fixture = await IsolatedDesktopFixture.start(focusedFillDriver: driver);
  final owner = fixture.service.owner;
  final boundary = GlobalKey();
  Process? receiver, cli;
  StreamIterator<String>? receiverLines, cliLines;
  final drains = <Future<String>>[];
  var closed = false, failed = false, approvals = 0;
  var assertionsPassed = false;
  var duplicateVerified = false,
      attentionBlocked = false,
      attentionAcknowledged = false,
      revoked = false,
      revocationBlocked = false,
      historyViewed = false;
  String? requestId, lastOperation;
  FocusedFillApplication? application;
  DateTime? deadline;
  var sequence = 0;
  try {
    var credential = await owner.createStringCredential(
      name: '本机填充合成密码',
      publicPurpose: 'Windows隔离流程',
      secret: secret,
      suggestedBinding: '',
    );
    credential = await owner.updateCredentialMetadata(
      credential.id,
      credential.revision,
      name: credential.name,
      publicPurpose: credential.publicPurpose,
      privateNote: '',
      suggestedBinding: '',
      discoverable: true,
    );
    receiver = await Process.start(receiverPath, []);
    receiverLines = StreamIterator(
      receiver.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    cli = await Process.start(cliPath, ['--port', '${fixture.port}']);
    cliLines = StreamIterator(
      cli.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    for (final process in [receiver, cli]) {
      drains.add(
        process.stderr.transform(utf8.decoder).join().then((value) {
          scan(value);
          return value;
        }),
      );
    }
    Future<Map<String, dynamic>> response(StreamIterator<String> lines) async {
      if (!await lines.moveNext().timeout(const Duration(seconds: 12))) {
        throw StateError('Test child ended');
      }
      scan(lines.current);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    expect((await response(receiverLines))['event'], 'window_ready');
    Future<Map<String, dynamic>> receive(int code, [String? value]) async {
      final units = value?.codeUnits ?? const <int>[];
      final body = Uint8List(1 + units.length * 2)..[0] = code;
      final view = ByteData.sublistView(body);
      for (var i = 0; i < units.length; i++) {
        view.setUint16(1 + i * 2, units[i], Endian.little);
      }
      final length = ByteData(4)..setUint32(0, body.length, Endian.little);
      receiver!.stdin.add(length.buffer.asUint8List());
      receiver.stdin.add(body);
      await receiver.stdin.flush();
      body.fillRange(0, body.length, 0);
      return response(receiverLines!);
    }

    Future<Map<String, dynamic>> call(Map<String, Object?> value) async {
      cli!.stdin.writeln(jsonEncode(value));
      await cli.stdin.flush();
      return response(cliLines!);
    }

    Future<void> click(String key) async {
      await record({
        'phase': 'action_started',
        'step': 'before_click',
        'key': key,
        'flutterSemanticsEnabled': SemanticsBinding.instance.semanticsEnabled,
      });
      final target = find.byKey(ValueKey(key));
      final until = DateTime.now().add(const Duration(seconds: 10));
      while (target.evaluate().isEmpty && DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> capture(String label) async {
      await tester.pumpAndSettle();
      verifyFrameworkErrors();
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${folder.path}/$label.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    }

    await receive(1, secret);
    await call({'command': 'session', 'chatLabel': 'Windows本机填充闭环'});
    final capabilities = await call({'command': 'capabilities'});
    expect(
      capabilities['capabilities'],
      contains('credential-focused-target.v1'),
    );
    if (lockedOnly) {
      final result = await call({'command': 'focus-target'});
      expect(result['targetState'], 'refused');
      expect(result['errorCode'], 'desktop_locked');
      final input = await receive(2);
      expect(input['empty'], isTrue);
      expect(input['noPaste'], isTrue);
      expect(input['clipboardUnchanged'], isTrue);
      expect(owner.focusedFillOperations, isEmpty);
      expect(owner.credentialUseRequests, isEmpty);
      closed = true;
      await record({
        'phase': 'locked_refusal',
        'helper': driver.helper.toJson(),
        'receipt': result,
        'receiver': input,
        'encryptedLibrary': true,
      });
      return;
    }
    await mount(
      RepaintBoundary(
        key: boundary,
        child: InformationApp(
          service: fixture.service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final limit = DateTime.now().add(const Duration(minutes: 4));
    await record({
      'phase': 'ready',
      'helper': driver.helper.toJson(),
      'cli': cliPath,
      'receiver': receiverPath,
      'encryptedLibrary': true,
      'testSemanticsRequested': testSemanticsRequested,
      'harness': harness,
      'flutterSemanticsEnabled': SemanticsBinding.instance.semanticsEnabled,
      'controlDeadline': limit.toUtc().toIso8601String(),
    });
    var seen = -1;
    while (!closed && DateTime.now().isBefore(limit)) {
      Map<String, dynamic>? next;
      try {
        next =
            jsonDecode(await File('${folder.path}/command.json').readAsString())
                as Map<String, dynamic>;
      } on Object {
        /* Await complete task-owned control file. */
      }
      if (next == null || next['id'] is! int || next['id'] == seen) {
        await tester.pump(const Duration(milliseconds: 80));
        continue;
      }
      seen = next['id'] as int;
      await record({
        'phase': 'action_started',
        'id': seen,
        'action': next['action'],
        'flutterSemanticsEnabled': SemanticsBinding.instance.semanticsEnabled,
      });
      try {
        Map<String, Object?> result;
        switch (next['action']) {
          case 'discover':
            final value = await call({'command': 'focus-target'});
            if (value['targetState'] == 'ready') {
              final candidate = FocusedFillTarget.fromJson(value).application!;
              expect(
                candidate.executable.toLowerCase(),
                (await File(receiverPath).resolveSymbolicLinks()).toLowerCase(),
              );
              application = candidate;
            }
            result = value;
          case 'request':
            final value = await call({
              'command': 'request-use',
              'purpose': '核对本机合成密码输入，不连接网络',
              'credentials': [
                {
                  'alias': 'password',
                  'credentialId': credential.id,
                  'version': credential.version,
                },
              ],
              'fill': FocusedFillPlan(application!, '合成本机密码框，非网站登录').toJson(),
            });
            requestId = value['requestId'] as String;
            await tester.pump(const Duration(seconds: 1));
            await capture('approval');
            result = {
              'requestId': requestId,
              'pending':
                  owner.credentialUseState(
                    owner.credentialUseRequests.single,
                  ) ==
                  'pending',
            };
          case 'approve':
            await click('focused-fill-approve');
            await record({
              'phase': 'action_started',
              'id': seen,
              'action': 'approve',
              'step': 'confirmation_open',
              'flutterSemanticsEnabled':
                  SemanticsBinding.instance.semanticsEnabled,
            });
            await capture('confirmation');
            await click('fill-confirm-decision');
            expect(
              owner.credentialUseRequests.single.credentialApproved,
              isTrue,
            );
            expect(owner.focusedFillOperations, isEmpty);
            approvals++;
            deadline = owner.credentialUseRequests.single.credentialExpiresAt;
            result = {
              'approvedByFlutter': true,
              'approvals': approvals,
              'inputOperations': 0,
            };
          case 'fill':
          case 'duplicate':
            if (next['action'] == 'fill') {
              lastOperation = 'native-ui-${++sequence}';
            }
            final use = await call({
              'command': 'fill-use',
              'requestId': requestId,
              'operationId': lastOperation,
            });
            await fixture.service.drainFocusedFills().timeout(
              const Duration(seconds: 15),
            );
            final status = await call({
              'command': 'fill-status',
              'requestId': requestId,
              'operationId': lastOperation,
            });
            final receiverFacts = await receive(2);
            expect(receiverFacts['noPaste'], isTrue);
            expect(receiverFacts['clipboardUnchanged'], isTrue);
            if (status['fillState'] == 'sent') {
              expect(receiverFacts['matches'], isTrue);
              if (next['action'] == 'duplicate') {
                duplicateVerified = true;
              }
            }
            attentionBlocked |= use['errorCode'] == 'fill_needs_attention';
            revocationBlocked |= use['errorCode'] == 'grant_revoked';
            result = {
              'use': use,
              'status': status,
              'receiver': receiverFacts,
              'approvals': approvals,
              'deadlineUnchanged':
                  owner.credentialUseRequests.single.credentialExpiresAt ==
                  deadline,
            };
          case 'clear':
            result = await receive(3);
          case 'arm-change':
            result = await receive(4);
          case 'history':
            await tester.tap(find.byKey(const ValueKey('nav-3')));
            await tester.pumpAndSettle();
            await capture('history-${owner.focusedFillOperations.length}');
            historyViewed = true;
            result = {
              'history': true,
              'operations': owner.focusedFillOperations.length,
            };
          case 'acknowledge':
            await click('fill-acknowledge-attention');
            await capture('attention-confirmation');
            await click('fill-confirm-attention');
            attentionAcknowledged =
                owner.focusedFillOperations.last.attentionAcknowledgedAt !=
                null;
            expect(attentionAcknowledged, isTrue);
            result = {'ownerConfirmedByFlutter': attentionAcknowledged};
          case 'revoke':
            await click('fill-revoke');
            await tester.tap(find.text('确认撤销'));
            await tester.pumpAndSettle();
            expect(
              owner.credentialGrantState(owner.credentialUseRequests.single),
              'revoked',
            );
            revoked = true;
            result = {'revokedByFlutter': true};
          case 'close':
            closed = true;
            result = {'closing': true};
          default:
            throw StateError('Unknown test action');
        }
        await record({
          'phase': 'action',
          'id': seen,
          'action': next['action'],
          'ok': true,
          'flutterSemanticsEnabled': SemanticsBinding.instance.semanticsEnabled,
          ...result,
        });
      } on Object {
        failed = true;
        await record({
          'phase': 'action',
          'id': seen,
          'action': next['action'],
          'ok': false,
          'rawErrorNotRecorded': true,
        });
      }
    }
    expect(
      closed,
      isTrue,
      reason: 'Interactive test must finish explicitly within its bound',
    );
    expect(failed, isFalse);
    expect(approvals, 1);
    expect(duplicateVerified, isTrue);
    expect(attentionBlocked, isTrue);
    expect(attentionAcknowledged, isTrue);
    expect(revoked, isTrue);
    expect(revocationBlocked, isTrue);
    expect(historyViewed, isTrue);
    expect(
      owner.focusedFillOperations
          .where((op) => op.state == FocusedFillState.sent)
          .length,
      greaterThanOrEqualTo(2),
    );
    assertionsPassed = true;
  } finally {
    await mount(const SizedBox());
    for (final process in [cli, receiver]) {
      if (process == null) continue;
      try {
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on Object {
        process.kill();
        await process.exitCode;
      }
    }
    await cliLines?.cancel();
    await receiverLines?.cancel();
    for (final drain in drains) {
      expect(await drain, isEmpty);
    }
    await fixture.bootstrap.runtime!.stop();
    final reopened = await EncryptedInformationRepository.open(
      fixture.root.path,
      WindowsDatabaseKeyStore('${fixture.root.path}/database-key.dpapi'),
    );
    final afterRestart = InformationService(
      repository: reopened,
      focusedFillDriver: driver,
    );
    final facts = <String, Object?>{};
    try {
      final requests = afterRestart.owner.credentialUseRequests;
      facts.addAll({
        'operations': afterRestart.owner.focusedFillOperations.length,
        'requests': requests.length,
        'grantNotRevived': requests.every(
          (r) => afterRestart.owner.credentialGrantState(r) != 'available',
        ),
      });
      expect(facts['grantNotRevived'], isTrue);
    } finally {
      await afterRestart.close();
      await reopened.close();
      await fixture.close();
    }
    await record({
      'phase': 'closed',
      'closed': closed,
      'assertionsPassed': assertionsPassed,
      'failed': failed,
      'reopenedEncryptedFacts': facts,
    });
  }
}
