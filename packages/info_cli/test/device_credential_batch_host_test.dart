@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/chrome_browser_fill.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/credential_batch_protocol.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:test/test.dart';

import '../../../apps/server/test/support/tls_fixture.dart';

void main() {
  late _Fixture f;
  setUp(() async {
    f = await _Fixture.start();
  });
  tearDown(() async {
    await f.close();
  });

  test(
    'browser inspection refusals reach the CLI before any request or material preparation',
    () async {
      final context = File('${f.root.path}/chat/context.json');
      await ChiyoContext(
        chatId: 'synthetic-preflight',
        agentName: 'Synthetic Agent',
        secret: f.session,
        port: f.profile.address.port,
        connection: f.profile,
      ).saveNew(context);
      var caseNumber = 0;
      for (final via in ['ego', 'chrome']) {
        for (final (code, expected, exit) in [
          ('ambiguous_form', 'ambiguous_form', 2),
          ('unavailable_target', 'unavailable_target', 2),
          ('browser_unavailable', 'browser_unavailable', 3),
          ('browser_timeout', 'browser_operation_failed', 2),
          ('RAW_PRIVATE_BROWSER_DETAIL', 'browser_operation_failed', 2),
        ]) {
          f.browser.inspectionError = code;
          final operation = 'preflight-$via-${++caseNumber}';
          final result =
              await ChiyoCli(
                environment: {
                  'CHIYO_CONTEXT': context.path,
                  'CHIYO_CONNECTION_DIRECTORY': f.root.path,
                },
              ).run([
                'fill',
                'request',
                '--credential',
                f.a,
                '--via',
                via,
                if (via == 'ego') ...[
                  '--space',
                  '7',
                  '--page',
                  'p1',
                ] else ...[
                  '--browser',
                  'http://127.0.0.1:9222',
                  '--tab',
                  'synthetic-tab',
                ],
                '--url',
                'https://example.test/login',
                '--form',
                '#login',
                '--selector',
                '#password',
                '--purpose',
                'Inspect synthetic login',
                '--operation',
                operation,
                '--json',
              ]);
          expect((result.output['error'] as Map)['code'], expected);
          expect(result.exitCode, exit, reason: result.render());
          if (code == 'browser_unavailable') {
            expect((result.output['error'] as Map)['message'], contains('浏览器'));
          }
          final data = result.output['data'] as Map;
          expect(data['operationId'], operation);
          expect(data['requestId'], isNull);
          expect(data['status'], isNot('request_unknown'));
          expect(
            result.render(),
            isNot(contains('RAW_PRIVATE_BROWSER_DETAIL')),
          );
        }
      }
      expect(f.browser.inspections, 10);
      expect(f.count('request'), 0);
      expect(f.count('begin'), 0);
      expect(f.count('material'), 0);
      expect(f.service.owner.credentialBatches, isEmpty);
      expect(f.service.owner.credentialBatchOperations, isEmpty);
      expect(await f.journals(), isEmpty);
      expect(f.browser.materials, isEmpty);
      expect(f.browser.fills, 0);
      expect(f.native.sent, 0);
    },
  );

  test(
    'successful history queries retain partial expiry while new execution and waiting still fail',
    () async {
      final id = await f.request(native: true);
      final pending = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'pending-fill',
      ]);
      expect(pending.exitCode, 4);
      expect((pending.output['error'] as Map)['code'], 'request_pending');
      final wait = await f.cli(['requests', 'wait', id, '--timeout', '0']);
      expect(wait.exitCode, 6);
      expect((wait.output['data'] as Map)['status'], 'pending');
      expect(f.count('begin'), 0);
      expect(f.count('material'), 0);
      expect(f.native.sent, 0);

      await f.approve(id, ['b1']);
      f.now = f.now.add(
        AccessTiming.defaultLifetime - const Duration(seconds: 1),
      );
      f.native.afterBatch = () async {
        f.now = f.now.add(const Duration(seconds: 1));
      };
      final started = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'partial-expiry',
      ]);
      expect(started.exitCode, 0, reason: started.render());
      final done = await f.done('partial-expiry');
      expect(done['executionState'], 'partial');
      expect(done['errorCode'], 'grant_expired');
      expect(f.native.sent, 1);
      for (final verb in ['show', 'retry']) {
        final query = await f.cli(['operations', verb, 'partial-expiry']);
        expect(query.exitCode, 0, reason: query.render());
        expect(query.output['ok'], true);
        final data = query.output['data'] as Map;
        expect(data['status'], 'ok');
        expect(data['executionState'], 'partial');
        expect(data['errorCode'], 'grant_expired');
        expect(data['operationId'], 'partial-expiry');
        expect(data['itemResults'], done['itemResults']);
        expect(data['finishedAt'], done['finishedAt']);
      }
      final originalRun = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'partial-expiry',
      ]);
      expect(originalRun.exitCode, 4);
      expect((originalRun.output['data'] as Map)['executionState'], 'partial');
      final expired = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'new-expired-fill',
      ]);
      expect(expired.exitCode, 4, reason: expired.render());
      expect((expired.output['error'] as Map)['code'], 'scope_not_approved');
      expect(f.count('begin'), 1);
      expect(f.count('material'), 1);
      expect(f.native.sent, 1);
      expect(f.service.owner.credentialBatchOperations, hasLength(1));

      f.support = false;
      final unavailable = await f.cli(['operations', 'show', 'partial-expiry']);
      expect(unavailable.exitCode, 3);
      expect(unavailable.output['ok'], false);
      expect(
        (unavailable.output['error'] as Map)['code'],
        'unsupported_capability',
      );
    },
  );

  test(
    'browser unavailability after dispatch remains unknown instead of a capability refusal',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.browser.result = {'status': 'unknown', 'code': 'browser_unavailable'};
      final arguments = [
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'disconnected-fill',
      ];
      expect((await f.cli(arguments)).exitCode, 0);
      final done = await f.done('disconnected-fill');
      expect(done['executionState'], 'unknown');
      expect(done['errorCode'], 'browser_unavailable');
      final execution = await f.cli(arguments);
      expect(execution.exitCode, 7, reason: execution.render());
      final query = await f.cli(['operations', 'show', 'disconnected-fill']);
      expect(query.exitCode, 0, reason: query.render());
      final data = query.output['data'] as Map;
      expect(data['executionState'], 'unknown');
      expect(data['errorCode'], 'browser_unavailable');
      expect(f.browser.fills, 1);
      expect(f.count('material'), 1);
    },
  );

  test(
    'native targets stay in the original private scope and one setter uses the approved snapshot',
    () async {
      final id = await f.backgroundRequest();
      expect(f.background.setters, 0);
      expect(f.native.sent, 0);
      expect(f.browser.inspections, 0);
      final foreign = await f.call({
        'command': 'batch-request',
        'operationId': 'foreign-native',
        'input': f.plan(
          destination: {
            'via': 'native',
            'targetId': f.background.target.targetId,
          },
        ),
      }, session: f.stranger);
      expect(foreign['errorCode'], 'target_unavailable');
      await f.approve(id, ['b1']);
      final args = [
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'native-setter',
      ];
      expect((await f.cli(args)).exitCode, 0);
      final done = await f.done('native-setter');
      expect(done['executionState'], 'filled');
      expect(done['itemResults'], {'b1': 'sent'});
      expect(f.background.received, _Fixture.aSecret);
      expect(f.background.setters, 1);
      expect(f.background.material!.every((b) => b == 0), true);
      expect((await f.cli(args)).exitCode, 0);
      expect(f.background.setters, 1);
      f.background.restart();
      final stale = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'stale-native',
      ]);
      expect(stale.exitCode, 5);
      expect((stale.output['error'] as Map)['code'], 'target_unavailable');
      expect(f.count('begin'), 1);
      expect(f.count('material'), 1);
      expect(f.native.sent, 0);
    },
  );
  test(
    'native authorization is rechecked before the complete setter',
    () async {
      final id = await f.backgroundRequest();
      await f.approve(id, ['b1']);
      f.background.beforeDispatch = () async {
        final request = f.service.owner.credentialBatches.single;
        await f.service.owner.revokeCredentialBatch(
          id,
          operationId: 'revoke-native',
          revision: request.revision,
          itemIds: ['b1'],
        );
      };
      await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'revoked-native',
      ]);
      final done = await f.done('revoked-native');
      expect(done['executionState'], 'refused');
      expect(done['errorCode'], 'grant_revoked');
      expect(f.background.setters, 0);
      expect(f.background.material!.every((b) => b == 0), true);
    },
  );
  test(
    'unknown native setter results cannot be replayed or hidden by a new ID',
    () async {
      final id = await f.backgroundRequest();
      await f.approve(id, ['b1']);
      f.background.result = const NativeFillResult(
        NativeFillState.unknown,
        'access_denied',
      );
      final args = [
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'unknown-native',
      ];
      await f.cli(args);
      expect((await f.done('unknown-native'))['executionState'], 'unknown');
      expect((await f.cli(args)).exitCode, 7);
      final replacement = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'replacement-native',
      ]);
      expect(replacement.exitCode, 7);
      expect(f.background.setters, 1);
      expect(f.count('material'), 1);
    },
  );
  test(
    'native capability is explicit before discovery or request creation',
    () async {
      final unavailable = await f.cli([
        'fill',
        'targets',
        '--via',
        'native',
        '--app',
        'synthetic.native',
      ]);
      expect(unavailable.exitCode, 3);
      expect(f.background.discoveries, 0);
      expect(f.service.owner.credentialBatches, isEmpty);
    },
  );

  test(
    'native operations do not queue a second write to a busy target',
    () async {
      final id = await f.backgroundRequest();
      await f.approve(id, ['b1']);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      f.background.beforeDispatch = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'busy-native-first',
      ]);
      await entered.future;
      final busy = await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'busy-native-second',
      ]);
      expect((busy.output['error'] as Map)['code'], 'busy');
      expect(f.background.setters, 0);
      release.complete();
      expect((await f.done('busy-native-first'))['itemResults'], {
        'b1': 'sent',
      });
      expect(f.background.setters, 1);
    },
  );

  test('a v1-only service cannot enable v2 discovery or submit', () async {
    f.backgroundSupport = true;
    f.nativeCapability = 'credential-native-fill.v1';
    final capabilities = await f.call({'command': 'capabilities'});
    expect(
      capabilities['capabilities'],
      isNot(contains('credential-native-fill.v2')),
    );
    expect(capabilities['providers'], isNot(contains('native')));
    final discovered = await f.cli([
      'fill',
      'targets',
      '--via',
      'native',
      '--app',
      'synthetic.native',
    ]);
    expect(discovered.exitCode, 3);
    final submitted = await f.call({
      'command': 'batch-request',
      'operationId': 'v1-only-submit',
      'input': f.plan(
        destination: {
          'via': 'native',
          'targetId': f.background.target.targetId,
        },
      ),
    });
    expect(submitted['errorCode'], 'unsupported_capability');
    expect(f.background.discoveries, 0);
    expect(f.count('request'), 0);
    expect(f.service.owner.credentialBatches, isEmpty);
  });

  test(
    'new native discovery and request reject legacy driver snapshots',
    () async {
      f.backgroundSupport = true;
      f.background.target = NativeFillTarget.fromJson({
        ...f.background.target.toJson(),
        'controlKind': 'appkit_secure_text',
      });
      final discovered = await f.cli([
        'fill',
        'targets',
        '--via',
        'native',
        '--app',
        'synthetic.native',
      ]);
      expect(discovered.exitCode, 3);
      final submitted = await f.call({
        'command': 'batch-request',
        'operationId': 'legacy-driver-submit',
        'input': f.plan(
          destination: {
            'via': 'native',
            'targetId': f.background.target.targetId,
          },
        ),
      });
      expect(submitted['errorCode'], 'unsupported_capability');
      expect(f.count('request'), 0);
      expect(f.background.setters, 0);
    },
  );

  test(
    'a legacy approval cannot be rebound to a v2 control with the same IDs',
    () async {
      await f.backgroundRequest();
      final request = await f.service.agent.requestCredentialBatch(
        f.session,
        'A' * 22,
        CredentialBatchInput.fromJson({
          'protocolVersion': 3,
          ...f.plan(
            destination: {
              'via': 'native',
              'target': {
                ...f.background.target.toJson(),
                'controlKind': 'appkit_secure_text',
              },
            },
          ),
        }),
        operationId: 'legacy-approved-submit',
      );
      await f.approve(request.id, ['b1']);
      final result = await f.cli([
        'fill',
        'run',
        '--request',
        request.id,
        '--operation',
        'legacy-approved-fill',
      ]);
      expect(result.exitCode, 5, reason: result.render());
      expect((result.output['error'] as Map)['code'], 'destination_changed');
      expect((result.output['error'] as Map)['message'], contains('原来的输入框已失效'));
      expect(f.count('material'), 0);
      expect(f.background.setters, 0);
    },
  );
  test(
    'mixed plans retain native setter acceptance when a later explicit destination refuses',
    () async {
      f.backgroundSupport = true;
      await f.cli([
        'fill',
        'targets',
        '--via',
        'native',
        '--app',
        'synthetic.native',
      ]);
      final input = f.plan();
      (input['items'] as List).first['destination'] = {
        'via': 'native',
        'targetId': f.background.target.targetId,
      };
      final submitted = await f.call({
        'command': 'batch-request',
        'operationId': 'mixed-native-submit',
        'input': input,
      });
      final id = submitted['requestId'] as String;
      await f.approve(id, ['b1', 'b2']);
      f.browser.result = {'status': 'refused', 'code': 'value_not_retained'};
      await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'partial-native',
      ]);
      final done = await f.done('partial-native');
      expect(done['executionState'], 'partial');
      expect(done['itemResults'], {'b1': 'sent', 'b2': 'refused'});
      expect(f.background.setters, 1);
      expect(f.native.sent, 0);
    },
  );
  test(
    'only resident Host shutdown disposes an owned native driver and repeat close is idempotent',
    () async {
      final id = await f.backgroundRequest();
      await f.approve(id, ['b1']);
      final entered = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      f.background.beforeDispatch = () async {
        entered.complete();
        await release.future;
      };
      await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'resident-native',
      ]);
      await entered.future;
      expect(f.background.disposals, 0);
      expect(f.background.refs, isNotEmpty);
      final observation = await f.cli([
        'operations',
        'show',
        'resident-native',
      ]);
      expect(observation.exitCode, 0);
      expect(f.background.disposals, 0);
      release.complete();
      expect((await f.done('resident-native'))['itemResults'], {'b1': 'sent'});
      await Future.wait([f.host.close(), f.host.close()]);
      expect(f.background.disposals, 1);
      expect(f.background.refs, isEmpty);
    },
  );
  test(
    'a borrowed native driver remains the caller responsibility after Host shutdown',
    () async {
      await f.close();
      f = await _Fixture.start(ownsNativeDriver: false);
      await f.backgroundRequest();
      await f.host.close();
      expect(f.background.disposals, 0);
      expect(f.background.refs, isNotEmpty);
      await f.background.dispose();
      expect(f.background.disposals, 1);
      expect(f.background.refs, isEmpty);
    },
  );
  test(
    'resident shutdown closes a pending native helper read before waiting for the operation',
    () async {
      final id = await f.backgroundRequest();
      await f.approve(id, ['b1']);
      f.background.setterEntered = Completer<void>();
      f.background.pendingSetter = Completer<NativeFillResult>();
      addTearDown(() {
        if (!f.background.pendingSetter!.isCompleted) {
          f.background.pendingSetter!.complete(
            const NativeFillResult(NativeFillState.unknown, 'fill_unknown'),
          );
        }
      });
      await f.cli([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'pending-native-helper',
      ]);
      await f.background.setterEntered!.future;
      await f.host.close().timeout(const Duration(seconds: 3));
      expect(f.background.disposals, 1);
      expect(f.background.refs, isEmpty);
      expect(f.background.pendingSetter!.isCompleted, true);
    },
  );
  test(
    'one private request contains multiple inspected destinations and does not execute on approval',
    () async {
      final id = await f.request();
      expect(f.service.owner.credentialBatches, hasLength(1));
      expect(f.browser.inspections, 2);
      await f.approve(id, ['b1', 'b2']);
      expect(f.browser.fills, 0);
      final claim = await f.run(id, 'fill-1');
      expect(claim['executionState'], 'checking');
      expect(jsonEncode(claim), isNot(contains('privateProof')));
      final done = await f.done('fill-1');
      expect(done['executionState'], 'filled');
      expect(done['itemResults'], {'b1': 'filled', 'b2': 'filled'});
      expect(f.browser.received, [_Fixture.aSecret, _Fixture.bSecret]);
      expect(
        f.browser.materials.every((bytes) => bytes.every((b) => b == 0)),
        true,
      );
      final serialized = jsonEncode(await f.journals());
      for (final forbidden in [
        f.session,
        _Fixture.aSecret,
        _Fixture.bSecret,
        'privateProof',
        'ownerToken',
      ]) {
        expect(serialized, isNot(contains(forbidden)));
      }
      final repeated = await f.run(id, 'fill-1');
      expect(repeated['executionState'], 'filled');
      expect(f.browser.fills, 2);
    },
  );
  test(
    'partial approval can execute only the selected item, without a second request',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1']);
      expect((await f.run(id, 'all'))['errorCode'], 'scope_not_approved');
      expect(f.count('material'), 0);
      await f.run(id, 'only-a', ids: ['b1']);
      expect((await f.done('only-a'))['executionState'], 'filled');
      expect(f.browser.received, [_Fixture.aSecret]);
      expect(f.service.owner.credentialBatches, hasLength(1));
    },
  );
  test(
    'a lost request reply recovers the original request without inspecting a new target',
    () async {
      f.dropRequest = true;
      final first = await f.call({
        'command': 'batch-request',
        'operationId': 'lost-submit',
        'input': f.plan(),
      });
      expect(first['status'], 'service_unavailable');
      expect(f.browser.inspections, 2);
      f.browser.digest = 'b' * 64;
      final recovered = await f.call({
        'command': 'batch-request',
        'operationId': 'lost-submit',
        'input': f.plan(),
      });
      expect(
        recovered['requestId'],
        f.service.owner.credentialBatches.single.id,
      );
      expect(f.count('request'), 2);
      expect(f.browser.inspections, 2);
    },
  );
  test(
    'the journal freezes an unreceived request and scopes identical public IDs by private chat',
    () async {
      f.skipRequest = true;
      await f.call({
        'command': 'batch-request',
        'operationId': 'frozen',
        'input': f.plan(),
      });
      expect(f.service.owner.credentialBatches, isEmpty);
      f.skipRequest = false;
      f.browser.digest = 'b' * 64;
      final recovered = await f.call({
        'command': 'batch-request',
        'operationId': 'frozen',
        'input': f.plan(),
      });
      expect(recovered['status'], 'pending');
      expect(f.browser.inspections, 2);
      expect(
        f
            .service
            .owner
            .credentialBatches
            .single
            .items
            .first
            .destination
            .browser!
            .structureDigest,
        'a' * 64,
      );
      final changed = f.plan()..['purpose'] = 'Different intent';
      expect(
        (await f.call({
          'command': 'batch-request',
          'operationId': 'frozen',
          'input': changed,
        }))['errorCode'],
        'operation_conflict',
      );
      final stranger = await f.call({
        'command': 'batch-request',
        'operationId': 'frozen',
        'input': f.plan(),
      }, session: f.stranger);
      expect(stranger['status'], 'pending');
      expect(f.service.owner.credentialBatches, hasLength(2));
    },
  );
  test(
    'recovering a known server request still verifies its frozen submission digest',
    () async {
      f.skipRequest = true;
      final command = {
        'command': 'batch-request',
        'operationId': 'shared-op',
        'input': f.plan(),
      };
      await f.call(command);
      f.skipRequest = false;
      final frozen =
          (await f.journals()).single['prepared'] as Map<String, dynamic>;
      await f.service.agent.requestCredentialBatch(
        f.session,
        'A' * 22,
        CredentialBatchInput.fromJson({
          ...frozen,
          'purpose': 'Other original content',
        }),
        operationId: 'shared-op',
      );
      final count = f.browser.inspections;
      expect((await f.call(command))['errorCode'], 'operation_conflict');
      expect(f.browser.inspections, count);
      expect(f.service.owner.credentialBatches, hasLength(1));
    },
  );
  test('all targets must still match before material is claimed', () async {
    final id = await f.request();
    await f.approve(id, ['b1', 'b2']);
    f.browser.digest = 'b' * 64;
    expect((await f.run(id, 'changed'))['errorCode'], 'destination_changed');
    expect(f.count('begin'), 0);
    expect(f.count('material'), 0);
    expect(f.browser.fills, 0);
  });
  test(
    'a lost begin reply never obtains another proof or writes input, including after Host restart',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.dropBegin = true;
      expect((await f.run(id, 'lost-begin'))['executionState'], 'unknown');
      expect(f.count('begin'), 1);
      expect(f.count('material'), 0);
      await f.host.close();
      await f.restart();
      expect((await f.run(id, 'lost-begin'))['executionState'], 'checking');
      expect(f.count('begin'), 1);
      expect(f.browser.fills, 0);
      f.now = f.now.add(const Duration(seconds: 31));
      expect(
        (await f.call({
          'command': 'batch-status',
          'operationId': 'lost-begin',
        }))['executionState'],
        'unknown',
      );
      expect((await f.run(id, 'new-id'))['errorCode'], 'fill_needs_attention');
    },
  );
  test(
    'calling socket disconnection does not cancel a run already accepted by the App',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      final entered = Completer<void>(), release = Completer<void>();
      f.afterBegin = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final record = (await readPrivateDeviceState(
        File('${f.root.path}/credential-batch-host/endpoint.json'),
      ))!;
      final http = HttpClient();
      final request = await http.postUrl(
        Uri.parse('http://127.0.0.1:${record['port']}/execute'),
      );
      final fields = {
        ...f.profile.toPrivateJson(),
        'certificate': f.profile.certificate.trim(),
      };
      final sorted = {
        for (final key in fields.keys.toList()..sort()) key: fields[key],
      };
      request.headers.contentType = ContentType.json;
      request.headers.set(
        'authorization',
        'Bearer ${record['controlCapability']}',
      );
      request.write(
        jsonEncode({
          'profileHash': sha256
              .convert(utf8.encode(jsonEncode(sorted)))
              .toString(),
          'serverId': f.profile.serverId,
          'sessionSecret': f.session,
          'input': {
            'command': 'batch-run',
            'requestId': id,
            'operationId': 'detached',
          },
        }),
      );
      final response = request.close().then<void>((r) async {
        await r.drain<void>();
      }, onError: (Object _) {});
      await entered.future;
      http.close(force: true);
      await response;
      release.complete();
      expect((await f.done('detached'))['executionState'], 'filled');
      expect(f.count('begin'), 1);
      expect(f.browser.fills, 2);
    },
  );
  test(
    'a known server operation can be queried after losing only the local journal, without target inspection',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      await f.run(id, 'existing', ids: ['b1']);
      await f.done('existing');
      final inspected = f.browser.inspections;
      await for (final file in Directory(
        '${f.root.path}/credential-batch-host/journal',
      ).list()) {
        if (file is File) await file.delete();
      }
      f.browser.digest = 'b' * 64;
      expect(
        (await f.run(id, 'existing', ids: ['b1']))['executionState'],
        'filled',
      );
      expect(f.browser.inspections, inspected);
      expect(f.browser.fills, 1);
      expect(
        (await f.run(id, 'existing', ids: ['b2']))['errorCode'],
        'operation_conflict',
      );
    },
  );
  test(
    'concurrent identical submissions and runs share one durable operation',
    () async {
      final submitted = await Future.wait([f.request(), f.request()]);
      expect(submitted.first, submitted.last);
      expect(f.count('request'), 2);
      expect(f.browser.inspections, 2);
      await f.approve(submitted.first, ['b1', 'b2']);
      await Future.wait([
        f.run(submitted.first, 'concurrent'),
        f.run(submitted.first, 'concurrent'),
      ]);
      expect((await f.done('concurrent'))['executionState'], 'filled');
      expect(f.count('begin'), 1);
      expect(f.browser.fills, 2);
    },
  );
  test(
    'a lost finish reply queries the original completed result without sending again',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.dropFinish = true;
      await f.run(id, 'lost-finish');
      expect((await f.done('lost-finish'))['executionState'], 'filled');
      await f.run(id, 'lost-finish');
      expect(f.browser.fills, 2);
      expect(f.count('finish'), 1);
    },
  );
  test(
    'browser unknown normalizes transport errors and cannot replay with either operation ID',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.browser.result = {'status': 'unknown', 'code': 'browser_timeout'};
      await f.run(id, 'unknown');
      final done = await f.done('unknown');
      expect(done['executionState'], 'unknown');
      expect(done['errorCode'], 'browser_operation_failed');
      await f.run(id, 'unknown');
      expect(f.browser.fills, 1);
      expect(
        (await f.run(id, 'replacement'))['errorCode'],
        'fill_needs_attention',
      );
      expect(f.browser.fills, 1);
    },
  );
  test(
    'an exception while a browser write is in flight is unknown and does not expose its message',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.browser.beforeFill = () async {
        throw StateError(_Fixture.aSecret);
      };
      await f.run(id, 'throw');
      final done = await f.done('throw');
      expect(done['executionState'], 'unknown');
      expect((done['itemResults'] as Map)['b1'], 'unknown');
      expect(jsonEncode(done), isNot(contains(_Fixture.aSecret)));
    },
  );
  test(
    'switching the active App connection during authorize stops dispatch',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.afterAuthorize = () async {
        await f.publish(
          AgentConnectionProfile.local(
            port: f.server.port,
            deviceToken: '${'C' * 22}.${'D' * 43}',
            libraryId: f.profile.serverId,
          ),
        );
      };
      await f.run(id, 'switch');
      expect((await f.doneDirect('switch'))['executionState'], 'failed');
      expect(f.browser.fills, 0);
      expect(
        (await f.call({
          'command': 'batch-status',
          'operationId': 'switch',
        }))['errorCode'],
        'session_mismatch',
      );
    },
  );
  test(
    'native input authorizes every batch and stops after revocation',
    () async {
      final id = await f.request(native: true);
      await f.approve(id, ['b1']);
      f.native.afterBatch = () async {
        final current = f.service.owner.credentialBatches.single;
        await f.service.owner.revokeCredentialBatch(
          id,
          operationId: 'revoke',
          revision: current.revision,
          itemIds: ['b1'],
        );
      };
      await f.run(id, 'native', ids: ['b1']);
      final done = await f.done('native');
      expect(done['executionState'], 'partial');
      expect(f.native.sent, 1);
      expect(f.count('authorize'), 2);
      expect(f.native.closed, true);
      expect(f.native.batch!.every((b) => b == 0), true);
    },
  );
  test(
    'changing libraries during browser checks is refused by the final dispatch guard',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      f.browser.beforeFill = () async {
        await f.publish(
          AgentConnectionProfile.local(
            port: f.server.port,
            deviceToken: '${'C' * 22}.${'D' * 43}',
            libraryId: 'other-library-id',
          ),
        );
      };
      await f.run(id, 'late-switch');
      expect((await f.doneDirect('late-switch'))['executionState'], 'refused');
      expect(f.browser.fills, 0);
      expect(f.count('authorize'), 0);
    },
  );
  test('revocation during browser checks refuses the final setter', () async {
    final id = await f.request();
    await f.approve(id, ['b1', 'b2']);
    f.browser.beforeFill = () async {
      final r = f.service.owner.credentialBatches.single;
      await f.service.owner.revokeCredentialBatch(
        id,
        operationId: 'late-revoke',
        revision: r.revision,
        itemIds: ['b1'],
      );
    };
    await f.run(id, 'late-revoke');
    expect((await f.done('late-revoke'))['executionState'], 'failed');
    expect(f.browser.fills, 0);
    expect(f.browser.materials.every((v) => v.every((b) => b == 0)), true);
  });
  test(
    'closing the App during browser checks prevents final dispatch and leaves an uncertain audit',
    () async {
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      final closing = Completer<Future<void>>();
      f.browser.beforeFill = () async {
        closing.complete(f.host.close());
      };
      await f.run(id, 'late-close');
      await (await closing.future);
      expect(f.browser.fills, 0);
      expect(f.browser.materials.every((v) => v.every((b) => b == 0)), true);
      f.now = f.now.add(const Duration(seconds: 31));
      expect((await f.doneDirect('late-close'))['executionState'], 'unknown');
    },
  );
  test(
    'raw secrets, prepared targets, owner identities and arbitrary executables are rejected',
    () async {
      for (final payload in [
        {
          'command': 'batch-run',
          'operationId': 'bad',
          'requestId': 'id',
          'ownerToken': 'NO',
        },
        {
          'command': 'batch-request',
          'operationId': 'bad',
          'input': {...f.plan(), 'password': _Fixture.aSecret},
        },
        {
          'command': 'batch-request',
          'operationId': 'bad',
          'input': f.plan(
            destination: {
              'via': 'focus',
              'application': f.native.application.toJson(),
            },
          ),
        },
        {
          'command': 'batch-request',
          'operationId': 'bad',
          'input': f.plan(
            destination: {
              'via': 'ego',
              'target': {'field': '#password'},
            },
          ),
        },
        {
          'command': 'batch-request',
          'operationId': 'bad',
          'input': f.plan(
            destination: {'via': 'focus', 'executable': 'C:/any.exe'},
          ),
        },
      ]) {
        final result = await f.call(payload);
        expect(result['status'], isNot('ok'));
        expect(jsonEncode(result), isNot(contains(_Fixture.aSecret)));
      }
      expect(f.count('request'), 0);
      expect(f.native.sent, 0);
      expect(f.browser.fills, 0);
    },
  );
  test(
    'old service capability is refused without journal writes or target inspection',
    () async {
      f.support = false;
      expect(
        (await f.call({
          'command': 'batch-request',
          'operationId': 'old',
          'input': f.plan(),
        }))['errorCode'],
        'unsupported_capability',
      );
      expect(await f.journals(), isEmpty);
      expect(f.browser.inspections, 0);
    },
  );
  test(
    'real private loopback authentication rejects missing capability and Origin',
    () async {
      final record = (await readPrivateDeviceState(
        File('${f.root.path}/credential-batch-host/endpoint.json'),
      ))!;
      final http = HttpClient();
      try {
        for (final auth in [false, true]) {
          final request = await http.postUrl(
            Uri.parse('http://127.0.0.1:${record['port']}/execute'),
          );
          request.headers.contentType = ContentType.json;
          if (auth) {
            request.headers.set(
              'authorization',
              'Bearer ${record['controlCapability']}',
            );
            request.headers.set('origin', 'https://synthetic.invalid');
          }
          request.write('{}');
          final response = await request.close();
          final result = jsonDecode(await utf8.decoder.bind(response).join());
          expect(result['errorCode'], 'service_unavailable');
        }
      } finally {
        http.close(force: true);
      }
      expect(f.paths, isEmpty);
    },
  );
  test(
    'HTTPS remote configuration uses the same original profile and bound server',
    () async {
      await f.close();
      f = await _Fixture.start(remote: true);
      final id = await f.request();
      await f.approve(id, ['b1', 'b2']);
      await f.run(id, 'remote');
      expect((await f.done('remote'))['executionState'], 'filled');
      expect(f.paths.every((p) => p.startsWith('/v1/agent/')), true);
      expect(f.browser.fills, 2);
    },
  );
}

