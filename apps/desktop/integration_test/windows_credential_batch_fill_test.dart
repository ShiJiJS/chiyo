// Real Windows runner and build-bound helper, real encrypted HTTPS fixture,
// production App host and compiled public chiyo. Only synthetic data is used.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/device_credential_batch_host.dart';
import 'package:info_cli/installed_ego_browser.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/bundled_focused_fill.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:integration_test/integration_test.dart';
import '../../../packages/info_cli/test/support/windows_password_receiver.dart';
import '../../server/test/support/device_credential_fixture.dart';
import '../test/support/desktop_platform_fixture.dart';
import '../test/support/online_ui_harness.dart';
import 'support/native_semantics_lifetime.dart';
import 'support/synthetic_chrome.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'public batch CLI reaches the real App host and Chrome Ego Win32 receivers',
    (tester) async {
      const evidence = String.fromEnvironment('BATCH_EVIDENCE');
      const cli = String.fromEnvironment('BATCH_CLI');
      const chromeExecutable = String.fromEnvironment('BATCH_CHROME');
      const receiverExecutable = String.fromEnvironment('BATCH_RECEIVER');
      const space = int.fromEnvironment('BATCH_EGO_SPACE');
      const page = String.fromEnvironment('BATCH_EGO_PAGE');
      expect(
        [
          evidence,
          cli,
          chromeExecutable,
          receiverExecutable,
          page,
        ].every((v) => v.isNotEmpty),
        true,
      );
      expect(space, greaterThan(0));
      final ui = OnlineUiHarness(tester),
          semantics = NativeSemanticsLifetime(tester);
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _LocalHttp();
      final root = Directory(evidence);
      await ui.resolve(() => root.create(recursive: true));
      final secrets = {
        for (final provider in ['chrome', 'ego', 'focus'])
          provider:
              '  BATCH-$provider-${base64Url.encode(List.generate(24, (_) => Random.secure().nextInt(256)))}-中文🧭  ',
      };
      void scan(String text) {
        if (secrets.values.any(
          (s) =>
              text.contains(s) ||
              text.contains(
                jsonEncode(s).substring(1, jsonEncode(s).length - 1),
              ),
        )) {
          throw StateError('Synthetic material escaped public output');
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
      final appDirectory = Directory('${server.root.path}/isolated-app');
      HttpServer? form;
      SyntheticChrome? chrome;
      WindowsPasswordReceiver? receiver;
      try {
        await ui.resolve(
          () => AutomaticConnectionStore(appDirectory.path).publish(
            ConnectionProfile(
              address: server.owner.address.toString(),
              token: server.token,
              serverId: server.owner.serverId,
              certificate: server.certificate,
            ).toJson(),
            server.profiles.first,
          ),
        );
        final opened = await ui.resolve(
          () => server.agents.first.call('/session/lifecycle', {
            'chatLabel': 'Synthetic Windows public batch integration',
          }),
        );
        final context = ChiyoContext(
          chatId: 'synthetic-windows-batch',
          agentName: 'Synthetic Agent',
          secret: opened['sessionSecret'] as String,
          port: server.profiles.first.address.port,
          connection: server.profiles.first,
        );
        final contextFile = File('${server.root.path}/chat/context.json');
        await ui.resolve(() => context.saveNew(contextFile));
        final credentials = <String, String>{};
        for (final entry in secrets.entries) {
          credentials[entry.key] = await ui.resolve(
            () => server.runtime.run(() async {
              final c = await server.runtime.service.owner
                  .createStringCredential(
                    name: 'Synthetic ${entry.key}',
                    publicPurpose: 'Integration only',
                    secret: entry.value,
                  );
              await server.runtime.service.owner.updateCredentialMetadata(
                c.id,
                c.revision,
                name: c.name,
                publicPurpose: c.publicPurpose,
                privateNote: '',
                suggestedBinding: 'password',
                discoverable: true,
              );
              return c.id;
            }),
          );
        }
        final driver = await ui.resolve(loadBundledFocusedFill);
        final platform = NativeDesktopFixture();
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(appDirectory.path),
            platform: platform,
            focusedFillDriver: driver,
            localBuilder: (_) => const SizedBox(),
          ),
        );
        await ui.until(() => platform.events != null);
        await ui.resolve(() async {
          for (var i = 0; i < 100; i++) {
            final result = await DeviceCredentialBatchClient(
              server.profiles.first,
              directory: appDirectory,
            ).execute(context.secret, {'command': 'capabilities'});
            if (result['status'] == 'ok') return;
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          throw StateError('Production App batch host did not start');
        });
        final cleanEnvironment = Map<String, String>.from(Platform.environment)
          ..removeWhere(
            (k, _) => k.startsWith('CHIYO_') || k.startsWith('CODEX_'),
          );
        Future<Map<String, dynamic>> call(
          List<String> arguments, {
          int expected = 0,
        }) => ui.resolve(() async {
          final result = await Process.run(
            cli,
            [...arguments, '--json'],
            environment: {
              ...cleanEnvironment,
              'CHIYO_CONTEXT': contextFile.path,
              'CHIYO_CONNECTION_DIRECTORY': appDirectory.path,
            },
            includeParentEnvironment: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          scan(result.stdout as String);
          scan(result.stderr as String);
          final decoded =
              jsonDecode(result.stdout as String) as Map<String, dynamic>;
          if (result.exitCode != expected) {
            throw StateError(
              'Public CLI ${arguments.take(2).join(' ')} exit ${result.exitCode}; status=${(decoded['data'] as Map?)?['status']}; error=${(decoded['error'] as Map?)?['code']}',
            );
          }
          return decoded;
        });
        var approvalSequence = 0;
        Future<void> approve(String request) => ui.resolve(() async {
          final detail = approvalDetailFromJson(
            await server.owner.request(
              'GET',
              '/v1/owner/approvals/details/$request',
            ),
          );
          if (!detail.credentialBatch) {
            throw StateError('Synthetic approval is not a batch');
          }
          await server.owner.request(
            'POST',
            '/v1/owner/approvals/decisions',
            approvalChangeToJson(
              WorkspaceApprovalChange(
                operationId: 'approve-${++approvalSequence}',
                requestId: request,
                reviewToken: detail.reviewToken,
                action: WorkspaceApprovalAction.approve,
                selected: ['b1'],
              ),
            ),
          );
        });
        Future<Map<String, dynamic>> settle(String operation) async {
          for (var i = 0; i < 100; i++) {
            final response = await call(['operations', 'show', operation]);
            final data = response['data'] as Map<String, dynamic>;
            if (!{'checking', 'dispatched'}.contains(data['executionState'])) {
              return data;
            }
            await ui.resolve(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
          }
          throw StateError('Synthetic public fill did not settle');
        }

        Future<String> request(String via, List<String> target) async {
          final response = await call([
            'fill',
            'request',
            '--credential',
            credentials[via]!,
            '--via',
            via,
            ...target,
            '--purpose',
            'Synthetic $via integration',
            '--operation',
            'submit-$via',
          ]);
          return (response['data'] as Map)['requestId'] as String;
        }

        Future<void> execute(String request, String operation) async {
          await call([
            'fill',
            'run',
            '--request',
            request,
            '--operation',
            operation,
          ]);
          final result = await settle(operation);
          expect(result['executionState'], 'filled', reason: '$result');
          final duplicate = await call(['operations', 'retry', operation]);
          expect((duplicate['data'] as Map)['executionState'], 'filled');
        }

        final formServer = await ui.resolve(
          () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        );
        form = formServer;
        formServer.listen((request) async {
          request.response.headers.contentType = ContentType.html;
          request.response.write(_form);
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${formServer.port}/login';
        final activeChrome = await ui.resolve(
          () => SyntheticChrome.start(chromeExecutable, root),
        );
        chrome = activeChrome;
        await ui.resolve(() => activeChrome.go(url));
        final chromeRequest = await request('chrome', [
          '--browser',
          activeChrome.address,
          '--tab',
          activeChrome.tab,
          '--url',
          url,
          '--form',
          '#login',
          '--selector',
          '[name="password"]',
        ]);
        expect(
          await ui.resolve(() => activeChrome.evaluate('window.inputEvents')),
          0,
        );
        await approve(chromeRequest);
        await execute(chromeRequest, 'run-chrome');
        expect(
          await ui.resolve(
            () => activeChrome.evaluate(_check(secrets['chrome']!)),
          ),
          {'matched': true, 'otherEmpty': true, 'events': 1},
        );
        await ui.resolve(
          () => activeChrome.evaluate(
            'document.querySelector("#password").value="";true',
          ),
        );
        await record({
          'phase': 'chrome_passed',
          'exactSyntheticMatch': true,
          'oneInputAfterRetry': true,
          'productionAppHost': true,
        });

        final ego = await ui.resolve(findInstalledEgoBrowser);
        expect(ego, isNotNull);
        Future<Object?> egoControl(String operation) => ui.resolve(() async {
          final process = await Process.start(ego!, ['nodejs']);
          final output = utf8.decoder.bind(process.stdout).join(),
              errors = utf8.decoder.bind(process.stderr).join();
          process.stdin.add(
            utf8.encode(
              'const task=await taskSpace($space);const page=task.page(${jsonEncode(page)});const result=await (async()=>{$operation})();console.log("chiyo-integration:"+JSON.stringify(result));',
            ),
          );
          await process.stdin.close();
          final code = await process.exitCode;
          final out = await output, err = await errors;
          scan(out);
          scan(err);
          if (code != 0) throw StateError('Synthetic Ego control failed');
          final lines = const LineSplitter()
              .convert('$out\n$err')
              .where((s) => s.startsWith('chiyo-integration:'));
          return jsonDecode(
            lines.single.substring('chiyo-integration:'.length),
          );
        });
        await egoControl('await page.goto(${jsonEncode(url)});return true;');
        final egoRequest = await request('ego', [
          '--space',
          '$space',
          '--page',
          page,
          '--url',
          url,
          '--form',
          '#login',
          '--selector',
          '[name="password"]',
        ]);
        expect(
          await egoControl('return await page.evaluate("window.inputEvents");'),
          0,
        );
        await approve(egoRequest);
        await execute(egoRequest, 'run-ego');
        expect(
          await egoControl(
            'return await page.evaluate(${jsonEncode(_check(secrets['ego']!))});',
          ),
          {'matched': true, 'otherEmpty': true, 'events': 1},
        );
        await egoControl(
          'return await page.evaluate(\'document.querySelector("#password").value="";true\');',
        );
        await record({
          'phase': 'browsers_passed',
          'chrome': true,
          'ego': true,
          'oneInputEachAfterRetry': true,
          'productionAppHost': true,
        });

        final native = await ui.resolve(
          () => WindowsPasswordReceiver.start(
            receiverExecutable,
            secrets['focus']!,
          ),
        );
        receiver = native;
        await record({
          'phase': 'awaiting_win32_focus',
          'receiver': receiverExecutable,
          'actions': ['native-positive', 'native-plain', 'finish'],
        });
        String? nativeRequest;
        var seen = 0, positive = false, plain = false, finished = false;
        final deadline = DateTime.now().add(const Duration(minutes: 4));
        while (!finished && DateTime.now().isBefore(deadline)) {
          final command = await ui.resolve(() async {
            final file = File('$evidence/command.json');
            if (!await file.exists()) return null;
            try {
              return jsonDecode(await file.readAsString())
                  as Map<String, dynamic>;
            } on FormatException {
              return null;
            }
          });
          if (command == null ||
              command['id'] is! int ||
              (command['id'] as int) <= seen) {
            await ui.resolve(
              () => Future<void>.delayed(const Duration(milliseconds: 70)),
            );
            continue;
          }
          seen = command['id'] as int;
          switch (command['action']) {
            case 'native-positive':
              nativeRequest = await request('focus', []);
              expect((await ui.resolve(native.verify))['empty'], true);
              await approve(nativeRequest);
              await execute(nativeRequest, 'run-native');
              final verified = await ui.resolve(native.verify);
              expect(verified['matches'], true);
              expect(verified['noPaste'], true);
              expect(verified['clipboardUnchanged'], true);
              await ui.resolve(native.clear);
              positive = true;
              await record({
                'id': seen,
                'phase': 'native_positive_passed',
                'receiver': verified,
                'cleared': true,
              });
            case 'native-plain':
              expect(positive, true);
              final refused = await ui.resolve(() async {
                final result = await Process.run(
                  cli,
                  [
                    'fill',
                    'run',
                    '--request',
                    nativeRequest!,
                    '--operation',
                    'native-plain',
                    '--json',
                  ],
                  environment: {
                    ...cleanEnvironment,
                    'CHIYO_CONTEXT': contextFile.path,
                    'CHIYO_CONNECTION_DIRECTORY': appDirectory.path,
                  },
                  includeParentEnvironment: false,
                  stdoutEncoding: utf8,
                  stderrEncoding: utf8,
                );
                scan(result.stdout as String);
                scan(result.stderr as String);
                if (result.exitCode == 0) {
                  throw StateError('Ordinary input was accepted');
                }
                return jsonDecode(result.stdout as String);
              });
              expect((await ui.resolve(native.verify))['empty'], true);
              plain = true;
              await record({
                'id': seen,
                'phase': 'native_plain_refused',
                'result': refused,
                'receiverEmpty': true,
              });
            case 'finish':
              expect(positive && plain, true);
              await ui.resolve(() => platform.events!(DesktopEvent.quit));
              expect(platform.terminated, true);
              final endpoint = await ui.resolve(
                () => readPrivateDeviceState(
                  File(
                    '${appDirectory.path}/credential-batch-host/endpoint.json',
                  ),
                ),
              );
              expect(endpoint!['phase'], 'closed');
              final denied = await ui.resolve(
                () => DeviceCredentialBatchClient(
                  server.profiles.first,
                  directory: appDirectory,
                ).execute(context.secret, {'command': 'capabilities'}),
              );
              expect(denied['status'], 'service_unavailable');
              finished = true;
              await record({
                'id': seen,
                'phase': 'passed',
                'chrome': true,
                'ego': true,
                'win32': true,
                'ordinaryInputRefused': true,
                'appQuitClosedHost': true,
                'secretAbsentFromPublicResults': true,
              });
            default:
              throw StateError('Unknown synthetic integration action');
          }
        }
        expect(finished, true, reason: 'Native operator phase did not finish');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await ui.resolve(() => receiver?.close() ?? Future<void>.value());
        await ui.resolve(() => chrome?.close() ?? Future<void>.value());
        await ui.resolve(
          () => form?.close(force: true) ?? Future<void>.value(),
        );
        await ui.resolve(server.dispose);
        HttpOverrides.global = previousHttp;
        semantics.finishAfterUnmount();
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 12)),
    semanticsEnabled: false,
  );
}

String _check(String expected) =>
    '({matched:document.querySelector("#password").value===${jsonEncode(expected)},otherEmpty:document.querySelector("#other-password").value==="",events:window.inputEvents})';
const _form =
    '''<!doctype html><meta charset="utf-8"><title>Chiyo synthetic public fill</title>
<form id="login"><input id="account"><input id="password" name="password" type="password"></form>
<form id="other"><input id="other-password" name="password" type="password"></form>
<script>window.inputEvents=0;document.querySelector('#password').addEventListener('input',()=>window.inputEvents++);</script>''';
