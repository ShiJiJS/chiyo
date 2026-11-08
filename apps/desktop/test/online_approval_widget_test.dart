import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_server/agent_devices.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previous = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = previous);
  testWidgets(
    'normal online App notices an Agent request, approves selected fields and revokes',
    (t) async {
      t.view.physicalSize = const Size(1500, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.OnlineInformationRuntime runtime;
      late OnlineServer server;
      late HttpClient http;
      late PrivateConnectionProfileStore profiles;
      late String device;
      late core.InformationItem item;
      Future<Map<String, dynamic>> agent(
        String path,
        Map<String, Object?> body,
      ) async {
        final request = await http.postUrl(
          Uri.parse('https://127.0.0.1:${server.port}/v1/agent$path'),
        );
        request.headers.set('authorization', 'Bearer $device');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 250; i++) {
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
        fail('Online UI condition did not complete');
      }

      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'chiyo-online-approval-ui-',
        );
        await initializeServerSecrets('${root.path}/secrets');
        final fixture = await createTlsFixture(root);
        final tls = SecurityContext()
          ..useCertificateChain(fixture.certificate)
          ..usePrivateKey(fixture.privateKey);
        final trust = SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates(fixture.ca);
        final token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        runtime = await core.OnlineInformationRuntime.open(repository: repo);
        item = await runtime.run(
          () => runtime.service.owner.createInformation('远程合成服务器', '审批集成测试', [
            const core.FieldInput('主机地址', '', 'PRIVATE_SELECTED'),
            const core.FieldInput('登录账号', '', 'PRIVATE_UNSELECTED'),
          ]),
        );
        final devices = AgentDeviceRegistry(repo);
        device = (await devices.enroll(
          'synthetic-ui-device',
          'Synthetic UI CLI',
        )).bearer;
        server = await OnlineServer.start(
          runtime: runtime,
          devices: devices,
          tls: tls,
          ownerToken: token,
          serverId: 'online-approval-synthetic',
        );
        profiles = PrivateConnectionProfileStore('${root.path}/profile');
        await profiles.save(
          ConnectionProfile(
            address: 'https://127.0.0.1:${server.port}',
            token: token,
            serverId: 'online-approval-synthetic',
            certificate: await File(fixture.ca).readAsString(),
          ),
        );
        http = HttpClient(context: trust);
      });
      try {
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await until(() => find.byTooltip('连接设置').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('访问审批').first));
        await until(
          () => find
              .byKey(const ValueKey('approval-inbox-list'))
              .evaluate()
              .isNotEmpty,
        );
        late Map<String, dynamic> opened, requested;
        await t.runAsync(() async {
          opened = await agent('/session/lifecycle', {
            'chatLabel': '无演示入口的真实申请',
          });
          requested = await agent('/request', {
            'sessionSecret': opened['sessionSecret'],
            'purpose': '核对服务器地址',
            'operationId': 'ui-request-once',
            'fields': [
              for (final f in item.fields) {'itemId': item.id, 'fieldId': f.id},
            ],
          });
        });
        expect(requested['status'], 'pending');
        final requestId = requested['requestId'] as String;
        await until(
          () => find
              .byKey(ValueKey('approval-select-$requestId'))
              .evaluate()
              .isNotEmpty,
        );
        final unselected = jsonEncode([item.id, item.fields.last.id]);
        final toggle = find.byKey(ValueKey('approval-scope-$unselected'));
        await until(() => toggle.evaluate().isNotEmpty);
        expect(find.text('PRIVATE_SELECTED'), findsNothing);
        expect(find.text('PRIVATE_UNSELECTED'), findsNothing);
        await t.ensureVisible(toggle);
        await t.tap(toggle);
        await t.pump();
        final approve = find.byKey(const ValueKey('approval-approve'));
        await t.ensureVisible(approve);
        await t.runAsync(() => t.tap(approve));
        await until(
          () => find
              .byKey(const ValueKey('approval-revoke'))
              .evaluate()
              .isNotEmpty,
        );
        late Map<String, dynamic> grant;
        await t.runAsync(() async {
          grant = await agent('/claim', {
            'sessionSecret': opened['sessionSecret'],
            'requestId': requestId,
          });
          expect(grant['status'], 'ok');
          expect(
            (await agent('/read', {
              'token': grant['token'],
              'itemId': item.id,
              'fieldId': item.fields.first.id,
            }))['value'],
            'PRIVATE_SELECTED',
          );
          expect(
            (await agent('/read', {
              'token': grant['token'],
              'itemId': item.id,
              'fieldId': item.fields.last.id,
            }))['error'],
            'unauthorized',
          );
        });
        final revoke = find.byKey(const ValueKey('approval-revoke'));
        await t.ensureVisible(revoke);
        await t.runAsync(() => t.tap(revoke));
        await until(
          () =>
              find.byKey(const ValueKey('approval-revoke')).evaluate().isEmpty,
        );
        await t.runAsync(() async {
          expect(
            (await agent('/read', {
              'token': grant['token'],
              'itemId': item.id,
              'fieldId': item.fields.first.id,
            }))['error'],
            'unauthorized',
          );
        });
        // A later request must also refresh after the first observation has
        // already been consumed; this is not only an initial page load.
        late Map<String, dynamic> second;
        await t.runAsync(() async {
          second = await agent('/request', {
            'sessionSecret': opened['sessionSecret'],
            'purpose': '拒绝后续申请',
            'fields': [
              {'itemId': item.id, 'fieldId': item.fields.first.id},
            ],
          });
        });
        final secondSelect = find.byKey(
          ValueKey('approval-select-${second['requestId']}'),
        );
        await until(() => secondSelect.evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(secondSelect));
        final deny = find.byKey(const ValueKey('approval-deny'));
        await until(() => deny.evaluate().isNotEmpty);
        await t.ensureVisible(deny);
        await t.runAsync(() => t.tap(deny));
        await until(() => deny.evaluate().isEmpty);
        await t.runAsync(() async {
          expect(
            (await agent('/status', {
              'sessionSecret': opened['sessionSecret'],
              'requestId': second['requestId'],
            }))['status'],
            'denied',
          );
        });
        // The App has no ownership of the host. Queue another request while its
        // entire widget session is closed, then reopen the saved normal profile.
        await t.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 20; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
        late Map<String, dynamic> queued;
        await t.runAsync(() async {
          queued = await agent('/request', {
            'sessionSecret': opened['sessionSecret'],
            'purpose': 'App 关闭期间的申请',
            'fields': [
              {'itemId': item.id, 'fieldId': item.fields.first.id},
            ],
          });
        });
        expect(queued['status'], 'pending');
        await t.pumpWidget(OnlineDesktopLauncher(profiles: profiles));
        await until(() => find.byTooltip('连接设置').evaluate().isNotEmpty);
        await t.runAsync(() => t.tap(find.text('访问审批').first));
        await until(
          () => find
              .byKey(ValueKey('approval-select-${queued['requestId']}'))
              .evaluate()
              .isNotEmpty,
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        for (var i = 0; i < 20; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.runAsync(() async {
          http.close(force: true);
          await server.close();
          await runtime.close();
          await repo.close();
          await root.delete(recursive: true);
        });
        await t.pump(const Duration(seconds: 15));
      }
    },
  );
}