class _Browser implements DeviceCredentialBatchBrowser {
  int inspections = 0, fills = 0;
  String? inspectionError;
  String digest = 'a' * 64;
  final received = <String>[], materials = <List<int>>[];
  Map<String, Object?> result = {'status': 'filled'};
  Future<void> Function()? beforeFill;
  @override
  Future<BrowserFormInspection> inspect(Map<String, dynamic> locator) async {
    inspections++;
    if (inspectionError case final code?) throw BrowserFillFailure(code);
    final ego = locator['via'] == 'ego';
    final target = BrowserFormTarget.fromJson({
      'provider': locator['via'],
      'instanceId': 'synthetic-browser',
      'pageId': locator[ego ? 'page' : 'tab'],
      'url': locator['url'],
      'form': locator['form'],
      'field': locator['selector'],
      'structureDigest': digest,
      if (ego)
        'space': locator['space']
      else
        'browserAddress': locator['browser'],
    });
    return BrowserFormInspection(target, {});
  }

  @override
  Future<Map<String, Object?>> fill(
    BrowserFormTarget target,
    List<int> material, {
    required Future<void> Function() beforeDispatch,
  }) async {
    materials.add(material);
    await beforeFill?.call();
    try {
      await beforeDispatch();
    } on Object catch (error) {
      return {'status': 'refused', 'code': browserDispatchError(error)};
    }
    fills++;
    received.add(utf8.decode(material));
    return result;
  }
}

