import 'dart:convert';
import 'dart:io';
import 'package:info_cli/chiyo_cli.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/browser_fill_types.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:test/test.dart';
import 'support/device_credential_fixture.dart';

class _Browser implements DeviceCredentialBatchBrowser {
  int fills = 0;
  String? received;
  @override
  Future<BrowserFormInspection> inspect(Map<String, dynamic> l) async =>
      BrowserFormInspection(
        BrowserFormTarget.fromJson({
          'provider': 'chrome',
          'instanceId': 'synthetic-browser',
          'pageId': l['tab'],
          'browserAddress': l['browser'],
          'url': l['url'],
          'form': l['form'],
          'field': l['selector'],
          'structureDigest': 'a' * 64,
        }),
        {},
      );
  @override
  Future<Map<String, Object?>> fill(
    BrowserFormTarget t,
    List<int> bytes, {
    required Future<void> Function() beforeDispatch,
  }) async {
    await beforeDispatch();
    fills++;
    received = utf8.decode(bytes);
    return {'status': 'filled'};
  }
}

class _DeniedFocus implements FocusedFillDiscoveryDriver {
  int inspections = 0, prepares = 0;
  @override
  Future<FocusedFillTarget> inspectTarget() async {
    inspections++;
    throw const CredentialUseFailure('access_denied');
  }

  @override
  Future<PreparedFocusedFill> prepare(
    FocusedFillApplication application,
  ) async {
    prepares++;
    throw StateError('Permission refusal cannot prepare an input target');
  }
}

