import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:info_cli/agent_client.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/information_files.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/ui.dart';
import 'support/isolated_desktop.dart';
import 'support/native_semantics_lifetime.dart';

/// Used only by the automatic sandbox/process probe. The interactive run
/// retains native panels; automatic results do not certify those OS panels.
class _FixtureFiles implements InformationFilePicker {
  _FixtureFiles(this.source, this.output);
  final String source, output;
  @override
  Future<String?> choose() async => source;
  @override
  Future<String?> saveAs(String originalName) async => output;
}

/// Interactive native acceptance: use Computer Use for the real Open/Save
/// panels and approval. All content and the encrypted library are synthetic.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Mac signed worker, SSH approval and ordinary file workflow',
    (tester) async {
      final semantics = NativeSemanticsLifetime(tester);
      expect(Platform.isMacOS, isTrue);
      const key = String.fromEnvironment('SYNTHETIC_SSH_KEY');
      const host = String.fromEnvironment('SYNTHETIC_SSH_HOST');
      const port = String.fromEnvironment('SYNTHETIC_SSH_PORT');
      const automatic = bool.fromEnvironment('MAC_QA_AUTOMATIC');
      for (final value in [key, host, port]) {
        expect(value, isNotEmpty);
      }
      final fixture = await IsolatedDesktopFixture.start(
        informationDeliveryFiles: NativeInformationDeliveryFiles(),
      );
      final service = fixture.service;
      final client = AgentClient(fixture.port);
      addTearDown(() async {
        client.close();
        await tester.pumpWidget(const SizedBox());
        semantics.finishAfterUnmount();
        await fixture.close();
      });
      Future<void> until(bool Function() done, String phase) async {
        debugPrint('MAC_QA_PHASE=$phase');
        final deadline = DateTime.now().add(const Duration(minutes: 5));
        while (!done()) {
          await tester.pump(const Duration(milliseconds: 100));
          if (!DateTime.now().isBefore(deadline)) {
            fail('Native UI did not complete: $phase');
          }
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      const original = [0, 255, 37, 80, 68, 70, 10];
      final source = File('${fixture.root.path}/synthetic-简历.pdf');
      final automaticOutput = '${fixture.root.path}/saved-original.pdf';
      await source.writeAsBytes(original);
      debugPrint('MAC_QA_SOURCE=${source.path}');
      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: InformationLibrary(
              owner: service.owner,
              files: automatic
                  ? _FixtureFiles(source.path, automaticOutput)
                  : const NativeInformationFilePicker(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-information')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('item-name')),
        'Mac 合成简历',
      );
      await tester.enterText(find.byKey(const ValueKey('field-name-0')), '简历');
      await tester.ensureVisible(find.byKey(const ValueKey('field-kind-0')));
      await tester.tap(find.byKey(const ValueKey('field-kind-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('choose-file-0')));
      await tester.tap(find.byKey(const ValueKey('choose-file-0')));
      await until(
        () => find.text('synthetic-简历.pdf').evaluate().isNotEmpty,
        'choose-original',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('save-information')),
      );
      await tester.tap(find.byKey(const ValueKey('save-information')));
      await until(
        () => service.owner.information.any((i) => i.name == 'Mac 合成简历'),
        'save-encrypted-original',
      );
      final item = service.owner.information.singleWhere(
        (i) => i.name == 'Mac 合成简历',
      );
      final field = item.fields.single;
      await tester.ensureVisible(
        find.byKey(ValueKey('export-file-${field.id}')),
      );
      await tester.tap(find.byKey(ValueKey('export-file-${field.id}')));
      await until(
        () =>
            find.textContaining('文件已另存，').evaluate().isNotEmpty ||
            find.textContaining('操作结果未确认。').evaluate().isNotEmpty,
        automatic
            ? 'save-original-with-picker-fixture'
            : 'save-original-outside-container',
      );
      expect(find.textContaining('文件已另存，'), findsOneWidget);
      if (automatic) {
        expect(await File(automaticOutput).readAsBytes(), original);
      }

      await service.owner.configureSshKnownHosts(
        '合成 localhost',
        utf8.encode('[127.0.0.1]:$port $host\n'),
      );
      var credential = await service.owner.createFileCredential(
        name: 'Mac 合成 SSH 私钥',
        publicPurpose: '仅本机测试服务',
        fileName: 'synthetic_ed25519',
        bytes: base64Decode(key),
      );
      credential = await service.owner.updateCredentialMetadata(
        credential.id,
        credential.revision,
        name: credential.name,
        publicPurpose: credential.publicPurpose,
        privateNote: '',
        suggestedBinding: 'ssh_key',
        discoverable: true,
      );
      await client.execute({'command': 'session', 'chatLabel': 'Mac 独立原生验收'});
      Map<String, Object?> launch(String executable) => {
        'receiver': 'ssh_identity',
        'executable': '/usr/bin/ssh',
        'argv': [
          '-T',
          '-o',
          'BatchMode=yes',
          '-i',
          {'file': 'ssh_key'},
          '-p',
          port,
          'fixture@127.0.0.1',
          executable,
        ],
        'cwd': fixture.root.path,
        'env': <String, Object?>{},
      };
      final request = await client.execute({
        'command': 'request-use',
        'protocolVersion': 2,
        'purpose': '合成凭据与普通附件验收',
        'credentials': [
          {'alias': 'ssh_key', 'credentialId': credential.id, 'version': 1},
        ],
        'launch': launch('/usr/bin/true'),
        'readFields': [FieldRef(item.id, field.id).toJson()],
      });
      expect(request['status'], 'pending', reason: jsonEncode(request));
      final requestId = request['requestId'] as String;
      await tester.pumpWidget(
        InformationApp(
          service: service,
          port: fixture.port,
          runtime: fixture.bootstrap.runtime,
        ),
      );
      await tester.pumpAndSettle();
      if (automatic) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('credential-use-approve')),
        );
        await tester.tap(find.byKey(const ValueKey('credential-use-approve')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('确认批准'));
        await tester.tap(find.text('确认批准'));
        await tester.pumpAndSettle();
      }
      await until(
        () => service.owner.credentialUseRequests.single.decidedAt != null,
        'approve-credential-and-file-in-ui',
      );
      expect(
        service.owner.credentialGrantState(
          service.owner.credentialUseRequests.single,
        ),
        'available',
      );
      final ids = <String>[];
      for (final entry in [
        ('first', '/usr/bin/true', 0),
        ('second', '/usr/bin/false', 1),
      ]) {
        final command = {
          'command': 'run-use',
          'protocolVersion': 2,
          'requestId': requestId,
          'operationId': entry.$1,
          'launch': launch(entry.$2),
        };
        final accepted = await client.execute(command);
        expect(accepted['status'], 'accepted', reason: jsonEncode(accepted));
        final id = accepted['executionId'] as String;
        ids.add(id);
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        Map<String, dynamic> status;
        do {
          status = await client.execute({
            'command': 'execution-status',
            'executionId': id,
          });
          if (status['executionState'] == 'exited' &&
              status['cleanupState'] == 'complete') {
            break;
          }
          await client.execute({'command': 'cleanup-use', 'executionId': id});
          await tester.pump(const Duration(milliseconds: 100));
          if (!DateTime.now().isBefore(deadline)) {
            fail('Native worker failed: ${jsonEncode(status)}');
          }
        } while (true);
        expect(status['exitCode'], entry.$3);
        expect((await client.execute(command))['duplicate'], isTrue);
      }
      expect(
        service.owner.credentialExecutions.map((e) => e.jobName).toSet(),
        hasLength(2),
      );
      final fetch = {
        'command': 'file-fetch',
        'requestId': requestId,
        'itemId': item.id,
        'fieldId': field.id,
        'operationId': 'original',
      };
      final delivered = await client.execute(fetch);
      expect(delivered['status'], 'ok', reason: jsonEncode(delivered));
      final copy = delivered['delivery'] as Map;
      expect(await File(copy['path'] as String).readAsBytes(), original);
      final repeated = await client.execute(fetch);
      expect((repeated['delivery'] as Map)['deliveryId'], copy['deliveryId']);
      final released = await client.execute({
        'command': 'file-release',
        'deliveryId': copy['deliveryId'],
      });
      expect((released['delivery'] as Map)['state'], 'released');
      expect(await File(copy['path'] as String).exists(), isFalse);
      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('history-entry-$requestId')));
      await tester.pumpAndSettle();
      debugPrint('MAC_QA_PHASE=inspect-history');
      if (!automatic) {
        final gate = File('${fixture.root.path}/finish-qa');
        await until(gate.existsSync, 'inspect-history');
      }
      await tester.ensureVisible(
        find.byKey(ValueKey('use-operation-${ids.first}')),
      );
      await tester.tap(find.byKey(ValueKey('use-operation-${ids.first}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('查看本次执行记录与清理 →'));
      await tester.tap(find.text('查看本次执行记录与清理 →'));
      await tester.pumpAndSettle();
      expect(find.text(ids.first), findsOneWidget);
      expect(find.textContaining('/usr/bin/true'), findsWidgets);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('撤销使用授权'));
      await tester.tap(find.text('撤销使用授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      final denied = await client.execute({
        'command': 'run-use',
        'protocolVersion': 2,
        'requestId': requestId,
        'operationId': 'after-revoke',
        'launch': launch('/usr/bin/true'),
      });
      expect(denied['errorCode'], 'grant_revoked');
      expect(service.owner.credentialExecutions, hasLength(2));
      // Credential revocation leaves the independently approved field access
      // usable. Revoking that field in the actual history UI reclaims its copy.
      final independent = await client.execute({
        ...fetch,
        'operationId': 'independent-file',
      });
      expect(independent['status'], 'ok', reason: jsonEncode(independent));
      final independentCopy = independent['delivery'] as Map;
      expect(
        await File(independentCopy['path'] as String).readAsBytes(),
        original,
      );
      final fieldGrant = (await service.owner.history()).grants.singleWhere(
        (g) => g.requestId == requestId,
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('history-entry-${fieldGrant.id}')),
      );
      await tester.tap(find.byKey(ValueKey('history-entry-${fieldGrant.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('撤销授权'));
      await tester.tap(find.text('撤销授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认撤销'));
      await tester.pumpAndSettle();
      await service.owner.reconcileInformationFileDeliveries();
      expect(await File(independentCopy['path'] as String).exists(), isFalse);
      final fileDenied = await client.execute({
        ...fetch,
        'operationId': 'after-field-revoke',
      });
      expect(fileDenied['errorCode'], 'not_authorized');
      debugPrint(
        automatic
            ? 'MAC_QA_BOUNDARIES=picker-fixture,real-native-widget-approval,real-signed-worker,real-ssh,real-file-delivery'
            : 'MAC_QA_BOUNDARIES=real-native-panels,real-native-approval,real-signed-worker,real-ssh,real-file-delivery',
      );
      debugPrint(
        'MAC_QA_RESULT=two-ssh-exits-and-cleanup,file-import-export-fetch-release,duplicate-not-replayed,execution-receipt,independent-revocations',
      );
    },
    skip: !Platform.isMacOS,
    // Let the native accessibility observer enable semantics, as in the real
    // application. Pre-enabling only the framework loses the initial tree when
    // the macOS engine bridge attaches later, then receives partial updates.
    semanticsEnabled: false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