class _Native implements FocusedFillDiscoveryDriver {
  final application = FocusedFillApplication.fromJson({
    'executable': 'C:/synthetic/app.exe',
    'sha256': 'a' * 64,
  });
  int sent = 0;
  bool closed = false;
  List<int>? batch;
  Future<void> Function()? afterBatch;
  @override
  Future<FocusedFillTarget> inspectTarget() async =>
      FocusedFillTarget.ready(application);
  @override
  Future<PreparedFocusedFill> prepare(FocusedFillApplication expected) async {
    closed = false;
    return _Prepared(this);
  }
}

class _Background implements NativeFillDriver {
  NativeFillTarget target = _target('H');
  final refs = <(String, String), NativeFillTarget>{};
  int discoveries = 0, setters = 0, disposals = 0;
  bool disposed = false;
  String? received;
  List<int>? material;
  Future<void> Function()? beforeDispatch;
  Completer<void>? setterEntered;
  Completer<NativeFillResult>? pendingSetter;
  NativeFillResult result = const NativeFillResult(NativeFillState.sent);
  static NativeFillTarget _target(String epoch) => NativeFillTarget.fromJson({
    'targetId': 'N' * 32,
    'helperInstanceId': epoch * 32,
    'platform': 'macos',
    'application': {
      'executable': '/Applications/Synthetic.app/Contents/MacOS/Synthetic',
      'sha256': 'a' * 64,
    },
    'appId': 'synthetic.native',
    'appName': 'Synthetic Native',
    'windowId': 'W' * 32,
    'windowTitle': 'Synthetic login',
    'fieldLabel': 'Password',
    'controlKind': 'macos_ax_password',
  });
  void restart() {
    refs.clear();
    target = _target('J');
  }