void main() {
  test(
    'native permission refusal gives an actionable capability error without creating an approval or input',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final directory = Directory('${f.root.path}/app-private');
      await AutomaticConnectionStore(
        directory.path,
      ).publish({'mode': 'server'}, f.profiles.first);
      final driver = _DeniedFocus();
      final host = await DeviceCredentialBatchHost.start(
        directory: directory,
        driver: driver,
      );
      addTearDown(host.close);
      final chat = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic permission refusal',
      });
      final file = File('${f.root.path}/cli-chat/context.json');
      await ChiyoContext(
        chatId: 'permission-trial',
        agentName: 'Trial Agent',
        secret: chat['sessionSecret'] as String,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
      ).saveNew(file);
      final result =
          await ChiyoCli(
            environment: {
              'CHIYO_CONTEXT': file.path,
              'CHIYO_CONNECTION_DIRECTORY': directory.path,
            },
          ).run([
            'fill',
            'request',
            '--credential',
            'synthetic-not-delivered',
            '--via',
            'focus',
            '--purpose',
            'Verify permission refusal',
            '--operation',
            'permission-refused',
            '--json',
          ]);
      expect(result.exitCode, 3, reason: result.render());
      final error = result.output['error'] as Map;
      expect(error['code'], 'access_denied');
      expect(error['message'], contains('设置 → 凭据填写'));
      expect(error['message'], isNot(contains('参数')));
      expect(
        (result.output['data'] as Map)['operationId'],
        'permission-refused',
      );
      expect(driver.inspections, 1);
      expect(driver.prepares, 0);
      expect(f.runtime.service.owner.credentialBatches, isEmpty);
      expect(f.repo.credentialBatchOperations, isEmpty);
    },
  );
  test(
    'public fill flags, normal HTTPS App approval and private App execution share one real operation',
    () async {
      final f = await DeviceCredentialFixture.create();
      addTearDown(f.dispose);
      final directory = Directory('${f.root.path}/app-private');
      await AutomaticConnectionStore(
        directory.path,
      ).publish({'mode': 'server'}, f.profiles.first);
      final browser = _Browser();
      final host = await DeviceCredentialBatchHost.start(
        directory: directory,
        browser: browser,
      );
      addTearDown(host.close);
      final opened = await f.agents.first.call('/session/lifecycle', {
        'chatLabel': 'Synthetic public fill',
      });
      final context = ChiyoContext(
        chatId: 'synthetic-public-fill',
        agentName: 'Trial Agent',
        secret: opened['sessionSecret'] as String,
        port: f.profiles.first.address.port,
        connection: f.profiles.first,
      );
      final file = File('${f.root.path}/cli-chat/context.json');
      await context.saveNew(file);
      const password = 'SYNTHETIC-CLI-PRIVATE-中文';
      final c = await f.runtime.run(() async {
        final c = await f.runtime.service.owner.createStringCredential(
          name: 'Synthetic service password',
          publicPurpose: '',
          secret: password,
        );
        return f.runtime.service.owner.updateCredentialMetadata(
          c.id,
          c.revision,
          name: c.name,
          publicPurpose: '',
          privateNote: '',
          suggestedBinding: 'password',
          discoverable: true,
        );
      });
      final env = {
        'CHIYO_CONTEXT': file.path,
        'CHIYO_CONNECTION_DIRECTORY': directory.path,
      };
      Future<ChiyoRunResult> call(List<String> args) =>
          ChiyoCli(environment: env).run([...args, '--json']);
      final command = [
        'fill',
        'request',
        '--credential',
        c.id,
        '--via',
        'chrome',
        '--browser',
        'http://127.0.0.1:9222',
        '--tab',
        'synthetic-tab',
        '--url',
        'https://synthetic.test/login',
        '--form',
        '#login',
        '--selector',
        '#password',
        '--purpose',
        'Sign into the synthetic service',
        '--operation',
        'submit-fill',
      ];
      final health = await call(['doctor']);
      expect(health.exitCode, 0);
      final fill = (health.output['data'] as Map)['fill'] as Map;
      expect(fill['supported'], true);
      expect(fill['appAvailable'], true);
      expect((fill['chrome'] as Map)['targetReady'], null);
      expect(browser.fills, 0);
      expect(f.runtime.service.owner.credentialBatches, isEmpty);
      final requested = await call(command);
      expect(requested.exitCode, 0, reason: requested.render());
      final id = (requested.output['data'] as Map)['requestId'] as String;
      expect(browser.fills, 0);
      final review = approvalDetailFromJson(
        await f.owner.request(
          'GET',
          '/v1/owner/approvals/details/${Uri.encodeComponent(id)}',
        ),
      );
      expect(review.credentialBatch, true);
      final change = WorkspaceApprovalChange(
        operationId: 'approve-public-fill',
        requestId: id,
        reviewToken: review.reviewToken,
        action: WorkspaceApprovalAction.approve,
        selected: ['b1'],
      );
      await f.owner.request(
        'POST',
        '/v1/owner/approvals/decisions',
        approvalChangeToJson(change),
      );
      expect(browser.fills, 0);
      final run = await call([
        'fill',
        'run',
        '--request',
        id,
        '--operation',
        'public-fill-1',
      ]);
      expect(run.exitCode, 0, reason: run.render());
      ChiyoRunResult result = run;
      for (var i = 0; i < 100; i++) {
        result = await call(['operations', 'show', 'public-fill-1']);
        if ((result.output['data'] as Map?)?['executionState'] == 'filled')
          break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        (result.output['data'] as Map)['executionState'],
        'filled',
        reason: result.render(),
      );
      expect(browser.fills, 1);
      expect(browser.received, password);
      final originalExpiry = f
          .runtime
          .service
          .owner
          .credentialBatches
          .single
          .items
          .single
          .expiresAt;
      expect((await call(['operations', 'retry', 'submit-fill'])).exitCode, 0);
      final retry = await call(['operations', 'retry', 'public-fill-1']);
      expect(retry.exitCode, 0);
      expect((retry.output['data'] as Map)['executionState'], 'filled');
      expect(browser.fills, 1);
      expect(f.runtime.service.owner.credentialBatches, hasLength(1));
      expect(f.runtime.service.owner.credentialBatchOperations, hasLength(1));
      expect(
        f.runtime.service.owner.credentialBatches.single.items.single.expiresAt,
        originalExpiry,
      );
      for (final response in [requested, run, result, retry]) {
        expect(response.render(), isNot(contains(password)));
        expect(response.render(), isNot(contains(context.secret)));
        expect(response.render(), isNot(contains('privateProof')));
      }
      final invalid = await ChiyoCli(
        environment: env,
        input: Stream.value(
          utf8.encode(
            jsonEncode({
              'purpose': 'Invalid extra material',
              'items': [
                {
                  'credentialId': c.id,
                  'secret': 'DO-NOT-ECHO-THIS',
                  'destination': {'via': 'focus'},
                },
              ],
            }),
          ),
        ),
      ).run(['fill', 'request', '--input', '-', '--json']);
      expect(invalid.exitCode, 2);
      expect(invalid.render(), isNot(contains('DO-NOT-ECHO-THIS')));
      expect(f.runtime.service.owner.credentialBatches, hasLength(1));
    },
  );
}
