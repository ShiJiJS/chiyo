import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_cli/codex_association.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'support/isolated_desktop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native v2 approval runs two independent SSH operations across compiled adapters and preserves independent field access after revocation',
    (tester) async {
      const adapter = String.fromEnvironment('CODEX_EXECUTABLE'),
          worker = String.fromEnvironment('WORKER_EXECUTABLE'),
          ssh = String.fromEnvironment('SSH_EXECUTABLE'),
          keys = String.fromEnvironment('SSH_FIXTURE'),
          port = String.fromEnvironment('SSH_FIXTURE_PORT'),
          evidence = String.fromEnvironment('EVIDENCE_DIRECTORY');
      for (final value in [adapter, worker, ssh, keys, port, evidence]) {
        expect(value, isNotEmpty);
      }
      final fixture = await IsolatedDesktopFixture.start(
        credentialWorkerExecutable: worker,
      );
      final service = fixture.service;
      final boundary = GlobalKey();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final limit = DateTime.now().add(const Duration(seconds: 15));
        while (service.owner.credentialExecutions.any(
          (e) => e.materialLease != null && e.cleanupState != 'complete',
        )) {
          await service.owner.reconcileCredentialMaterialCleanup();
          if (!DateTime.now().isBefore(limit)) {
            await fixture.bootstrap.runtime?.stop();
            fixture.bootstrap.dispose();
            throw StateError(
              'Retained isolated library with uncleared execution facts: ${fixture.root.path}',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await fixture.close();
      });
      final initial = AgentClient(fixture.port);
      await initial.execute({'command': 'session', 'chatLabel': '核对北辰测试服务器'});
      final reference = await CodexAssociation(
        'reuse-native-chat',
        fixture.port,
        initial.sessionSecret!,
      ).save(Directory('${fixture.root.path}/associations'));
      initial.close();
      Future<Map<String, dynamic>> command(Map<String, Object?> input) async {
        final process = await Process.start(
          adapter,
          [],
          environment: {'CODEX_THREAD_ID': 'reuse-native-chat'},
          workingDirectory: fixture.root.path,
        );
        final output = process.stdout.transform(utf8.decoder).join(),
            error = process.stderr.transform(utf8.decoder).join();
        process.stdin.writeln(jsonEncode({'association': reference, ...input}));
        await process.stdin.close();
        expect(await process.exitCode.timeout(const Duration(seconds: 15)), 0);
        expect(await error, isEmpty);
        return jsonDecode(await output) as Map<String, dynamic>;
      }

      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final bitmap = await render.toImage(pixelRatio: 1),
            data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory(evidence);
        await folder.create(recursive: true);
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        bitmap.dispose();
      }

      final host = (await File(
        '$keys/host.pub',
      ).readAsString()).split(' ').take(2).join(' ');
      await service.owner.configureSshKnownHosts(
        '合成localhost主机',
        utf8.encode('[127.0.0.1]:$port $host\n'),
      );
      var c = await service.owner.createFileCredential(
        name: '北辰测试 SSH 私钥',
        publicPurpose: '隔离原生验收',
        fileName: 'synthetic_ed25519',
        bytes: await File('$keys/client').readAsBytes(),
      );
      c = await service.owner.updateCredentialMetadata(
        c.id,
        c.revision,
        name: c.name,
        publicPurpose: c.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
      Map<String, Object?> launch(List<String> remote) => {
        'receiver': 'ssh_identity',
        'executable': ssh,
        'argv': [
          '-T',
          '-o',
          'BatchMode=yes',
          '-i',
          {'file': 'ssh_key'},
          '-p',
          port,
          'fixture@127.0.0.1',
          ...remote,
        ],
        'cwd': fixture.root.path,
        'env': <String, Object?>{},
      };
      final field = FieldRef(
        service.owner.information.single.id,
        service.owner.information.single.fields.first.id,
      );
      final requested = await command({
        'command': 'request-use',
        'purpose': '一次批准，核对两次操作及独立连接字段',
        'credentials': [
          {'alias': 'ssh_key', 'credentialId': c.id, 'version': 1},
        ],
        'launch': launch(['/usr/bin/false']),
        'readFields': [field.toJson()],
      });
      expect(requested['status'], 'pending');
      final id = requested['requestId'] as String;
      expect(service.owner.credentialUseRequests.single.protocolVersion, 2);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: InformationApp(
            service: service,
            port: fixture.port,
            runtime: fixture.bootstrap.runtime,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('批准期限内使用'), findsOneWidget);
      // New approvals default to two hours. Choose a longer independent field
      // grant explicitly instead of depending on the old eight-hour default.
      await tester.ensureVisible(
        find.byKey(const ValueKey('credential-field-lifetime')),
      );
      await tester.tap(find.byKey(const ValueKey('credential-field-lifetime')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('8 小时').last);
      await tester.pumpAndSettle();
      expect(find.text('8 小时'), findsOneWidget);
      await capture('approval');
      await tester.ensureVisible(
        find.byKey(const ValueKey('credential-use-approve')),
      );
      await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认批准'));
      await tester.tap(find.text('确认批准'));
      await tester.pumpAndSettle();
      final approved = service.owner.credentialUseRequests.single;
      expect(
        approved.credentialExpiresAt!.difference(approved.decidedAt!),
        const Duration(hours: 2),
      );
      expect(
        approved.fieldExpiresAt!.difference(approved.decidedAt!),
        const Duration(hours: 8),
      );
      final operations = <Map<String, Object?>>[
        {
          'command': 'run-use',
          'requestId': id,
          'operationId': 'native-first',
          'launch': launch(['/usr/bin/false']),
        },
        {
          'command': 'run-use',
          'requestId': id,
          'operationId': 'native-second',
          'launch': launch(['/usr/bin/printf', '%s', 'reuse-native-second']),
        },
      ];
      final ids = <String>[];
      for (var i = 0; i < operations.length; i++) {
        final accepted = await command(operations[i]);
        expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
        final executionId = accepted['executionId'] as String;
        ids.add(executionId);
        final limit = DateTime.now().add(const Duration(seconds: 20));
        while (true) {
          final status = await command({
            'command': 'execution-status',
            'executionId': executionId,
          });
          if (status['executionState'] == 'exited' &&
              status['cleanupState'] == 'complete') {
            expect(status['exitCode'], i == 0 ? 1 : 0);
            break;
          }
          if (status['executionState'] == 'exited') {
            final cleanup = await command({
              'command': 'cleanup-use',
              'executionId': executionId,
            });
            if (cleanup['errorCode'] != null) {
              expect(
                cleanup['errorCode'],
                anyOf('cleanup_busy', 'cleanup_failed'),
              );
            }
          }
          if (!DateTime.now().isBefore(limit)) {
            fail('Native v2 operation did not settle: ${jsonEncode(status)}');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final repeated = await command(operations[i]);
        expect(repeated['duplicate'], isTrue);
        expect(repeated['executionId'], executionId);
      }
      expect(service.owner.credentialUseRequests, hasLength(1));
      expect(service.owner.credentialExecutions, hasLength(2));
      expect(
        service.owner.credentialUseRequests.single.credentialExpiresAt,
        approved.credentialExpiresAt,
      );
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'available',
      );
      expect(
        service.owner.credentialExecutions.map((e) => e.jobName).toSet(),
        hasLength(2),
      );
      final output = await command({
        'command': 'execution-output',
        'executionId': ids[1],
      });
      expect(
        utf8.decode([
          for (final dynamic chunk in output['chunks'] as List)
            ...base64Decode(chunk['dataBase64'] as String),
        ]),
        'reuse-native-second',
      );
      final conflict = await command({
        ...operations[0],
        'launch': operations[1]['launch'],
      });
      expect(conflict['errorCode'], 'operation_conflict');
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('history-entry-$id')));
      await tester.pumpAndSettle();
      expect(find.text('2 条记录'), findsOneWidget);
      expect(find.text('使用操作'), findsOneWidget);
      await capture('history');
      await tester.ensureVisible(
        find.byKey(ValueKey('use-operation-${ids[0]}')),
      );
      await tester.tap(find.byKey(ValueKey('use-operation-${ids[0]}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('/usr/bin/false'), findsWidgets);
      await capture('selected-operation');
      await tester.ensureVisible(find.text('查看本次执行记录与清理 →'));
      await tester.tap(find.text('查看本次执行记录与清理 →'));
      await tester.pumpAndSettle();
      expect(find.text(ids[0]), findsOneWidget);
      expect(find.textContaining('/usr/bin/false'), findsWidgets);
      await capture('first-operation-receipt');
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('撤销使用授权'));
      await tester.tap(find.text('撤销使用授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      final denied = await command({
        ...operations[1],
        'operationId': 'native-after-revoke',
      });
      expect(denied['errorCode'], 'grant_revoked');
      expect(service.owner.credentialExecutions, hasLength(2));
      expect(
        (await command({
          'command': 'read',
          'requestId': id,
          ...field.toJson(),
        }))['value'],
        'native.example.invalid',
      );
      await capture('revoked-fields-remain');
      await File('$evidence/facts.json').writeAsString(
        jsonEncode({
          'requestProtocol': approved.protocolVersion,
          'operations': service.owner.credentialExecutions
              .map(
                (e) => {
                  'operationId': e.operationId,
                  'state': e.state,
                  'exitCode': e.exitCode,
                  'cleanupState': e.cleanupState,
                  'createdAt': e.createdAt?.toIso8601String(),
                  'planHash': e.operationPlan?.planHash,
                },
              )
              .toList(),
          'credentialGrantState': service.owner.credentialGrantState(
            service.owner.credentialUseRequests.single,
          ),
          'fieldGrantState': service.owner.credentialFieldGrantState(
            service.owner.credentialUseRequests.single,
          ),
          'actualView': {
            'width': tester.view.physicalSize.width,
            'height': tester.view.physicalSize.height,
          },
        }),
      );
    },
  );
}