  @override
  Future<List<NativeFillTarget>> discover({
    required String scope,
    required String appId,
    String? windowId,
  }) async {
    discoveries++;
    if (appId != target.appId ||
        windowId != null && windowId != target.windowId) {
      return [];
    }
    refs[(scope, target.targetId)] = target;
    return [target];
  }

  @override
  Future<PreparedNativeFill> prepare({
    required String scope,
    required String targetId,
    NativeFillTarget? expected,
  }) async {
    final found = refs[(scope, targetId)];
    if (found == null) throw const CredentialUseFailure('target_unavailable');
    if (expected != null && !expected.matches(found)) {
      throw const CredentialUseFailure('destination_changed');
    }
    return _BackgroundPrepared(this, found);
  }

  @override
  Future<void> release({
    required String scope,
    required String targetId,
  }) async {
    refs.remove((scope, targetId));
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    disposals++;
    refs.clear();
    if (pendingSetter != null && !pendingSetter!.isCompleted) {
      pendingSetter!.complete(
        const NativeFillResult(NativeFillState.unknown, 'fill_unknown'),
      );
    }
  }
}

class _BackgroundPrepared implements PreparedNativeFill {
  _BackgroundPrepared(this.driver, this.target);
  final _Background driver;
  @override
  final NativeFillTarget target;
  bool closed = false;
  @override
  Future<NativeFillResult> setValue(
    List<int> utf8Bytes, {
    required Future<void> Function() beforeDispatch,
  }) async {
    driver.material = utf8Bytes;
    if (closed) {
      return const NativeFillResult(
        NativeFillState.refused,
        'target_unavailable',
      );
    }
    await driver.beforeDispatch?.call();
    await beforeDispatch();
    if (!driver.target.matches(target)) {
      return const NativeFillResult(
        NativeFillState.refused,
        'destination_changed',
      );
    }
    driver.setters++;
    driver.received = utf8.decode(utf8Bytes);
    driver.setterEntered?.complete();
    return driver.pendingSetter?.future ?? driver.result;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _Prepared implements PreparedFocusedFill {
  _Prepared(this.driver);
  final _Native driver;
  @override
  FocusedFillApplication get application => driver.application;
  @override
  Future<FocusedFillBatchResult> sendBatch(List<int> units) async {
    driver.sent++;
    driver.batch = units;
    await driver.afterBatch?.call();
    return const FocusedFillBatchResult(FocusedFillState.sent);
  }

  @override
  Future<void> close() async {
    driver.closed = true;
  }
}

class _Fixture {
  static const aSecret = 'SYNTHETIC-A-示例-123456789012345678901234567890';
  static const bSecret = 'SYNTHETIC-B-😊';
  late Directory root;
  late InformationService service;
  late HttpServer server;
  late AgentConnectionProfile profile;
  late DeviceCredentialBatchHost host;
  late String session, stranger, a, b;
  DateTime now = DateTime.utc(2026, 11, 13);
  final browser = _Browser(), native = _Native();
  final background = _Background();
  bool backgroundSupport = false;
  String nativeCapability = 'credential-native-fill.v2';
  bool ownsNativeDriver = true;
  final paths = <String>[];
  final counts = <String, int>{};
  bool support = true,
      dropRequest = false,
      skipRequest = false,
      dropBegin = false,
      dropFinish = false,
      _closed = false;
  Future<void> Function()? afterAuthorize;
  Future<void> Function()? afterBegin;
  static Future<_Fixture> start({
    bool remote = false,
    bool ownsNativeDriver = true,
  }) async {
    final f = _Fixture()..ownsNativeDriver = ownsNativeDriver;
    final base = Directory('../../build/batch-host-tests').absolute;
    await base.create(recursive: true);
    f.root = await Directory(
      await base.resolveSymbolicLinks(),
    ).createTemp('App 合成 ');
    f.service = InformationService(
      repository: MemoryInformationRepository(),
      clock: () => f.now,
    );
    f.session = f.service.agent.openSession('same public chat');
    f.stranger = f.service.agent.openSession('same public chat');
    Future<String> credential(String name, String secret) async {
      final c = await f.service.owner.createStringCredential(
        name: name,
        publicPurpose: 'Synthetic',
        secret: secret,
      );
      await f.service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: name,
        publicPurpose: 'Synthetic',
        privateNote: '',
        suggestedBinding: 'password',
        discoverable: true,
      );
      return c.id;
    }

    f.a = await credential('A', aSecret);
    f.b = await credential('B', bSecret);
    String certificate = '';
    if (remote) {
      final tls = await createTlsFixture(f.root);
      f.server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(tls.certificate)
          ..usePrivateKey(tls.privateKey),
      );
      certificate = await File(tls.ca).readAsString();
    } else {
      f.server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    const token =
        'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
    f.profile = remote
        ? AgentConnectionProfile(
            address: Uri.parse('https://127.0.0.1:${f.server.port}'),
            deviceToken: token,
            serverId: 'synthetic-library-id',
            certificate: certificate,
          )
        : AgentConnectionProfile.local(
            port: f.server.port,
            deviceToken: token,
            libraryId: 'synthetic-library-id',
          );
    f.server.listen(f._respond);
    await f.publish(f.profile);
    await f.restart();
    return f;
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      paths.add(request.uri.path);
      request.response.headers.set('x-chiyo-server-id', profile.serverId);
      request.response.headers.contentType = ContentType.json;
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final path = profile.isLocal
          ? request.uri.path
          : request.uri.path.replaceFirst('/v1/agent', '');
      final action = path.split('/').last;
      counts[action] = (counts[action] ?? 0) + 1;
      if (request.headers.value('authorization') !=
              'Bearer ${profile.deviceToken}' ||
          request.headers.value('x-chiyo-server-id') != profile.serverId) {
        throw const CredentialUseFailure('session_mismatch');
      }
      Map<String, Object?> result;
      if (path == '/capabilities') {
        result = {
          'status': 'ok',
          'capabilities': [
            if (support) ...[
              'credential-batches.v3',
              'agent-record-queries.v1',
              if (backgroundSupport) nativeCapability,
            ],
          ],
        };
      } else if (path == '/session/check') {
        result = {
          'status': {session, stranger}.contains(body['sessionSecret'])
              ? 'ok'
              : 'unauthorized',
        };
      } else if (path == '/operations/show') {
        result = service.agent.showOwnOperation(
          body['sessionSecret'] as String,
          body['id'] as String,
        );
      } else if (path == '/requests/show') {
        result = service.agent.showOwnRequest(
          body['sessionSecret'] as String,
          body['id'] as String,
        );
      } else {
        if (skipRequest && action == 'request') {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        result = await CredentialBatchProtocol(
          service.agent,
          'A' * 22,
        ).dispatch(path, body);
        if (action == 'authorize') await afterAuthorize?.call();
        if (action == 'begin') await afterBegin?.call();
        if (action == 'request' && dropRequest ||
            action == 'begin' && dropBegin ||
            action == 'finish' && dropFinish) {
          dropRequest = false;
          dropBegin = false;
          dropFinish = false;
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
      }
      request.response.write(jsonEncode(result));
    } on CredentialUseFailure catch (e) {
      request.response.write(jsonEncode(e.toJson(protocolVersion: 3)));
    } catch (_) {
      request.response.write(jsonEncode({'status': 'service_unavailable'}));
    }
    try {
      await request.response.close();
    } catch (_) {}
  }

  Future<void> restart() async {
    host = await DeviceCredentialBatchHost.start(
      directory: root,
      driver: native,
      nativeDriver: background,
      ownsNativeDriver: ownsNativeDriver,
      browser: browser,
    );
  }

  Future<void> publish(AgentConnectionProfile value) =>
      AutomaticConnectionStore(root.path).publish({'mode': 'synthetic'}, value);
  Map<String, dynamic> plan({Map<String, dynamic>? destination}) => {
    'purpose': 'Synthetic login',
    'agentName': 'Synthetic Agent',
    'externalChatId': 'same-public-chat',
    'submissionVersion': 1,
    'items': [
      {
        'credentialId': a,
        'destination':
            destination ??
            {
              'via': 'ego',
              'space': 7,
              'page': 'p1',
              'url': 'https://example.test/login',
              'form': '#login',
              'selector': '#password',
            },
      },
      if (destination == null)
        {
          'credentialId': b,
          'destination': {
            'via': 'chrome',
            'browser': 'http://127.0.0.1:9222',
            'tab': 'synthetic-tab',
            'url': 'https://example.test/login',
            'form': '#other',
            'selector': '#password',
          },
        },
    ],
  };
  Future<Map<String, dynamic>> call(
    Map<String, dynamic> input, {
    String? session,
  }) => DeviceCredentialBatchClient(
    profile,
    directory: root,
  ).execute(session ?? this.session, input);
  Future<ChiyoRunResult> cli(List<String> arguments) async {
    final context = File('${root.path}/chat/context.json');
    if (!await context.exists()) {
      await ChiyoContext(
        chatId: 'synthetic-history',
        agentName: 'Synthetic Agent',
        secret: session,
        port: profile.address.port,
        connection: profile,
      ).saveNew(context);
    }
    return ChiyoCli(
      environment: {
        'CHIYO_CONTEXT': context.path,
        'CHIYO_CONNECTION_DIRECTORY': root.path,
      },
    ).run([...arguments, '--json']);
  }

  Future<String> request({bool native = false}) async {
    final result = await call({
      'command': 'batch-request',
      'operationId': 'submit',
      'input': plan(destination: native ? {'via': 'focus'} : null),
    });
    expect(result['status'], 'pending', reason: '$result');
    return result['requestId'] as String;
  }

  Future<String> backgroundRequest() async {
    backgroundSupport = true;
    final discovered = await cli([
      'fill',
      'targets',
      '--via',
      'native',
      '--app',
      'synthetic.native',
    ]);
    expect(discovered.exitCode, 0, reason: discovered.render());
    final found =
        ((discovered.output['data'] as Map)['targets'] as List).single as Map;
    expect(found['fieldLabel'], 'Password');
    for (final key in [
      'value',
      'bytes',
      'scope',
      'leaseId',
      'processId',
      'hwnd',
    ]) {
      expect(found.containsKey(key), false);
    }
    final submitted = await cli([
      'fill',
      'request',
      '--via',
      'native',
      '--target',
      found['targetId'] as String,
      '--credential',
      a,
      '--purpose',
      'Synthetic native login',
      '--operation',
      'submit-native',
    ]);
    expect(submitted.exitCode, 0, reason: submitted.render());
    return (submitted.output['data'] as Map)['requestId'] as String;
  }

  Future<void> approve(String id, List<String> ids) async {
    await service.owner.decideCredentialBatch(
      id,
      operationId: 'approve',
      revision: 1,
      approvedItems: ids,
    );
  }

  Future<Map<String, dynamic>> run(
    String id,
    String operation, {
    List<String>? ids,
  }) => call({
    'command': 'batch-run',
    'requestId': id,
    'operationId': operation,
    'itemIds': ?ids,
  });
  Future<Map<String, dynamic>> done(String operation) =>
      _until(() => call({'command': 'batch-status', 'operationId': operation}));
  Future<Map<String, dynamic>> doneDirect(String operation) => _until(
    () async => Map<String, dynamic>.from(
      service.agent.credentialBatchOperationStatus(
        session,
        'A' * 22,
        operation,
      ),
    ),
  );
  Future<Map<String, dynamic>> _until(
    Future<Map<String, dynamic>> Function() query,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      final result = await query();
      if ({
        'filled',
        'partial',
        'unknown',
        'failed',
        'refused',
      }.contains(result['executionState'])) {
        return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('Synthetic operation did not finish');
  }

  int count(String action) => counts[action] ?? 0;
  Future<List<Map<String, dynamic>>> journals() async => [
    await for (final file in Directory(
      '${root.path}/credential-batch-host/journal',
    ).list())
      if (file is File) (await readPrivateDeviceState(file))!,
  ];
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await host.close();
    await server.close(force: true);
    await service.close();
    final base = await Directory(
      '../../build/batch-host-tests',
    ).resolveSymbolicLinks();
    if (!(await root.resolveSymbolicLinks()).startsWith(
      '$base${Platform.pathSeparator}',
    )) {
      throw StateError('Fixture escaped build root');
    }
    await root.delete(recursive: true);
  }
}
