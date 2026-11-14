@TestOn('windows || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:info_cli/agent_client.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/device_credential_host.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/agent_server.dart';
import 'package:info_core/info_core.dart';
import 'package:info_remote/agent_connection.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:test/test.dart';

import 'support/device_credential_fixture.dart';

void main() {
  final fixturePath = Platform.environment['CHIYO_SSH_TEST_DIRECTORY'];
  final port = int.tryParse(Platform.environment['CHIYO_SSH_TEST_PORT'] ?? '');
  final bin = Platform.environment['CHIYO_SSH_TEST_BIN'];
  for (final remote in [false, true]) {
    test(
      'real CLI keeps one remote Shell with ordinary input and approved sudo in ${remote ? 'server' : 'local'} library mode',
      () async {
        final root = await Directory.systemTemp.createTemp('ssh-cli-');
        DeviceCredentialFixture? online;
        AgentServer? local;
        InformationService? memory;
        late AgentConnectionProfile profile;
        late InformationService service;
        Future<T> owner<T>(Future<T> Function(OwnerAccess) action) async =>
            remote
            ? online!.runtime.run(() => action(online!.runtime.service.owner))
            : action(service.owner);
        if (remote) {
          online = await DeviceCredentialFixture.create();
          profile = online.profiles.first;
          service = online.runtime.service;
        } else {
          memory = service = InformationService(
            repository: MemoryInformationRepository(),
          );
          const token =
              'AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
          local = await AgentServer.start(
            service.agent,
            port: 0,
            enableCredentialBatches: true,
            connectionToken: token,
            libraryId: 'synthetic-ssh-library',
          );
          profile = AgentConnectionProfile.local(
            port: local.port,
            deviceToken: token,
            libraryId: 'synthetic-ssh-library',
          );
        }
        final client = AgentClient.remote(profile);
        final opened = await client.openLifecycleSession('Synthetic SSH CLI');
        expect(opened['status'], 'ok');
        final context = File('${root.path}/chat/context.json');
        await ChiyoContext(
          chatId: 'ssh-cli-test',
          agentName: 'Synthetic Agent',
          secret: client.sessionSecret!,
          port: profile.address.port,
          connection: profile,
        ).saveNew(context);
        final state = Directory('${context.parent.path}/device-files');
        addTearDown(() async {
          final host = DeviceCredentialHost(profile, state);
          final journals = Directory('${context.parent.path}/ssh-sessions');
          if (await journals.exists()) {
            await for (final file in journals.list()) {
              if (file is! File || !file.path.endsWith('.json')) continue;
              final record = await readPrivateDeviceState(file);
              if (record == null) continue;
              if (record['sessionId'] is String) {
                await host.execute(client.sessionSecret!, {
                  'command': 'ssh-close',
                  'sessionId': record['sessionId'],
                  'force': true,
                });
              }
            }
          }
          await host.stopIfIdle();
          client.close();
          await local?.close();
          await memory?.close();
          await online?.dispose();
          await root.delete(recursive: true);
        });
        final public = (await File(
          '$fixturePath/host.pub',
        ).readAsString()).split(' ').take(2).join(' ');
        await owner(
          (o) => o.configureSshKnownHosts(
            'Synthetic SSH only',
            utf8.encode('[127.0.0.1]:$port $public\n'),
          ),
        );
        Future<String> credential(String name, String secret) =>
            owner((o) async {
              final c = await o.createStringCredential(
                name: name,
                publicPurpose: 'Synthetic only',
                secret: secret,
              );
              await o.updateCredentialMetadata(
                c.id,
                c.revision,
                name: name,
                publicPurpose: 'Synthetic only',
                privateNote: '',
                suggestedBinding: '',
                discoverable: true,
              );
              return c.id;
            });
        final login = await credential('Login', 'synthetic-login-only');
        final sudo = await credential('Sudo', 'synthetic-sudo-only');
        Future<Map<String, dynamic>> cli(
          List<String> args, {
          int exit = 0,
        }) async {
          final result = await Process.run(
            '$bin/chiyo${Platform.isWindows ? '.exe' : ''}',
            [...args, '--json'],
            environment: {
              'CHIYO_CONTEXT': context.path,
              'CHIYO_CHAT_ID': 'ssh-cli-test',
            },
            includeParentEnvironment: true,
          );
          expect(
            result.exitCode,
            exit,
            reason: '${result.stdout}\n${result.stderr}',
          );
          final value =
              jsonDecode(result.stdout as String) as Map<String, dynamic>;
          expect(
            '${result.stdout}${result.stderr}',
            isNot(contains('synthetic-login-only')),
          );
          expect(
            '${result.stdout}${result.stderr}',
            isNot(contains('synthetic-sudo-only')),
          );
          return Map<String, dynamic>.from(value['data'] as Map);
        }

        Future<void> approve(String id, String operation) async {
          if (remote) {
            final detail = approvalDetailFromJson(
              await online!.owner.request(
                'GET',
                '/v1/owner/approvals/details/$id',
              ),
            );
            expect(detail.sshSession, isTrue);
            await online!.owner.request(
              'POST',
              '/v1/owner/approvals/decisions',
              approvalChangeToJson(
                WorkspaceApprovalChange(
                  operationId: operation,
                  requestId: id,
                  reviewToken: detail.reviewToken,
                  action: WorkspaceApprovalAction.approve,
                  selected: detail.scopes.map((s) => s.id),
                  credentialMinutes: null,
                ),
              ),
            );
          } else {
            final request = service.owner.credentialBatches.singleWhere(
              (r) => r.id == id,
            );
            await service.owner.decideCredentialBatch(
              id,
              operationId: operation,
              revision: request.revision,
              approvedItems: request.items.map((i) => i.id),
              lifetime: null,
            );
          }
        }

        Future<Map<String, dynamic>> until(
          String id,
          bool Function(Map<String, dynamic>) done,
        ) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (true) {
            final value = await cli(['ssh', 'status', '--session', id]);
            if (done(value)) return value;
            if (DateTime.now().isAfter(deadline))
              fail('SSH state did not settle: $value');
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        }

        final requested = await cli([
          'ssh',
          'request',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
          '--user',
          'fixture',
          '--auth',
          'password',
          '--credential',
          login,
          '--purpose',
          'Test continuous SSH',
          '--operation',
          'request-login',
        ]);
        final requestId = requested['requestId'] as String;
        await approve(requestId, 'approve-login');
        final connection = await cli([
          'ssh',
          'open',
          '--request',
          requestId,
          '--operation',
          'open-one',
        ]);
        expect(connection['status'], 'ready');
        final id = connection['sessionId'] as String;
        addTearDown(() async {
          await cli(['ssh', 'close', '--session', id, '--force']);
        });
        final running = await cli([
          'ssh',
          'run',
          '--session',
          id,
          '--operation',
          'run-one',
          '--command',
          r'cd /tmp; export CHIYO_TEST=kept; read -r x </dev/tty; printf "reply=%s\\n" "$x"; sudo -k /usr/bin/id -u',
        ]);
        expect(running['status'], 'accepted');
        expect(
          (await cli([
            'ssh',
            'input',
            '--session',
            id,
            '--run',
            'run-one',
            '--text',
            'yes',
            '--enter',
            '--operation',
            'input-one',
          ]))['status'],
          'accepted',
        );
        final awaiting = await until(
          id,
          (v) => (v['run'] as Map?)?['credentialReceiver'] != null,
        );
        final action =
            ((awaiting['run'] as Map)['credentialReceiver'] as Map)['actionId']
                as String;
        final sudoRequest = await cli([
          'ssh',
          'credential',
          'request',
          '--session',
          id,
          '--run',
          'run-one',
          '--action',
          action,
          '--credential',
          sudo,
          '--purpose',
          'Test managed sudo',
          '--operation',
          'sudo-request',
        ]);
        await approve(sudoRequest['requestId'] as String, 'approve-sudo');
        expect(
          (await cli([
            'ssh',
            'credential',
            'use',
            '--session',
            id,
            '--run',
            'run-one',
            '--action',
            action,
            '--request',
            sudoRequest['requestId'] as String,
            '--operation',
            'sudo-use',
          ]))['status'],
          'delivered',
        );
        final exited = await until(id, (v) => v['sessionState'] == 'ready');
        expect(exited['sessionState'], 'ready');
        final output = await cli([
          'ssh',
          'output',
          '--session',
          id,
          '--run',
          'run-one',
        ]);
        expect('${output['output']}', contains('reply=yes'));
        expect((output['run'] as Map)['exitCode'], 0);
        await cli([
          'ssh',
          'run',
          '--session',
          id,
          '--operation',
          'run-two',
          '--command',
          r'printf "%s:%s\\n" "$PWD" "$CHIYO_TEST"; read -r x </dev/tty; printf "next=%s\\n" "$x"',
        ]);
        await cli([
          'ssh',
          'input',
          '--session',
          id,
          '--run',
          'run-one',
          '--text',
          'STALE',
          '--enter',
          '--operation',
          'stale',
        ], exit: 8);
        await cli([
          'ssh',
          'input',
          '--session',
          id,
          '--run',
          'run-two',
          '--text',
          'fresh',
          '--enter',
          '--operation',
          'input-two',
        ]);
        await until(id, (v) => v['sessionState'] == 'ready');
        final second = await cli([
          'ssh',
          'output',
          '--session',
          id,
          '--run',
          'run-two',
        ]);
        expect('${second['output']}', contains('/tmp:kept'));
        expect('${second['output']}', contains('next=fresh'));
        expect('${second['output']}', isNot(contains('STALE')));
        await cli([
          'ssh',
          'run',
          '--session',
          id,
          '--operation',
          'run-revoke',
          '--command',
          'read -r x </dev/tty; printf should-not-continue',
        ]);
        await owner((o) {
          final r = o.credentialBatches.singleWhere((r) => r.id == requestId);
          return o.revokeCredentialBatch(
            requestId,
            operationId: 'revoke-login',
            revision: r.revision,
            itemIds: r.items.map((i) => i.id),
          );
        });
        await cli([
          'ssh',
          'input',
          '--session',
          id,
          '--run',
          'run-revoke',
          '--text',
          'no',
          '--enter',
          '--operation',
          'revoked-input',
        ], exit: 4);
        await cli(['ssh', 'interrupt', '--session', id, '--run', 'run-revoke']);
        await until(id, (v) => {'closed', 'lost'}.contains(v['sessionState']));
        final operations = await owner(
          (o) async => o.credentialBatchOperations,
        );
        expect(
          operations
              .where((o) => o.sshContext?.kind == 'input')
              .every((o) => !o.materialClaimed),
          isTrue,
        );
        expect(
          operations
              .where((o) => o.sshContext?.kind == 'run')
              .every((o) => !o.materialClaimed),
          isTrue,
        );
      },
      skip: fixturePath == null || port == null || bin == null
          ? 'Requires explicitly started synthetic SSH fixture and compiled sibling CLI/worker/helper.'
          : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
