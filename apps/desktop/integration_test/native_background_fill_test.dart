// Real App bootstrap -> AppHost -> compiled CLI -> owner approval -> native
// setter. Requires a separately built synthetic receiver, never a user App.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_cli/chiyo_context.dart';
import 'package:info_cli/private_device_state.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/storage_desktop_launcher.dart';
import 'package:info_remote/automatic_connection.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_workspace/approval_transport.dart';
import 'package:info_workspace/workspace_approvals.dart';
import 'package:integration_test/integration_test.dart';

import '../../server/test/support/device_credential_fixture.dart';
import '../test/support/online_ui_harness.dart';
import 'support/native_semantics_lifetime.dart';

class _RealHttp extends HttpOverrides {}

/// Test-only receiver protocol; replies contain descriptions and booleans only.
class _Receiver {
  _Receiver(this.process, this.scan)
    : lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ) {
    errors = process.stderr.transform(utf8.decoder).listen((chunk) {
      if (stderr.length < 65536) stderr.write(chunk);
    });
  }
  final Process process;
  final void Function(String) scan;
  final StreamIterator<String> lines;
  final stderr = StringBuffer();
  late final StreamSubscription<String> errors;
  Future<Map<String, dynamic>> reply() async {
    if (!await lines.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Synthetic receiver closed before its receipt');
    }
    final text = lines.current;
    scan(text);
    if (utf8.encode(text).length > 65536) {
      throw StateError('Synthetic receipt too large');
    }
    final result = jsonDecode(text) as Map<String, dynamic>;
    scan(jsonEncode(result));
    if (['value', 'password', 'bytes', 'expected'].any(result.containsKey)) {
      throw StateError('Synthetic receiver returned material');
    }
    return result;
  }

  Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
    process.stdin.writeln(jsonEncode(input));
    await process.stdin.flush();
    return reply();
  }

  Future<void> close() async {
    try {
      await process.stdin.close();
    } on Object {
      /* Already exited. */
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    await lines.cancel();
    await errors.cancel();
    scan(stderr.toString());
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const cli = String.fromEnvironment('NATIVE_FILL_CLI');
  const executable = String.fromEnvironment('NATIVE_FILL_RECEIVER');
  const evidence = String.fromEnvironment('NATIVE_FILL_EVIDENCE');
  const kind = String.fromEnvironment('NATIVE_FILL_KIND');
  testWidgets(
    'the full App fills one fixed synthetic native field in the background',
    (tester) async {
      final ui = OnlineUiHarness(tester),
          semantics = NativeSemanticsLifetime(tester);
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _RealHttp();
      final forbidden = <String>[];
      void scan(String text) {
        for (final value in forbidden) {
          if (text.contains(value) ||
              text.contains(base64Encode(utf8.encode(value)))) {
            throw StateError(
              'Private material escaped a public acceptance response',
            );
          }
        }
        if (text.contains('"privateProof"') ||
            text.contains('"sessionSecret"')) {
          throw StateError('Private proof escaped the public CLI');
        }
      }

      DeviceCredentialFixture? fixture;
      _Receiver? receiver;
      File? hostEndpoint;
      try {
        expect(
          cli.isNotEmpty &&
              executable.isNotEmpty &&
              evidence.isNotEmpty &&
              kind.isNotEmpty,
          true,
        );
        expect(
          Platform.isMacOS
              ? kind == 'appkit_secure_text'
              : {
                  'win32_password',
                  'winforms_password',
                  'wpf_password',
                }.contains(kind),
          true,
        );
        final receiverPath = await ui.resolve(
          () => File(executable).resolveSymbolicLinks(),
        );
        expect(
          receiverPath.split(RegExp(r'[/\\]')).contains('build'),
          true,
          reason: 'Only a synthetic build fixture may receive test material',
        );
        final nonce = base64UrlEncode(
          List.generate(18, (_) => Random.secure().nextInt(256)),
        );
        final secret = '  SYNTHETIC-NATIVE-$nonce-中文🧭  ';
        forbidden.add(secret);
        final targetReceiver = await ui.resolve(
          () async => _Receiver(
            await Process.start(receiverPath, [
              '--native-fill-fixture',
              '--nonce',
              nonce,
              '--kind',
              kind,
            ]),
            scan,
          ),
        );
        receiver = targetReceiver;
        final ready = await ui.resolve(targetReceiver.reply);
        expect(ready['state'], 'ready');
        expect(ready['nonce'], nonce);
        expect(ready['controlKind'], kind);
        expect((ready['windowTitle'] as String).contains(nonce), true);
        final identifier = ready['fieldIdentifier'] as String;
        expect(identifier.isNotEmpty, true);
        expect(
          (await ui.resolve(
            () => receiver!.command({
              'command': 'expect',
              'bytes': utf8.encode(secret),
            }),
          ))['state'],
          'armed',
        );

        final f = await ui.resolve(DeviceCredentialFixture.create);
        fixture = f;
        final appDirectory = Directory('${f.root.path}/native-app');
        hostEndpoint = File(
          '${appDirectory.path}/credential-batch-host/endpoint.json',
        );
        await ui.resolve(
          () => AutomaticConnectionStore(appDirectory.path).publish(
            ConnectionProfile(
              address: f.owner.address.toString(),
              token: f.token,
              serverId: f.owner.serverId,
              certificate: f.certificate,
            ).toJson(),
            f.profiles.first,
          ),
        );
        final chat = await ui.resolve(
          () => f.agents.first.call('/session/lifecycle', {
            'chatLabel': 'Synthetic native full App acceptance',
          }),
        );
        final context = ChiyoContext(
          chatId: 'synthetic-native-$nonce',
          agentName: 'Synthetic acceptance Agent',
          secret: chat['sessionSecret'] as String,
          port: f.profiles.first.address.port,
          connection: f.profiles.first,
        );
        forbidden.addAll([
          context.secret,
          f.token,
          f.profiles.first.deviceToken,
        ]);
        final contextFile = File('${f.root.path}/chat/context.json');
        await ui.resolve(() => context.saveNew(contextFile));
        final credential = await ui.resolve(
          () => f.runtime.run(() async {
            final c = await f.runtime.service.owner.createStringCredential(
              name: 'Synthetic native acceptance',
              publicPurpose: 'Fixture only',
              secret: secret,
            );
            await f.runtime.service.owner.updateCredentialMetadata(
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
        await tester.pumpWidget(
          StorageDesktopLauncher(
            profiles: PrivateConnectionProfileStore(appDirectory.path),
            localBuilder: (_) => const SizedBox.shrink(),
          ),
        );
        await ui.until(
          () => File(
            '${appDirectory.path}/credential-batch-host/endpoint.json',
          ).existsSync(),
        );
        final environment = Map<String, String>.from(Platform.environment)
          ..removeWhere(
            (key, _) => key.startsWith('CHIYO_') || key.startsWith('CODEX_'),
          );
        Future<({int exit, Map<String, dynamic> data})> call(
          List<String> args,
        ) => ui.resolve(() async {
          final result = await Process.run(
            cli,
            [...args, '--json'],
            environment: {
              ...environment,
              'CHIYO_CONTEXT': contextFile.path,
              'CHIYO_CONNECTION_DIRECTORY': appDirectory.path,
            },
            includeParentEnvironment: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          scan(result.stdout as String);
          scan(result.stderr as String);
          final data =
              jsonDecode(result.stdout as String) as Map<String, dynamic>;
          scan(jsonEncode(data));
          return (exit: result.exitCode, data: data);
        });
        final discovered = await call([
          'fill',
          'targets',
          '--via',
          'native',
          '--app',
          ready['appId'] as String,
        ]);
        expect(
          discovered.exit,
          0,
          reason:
              'The production native adapter must be connected before acceptance',
        );
        final targets = ((discovered.data['data'] as Map)['targets'] as List)
            .map(
              (value) => NativeFillTarget.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .where(
              (target) =>
                  target.windowTitle == ready['windowTitle'] &&
                  target.fieldLabel.contains(identifier) &&
                  target.controlKind == kind,
            )
            .toList();
        expect(
          targets,
          hasLength(1),
          reason: 'Descriptions must identify exactly one fixture field',
        );
        final selected = targets.single;
        final selectedPath = await ui.resolve(
          () => File(selected.application.executable).resolveSymbolicLinks(),
        );
        expect(
          Platform.isWindows ? selectedPath.toLowerCase() : selectedPath,
          Platform.isWindows ? receiverPath.toLowerCase() : receiverPath,
        );
        final requested = await call([
          'fill',
          'request',
          '--via',
          'native',
          '--target',
          selected.targetId,
          '--credential',
          credential,
          '--purpose',
          'Synthetic background setter acceptance',
          '--operation',
          'native-request-$nonce',
        ]);
        expect(requested.exit, 0);
        final request = (requested.data['data'] as Map)['requestId'] as String;
        expect(
          (await ui.resolve(
            () => receiver!.command({'command': 'check'}),
          ))['matched'],
          false,
        );
        final detail = approvalDetailFromJson(
          await ui.resolve(
            () => f.owner.request(
              'GET',
              '/v1/owner/approvals/details/${Uri.encodeComponent(request)}',
            ),
          ),
        );
        expect(detail.scopes.single.label, contains('原生后台填写'));
        expect(detail.scopes.single.label, contains(identifier));
        await ui.resolve(
          () => f.owner.request(
            'POST',
            '/v1/owner/approvals/decisions',
            approvalChangeToJson(
              WorkspaceApprovalChange(
                operationId: 'native-approve-$nonce',
                requestId: request,
                reviewToken: detail.reviewToken,
                action: WorkspaceApprovalAction.approve,
                selected: ['b1'],
              ),
            ),
          ),
        );
        expect(
          (await ui.resolve(
            () => receiver!.command({'command': 'check'}),
          ))['matched'],
          false,
          reason: 'Approval must not fill',
        );
        final run = [
          'fill',
          'run',
          '--request',
          request,
          '--operation',
          'native-setter-$nonce',
        ];
        expect((await call(run)).exit, 0);
        Map<String, dynamic>? done;
        for (var i = 0; i < 150; i++) {
          final result = await call([
            'operations',
            'show',
            'native-setter-$nonce',
          ]);
          expect(result.exit, 0);
          final data = Map<String, dynamic>.from(result.data['data'] as Map);
          if (!{'checking', 'dispatched'}.contains(data['executionState'])) {
            done = data;
            break;
          }
          await ui.resolve(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        expect(done?['executionState'], 'filled');
        expect(done?['itemResults'], {'b1': 'sent'});
        final witness = await ui.resolve(
          () => receiver!.command({'command': 'check'}),
        );
        expect(witness['matched'], true);
        expect(witness['active'], false);
        expect(witness['focusedSinceArmed'], false);
        expect((await call(run)).exit, 0);
        expect(f.repo.credentialBatchOperations, hasLength(1));
        expect(
          (await ui.resolve(
            () => receiver!.command({'command': 'rebuild'}),
          ))['state'],
          'rebuilt',
        );
        final stale = await call([
          'fill',
          'run',
          '--request',
          request,
          '--operation',
          'native-stale-$nonce',
        ]);
        expect(stale.exit, 5);
        expect(
          {
            'target_unavailable',
            'destination_changed',
          }.contains((stale.data['error'] as Map)['code']),
          true,
        );
        expect(f.repo.credentialBatchOperations, hasLength(1));
        final receipt = jsonEncode({
          'kind': kind,
          'requestId': request,
          'operationId': 'native-setter-$nonce',
          'itemResults': done!['itemResults'],
          'matched': true,
          'active': false,
          'focusedSinceArmed': false,
          'staleTargetExit': stale.exit,
        });
        scan(receipt);
        await ui.resolve(() async {
          await Directory(evidence).create(recursive: true);
          await File(
            '$evidence/receipt.json',
          ).writeAsString(receipt, flush: true);
        });
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          final endpoint = hostEndpoint;
          if (endpoint != null) {
            await ui.resolve(() async {
              for (var i = 0; i < 150; i++) {
                if (!await endpoint.exists()) break;
                final state = await readPrivateDeviceState(endpoint);
                if (state?['phase'] == 'closed') break;
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
            });
          }
          if (receiver != null) await ui.resolve(receiver.close);
        } finally {
          try {
            if (fixture != null) await ui.resolve(fixture.dispose);
          } finally {
            try {
              semantics.finishAfterUnmount();
            } finally {
              HttpOverrides.global = previousHttp;
            }
          }
        }
      }
    },
    skip: cli.isEmpty || executable.isEmpty || evidence.isEmpty || kind.isEmpty,
  );
}
