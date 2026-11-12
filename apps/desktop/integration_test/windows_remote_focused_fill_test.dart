// Interactive Windows acceptance: real runner/bundled broker, isolated HTTPS
// server/SQLCipher/DPAPI, production App host, and an owned Win32 receiver.
// The desktop platform fixture avoids OS notifications and process termination;
// StorageDesktopLauncher still owns and closes the actual private fill host.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/bundled_focused_fill.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_source.dart';
import 'package:integration_test/integration_test.dart';

import '../../../packages/info_cli/test/support/windows_password_receiver.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../test/support/desktop_platform_fixture.dart';
import '../test/support/online_ui_harness.dart';
import 'support/native_semantics_lifetime.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows HTTPS approval fills through the running App host',
    (tester) async {
      const receiverPath = String.fromEnvironment('FILL_RECEIVER');
      const evidence = String.fromEnvironment('FILL_EVIDENCE');
      expect(receiverPath, isNotEmpty);
      expect(evidence, isNotEmpty);
      final semantics = NativeSemanticsLifetime(tester);
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _LocalHttp();
      final ui = OnlineUiHarness(tester);
      final secret =
          '  Win32-${base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256)))}-中文🧭  ';
      final folder = Directory(evidence);
      await ui.resolve(() => folder.create(recursive: true));
      void scan(String text) {
        // Real I/O callbacks can complete while OnlineUiHarness pumps the
        // UI. A guarded Flutter expect() here would conflict with pump().
        if (text.contains(secret) ||
            text.contains(
              jsonEncode(secret).substring(1, jsonEncode(secret).length - 1),
            )) {
          throw StateError('Synthetic value escaped public results');
        }
      }

      Future<void> record(Map<String, Object?> value) => ui.resolve(() async {
        final text = jsonEncode(value);
        scan(text);
        await File('$evidence/state.json').writeAsString(text, flush: true);
        await File(
          '$evidence/events.jsonl',
        ).writeAsString('$text\n', mode: FileMode.append, flush: true);
      });

      final server = await ui.resolve(DeviceCredentialFixture.create);
      final root = Directory('${server.root.path}/desktop-private');
      final store = PrivateConnectionProfileStore(root.path);
      WindowsPasswordReceiver? receiver;
      AgentClient? client;
      try {
        await ui.resolve(
          () => AutomaticConnectionStore(root.path).publish(
            ConnectionProfile(
              address: server.owner.address.toString(),
              token: server.token,
              serverId: server.owner.serverId,
              certificate: server.certificate,
            ).toJson(),
            server.profiles.first,
          ),
        );
        final driver = await ui.resolve(loadBundledFocusedFill);
        final nativeReceiver = await ui.resolve(
          () => WindowsPasswordReceiver.start(receiverPath, secret),
        );
        receiver = nativeReceiver;
        final chat = await ui.resolve(
          () => server.agents.first.call('/session/lifecycle', {
            'chatLabel': 'Synthetic Windows remote fill',
          }),
        );
        final session = chat['sessionSecret'] as String;
        final active = client = AgentClient.remote(
          server.profiles.first,
          sessionSecret: session,
          focusedFillHostDirectory: root,
        );
        Future<Map<String, dynamic>> call(Map<String, Object?> input) =>
            ui.resolve(() async {
              final result = await active.execute({
                'protocolVersion': 2,
                ...input,
              });
              scan(jsonEncode(result));
              return result;
            });
        expect(
          (await call({'command': 'capabilities'}))['capabilities'],
          isNot(contains('credential-focused-fill.v1')),
        );
        final credential = await ui.resolve(
          () => server.runtime.run(() async {
            final c = await server.runtime.service.owner.createStringCredential(
              name: 'Synthetic Windows remote fill',
              publicPurpose: '',
              secret: secret,
            );
            return server.runtime.service.owner.updateCredentialMetadata(
              c.id,
              c.revision,
              name: c.name,
              publicPurpose: '',
              privateNote: '',
              suggestedBinding: '',
              discoverable: true,
            );
          }),
        );
        final platform = NativeDesktopFixture();
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: store,
            platform: platform,
            focusedFillDriver: driver,
            localBuilder: (_) => const SizedBox(),
          ),
        );
        await ui.resolve(() async {
          for (var i = 0; i < 100; i++) {
            final support = await active.execute({'command': 'capabilities'});
            if ((support['capabilities'] as List? ?? []).contains(
              'credential-focused-fill.v1',
            )) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          fail('App-owned host did not publish its capability');
        });
        // A different device profile cannot reuse this App endpoint even with
        // the original session proof. No input has been requested yet.
        final wrong = AgentClient.remote(
          server.profiles[1],
          sessionSecret: session,
          focusedFillHostDirectory: root,
        );
        try {
          final denied = await ui.resolve(
            () => wrong.execute({'command': 'focus-target'}),
          );
          expect(denied['status'], 'service_unavailable');
          expect(denied.containsKey('application'), isFalse);
          expect((await ui.resolve(nativeReceiver.verify))['empty'], isTrue);
        } finally {
          wrong.close();
        }
        await record({
          'phase': 'awaiting_focus',
          'hostReady': true,
          'wrongProfileBlocked': true,
        });

        String? request, operation;
        FocusedFillApplication? application;
        var seen = -1,
            sequence = 0,
            finished = false,
            sent = false,
            plainRefused = false,
            attention = false,
            quit = false;
        final deadline = DateTime.now().add(const Duration(minutes: 12));
        Future<Map<String, dynamic>> settle(String id) => ui.resolve(() async {
          final until = DateTime.now().add(const Duration(seconds: 10));
          while (true) {
            final result = await active.execute({
              'protocolVersion': 2,
              'command': 'fill-status',
              'requestId': request,
              'operationId': id,
            });
            scan(jsonEncode(result));
            if (result['fillState'] != 'checking') return result;
            if (DateTime.now().isAfter(until)) {
              fail('Remote fill did not settle');
            }
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        });
        while (!finished && DateTime.now().isBefore(deadline)) {
          final input = await ui.resolve(() async {
            final file = File('$evidence/command.json');
            if (!await file.exists()) return null;
            try {
              return jsonDecode(await file.readAsString())
                  as Map<String, dynamic>;
            } on FormatException {
              return null;
            }
          });
          if (input == null || input['id'] is! int || input['id'] == seen) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 70)),
            );
            await tester.pump();
            continue;
          }
          seen = input['id'] as int;
          final action = input['action'];
          Map<String, Object?> result;
          switch (action) {
            case 'probe':
              final target = await call({'command': 'focus-target'});
              if (target['targetState'] == 'ready') {
                application = FocusedFillTarget.fromJson(target).application;
                expect(
                  application!.executable.toLowerCase(),
                  (await ui.resolve(
                    () => File(receiverPath).resolveSymbolicLinks(),
                  )).toLowerCase(),
                );
              }
              result = target;
            case 'request':
              final pending = await call({
                'command': 'request-use',
                'purpose': 'Synthetic Windows remote password',
                'credentials': [
                  {
                    'alias': 'password',
                    'credentialId': credential.id,
                    'version': credential.version,
                  },
                ],
                'fill': FocusedFillPlan(
                  application!,
                  'Owned Win32 synthetic receiver',
                ).toJson(),
              });
              expect(pending['status'], 'pending', reason: '$pending');
              request = pending['requestId'] as String;
              final denied = await call({
                'command': 'fill-use',
                'requestId': request,
                'operationId': 'unapproved',
              });
              expect(denied['errorCode'], 'request_pending');
              expect(
                (await ui.resolve(nativeReceiver.verify))['empty'],
                isTrue,
              );
              result = {'pending': true, 'unapprovedBlocked': true};
            case 'approve':
              await ui.resolve(() async {
                final detail = approvalDetailFromJson(
                  await server.owner.request(
                    'GET',
                    '/v1/owner/approvals/details/$request',
                  ),
                );
                await server.owner.request(
                  'POST',
                  '/v1/owner/approvals/decisions',
                  approvalChangeToJson(
                    WorkspaceApprovalChange(
                      operationId: 'windows-remote-approve',
                      requestId: request!,
                      reviewToken: detail.reviewToken,
                      action: WorkspaceApprovalAction.approve,
                      selected: detail.scopes.map((s) => s.id),
                      credentialMinutes: 15,
                    ),
                  ),
                );
              });
              result = {'approvedOverHttps': true};
            case 'fill':
            case 'duplicate':
              if (action == 'fill') operation = 'windows-remote-${++sequence}';
              final accepted = await call({
                'command': 'fill-use',
                'requestId': request,
                'operationId': operation,
              });
              final status = await settle(operation!);
              final checked = await ui.resolve(nativeReceiver.verify);
              if (status['fillState'] == 'sent') {
                expect(checked['matches'], isTrue);
                expect(checked['noPaste'], isTrue);
                expect(checked['clipboardUnchanged'], isTrue);
                sent = true;
              }
              if (status['fillState'] == 'refused') {
                expect(checked['empty'], isTrue);
                plainRefused = true;
              }
              if ({'partial', 'unknown'}.contains(status['fillState'])) {
                expect(checked['focusChanged'], isTrue);
                expect(checked['plainEmpty'], isTrue);
                attention = true;
              }
              if (action == 'duplicate') expect(accepted['duplicate'], isTrue);
              result = {
                'receipt': accepted,
                'status': status,
                'receiver': checked,
              };
            case 'attention-block':
              final blocked = await call({
                'command': 'fill-use',
                'requestId': request,
                'operationId': 'not-a-retry',
              });
              expect(blocked['errorCode'], 'fill_needs_attention');
              result = blocked;
            case 'clear':
              await ui.resolve(nativeReceiver.clear);
              result = await ui.resolve(nativeReceiver.verify);
            case 'arm-change':
              await ui.resolve(nativeReceiver.armFocusChange);
              result = {'armed': true};
            case 'quit':
              await ui.until(() => platform.events != null);
              await ui.resolve(() => platform.events!(DesktopEvent.quit));
              expect(platform.terminated, isTrue);
              final endpoint = await ui.resolve(
                () => readPrivateDeviceState(
                  File('${root.path}/focused-fill-host/endpoint.json'),
                ),
              );
              expect(endpoint!['phase'], 'closed');
              expect(
                (await call({'command': 'capabilities'}))['capabilities'],
                isNot(contains('credential-focused-fill.v1')),
              );
              final denied = await call({
                'command': 'fill-use',
                'requestId': request,
                'operationId': 'after-app-quit',
              });
              expect(denied['status'], 'service_unavailable');
              quit = true;
              result = {'hostClosed': true, 'newInputBlocked': true};
            case 'finish':
              expect(sent, isTrue);
              expect(plainRefused, isTrue);
              expect(attention, isTrue);
              expect(quit, isTrue);
              result = {'accepted': true};
              finished = true;
            default:
              fail('Unknown operator action');
          }
          await record({'id': seen, 'action': action, 'result': result});
        }
        expect(finished, isTrue, reason: 'Operator acceptance did not finish');
        final history = await ui.resolve(
          () => server.owner.request(
            'GET',
            '/v1/owner/credentials/${credential.id}/history',
          ),
        );
        scan(jsonEncode(history));
        await record({
          'phase': 'passed',
          'secretAbsentFromPublicResults': true,
        });
      } finally {
        client?.close();
        await tester.pumpWidget(const SizedBox());
        await ui.resolve(() => receiver?.close() ?? Future<void>.value());
        await ui.resolve(server.dispose);
        HttpOverrides.global = previousHttp;
        semantics.finishAfterUnmount();
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 15)),
    semanticsEnabled: false,
  );
}
