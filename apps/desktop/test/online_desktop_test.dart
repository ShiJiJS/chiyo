import 'package:info_server/agent_devices.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/online_desktop_launcher.dart';
import 'package:info_remote/connection_profile.dart';
import 'package:info_server/mounted_database_key_store.dart';
import 'package:info_server/online_server.dart';
import 'package:info_server/server_configuration.dart';
import 'package:info_storage/info_storage.dart';
import '../../server/test/support/tls_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final priorHttp = HttpOverrides.current;
  setUpAll(() => HttpOverrides.global = _RealHttp());
  tearDownAll(() => HttpOverrides.global = priorHttp);
  testWidgets(
    'normal connection and editor persist to HTTPS and survive a fresh profile',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.InformationService service;
      late OnlineServer server;
      late SecurityContext serverTls;
      late String token, certificate;
      late String directoryId;
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('chiyo-online-ui-');
        await initializeServerSecrets('${root.path}/secrets');
        final tls = await createTlsFixture(root);
        certificate = await File(tls.ca).readAsString();
        token = base64Url
            .encode(
              await File('${root.path}/secrets/owner.token').readAsBytes(),
            )
            .replaceAll('=', '');
        repo = await EncryptedInformationRepository.open(
          '${root.path}/data',
          MountedDatabaseKeyStore('${root.path}/secrets/database.key'),
        );
        service = core.InformationService(repository: repo);
        final parent = await service.owner.createDirectory('团队');
        directoryId = (await service.owner.createDirectory(
          '项目',
          parentId: parent.id,
        )).id;
        serverTls = SecurityContext()
          ..useCertificateChain(tls.certificate)
          ..usePrivateKey(tls.privateKey);
        server = await OnlineServer.start(
          devices: AgentDeviceRegistry(repo),
          service: service,
          tls: serverTls,
          ownerToken: token,
          serverId: 'online-ui-synthetic-0001',
        );
      });
      Future<void> settle() async {
        for (var i = 0; i < 100; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump(const Duration(milliseconds: 40));
        }
      }

      Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
      );
      Future<void> connect(String profile) async {
        await t.pumpWidget(
          OnlineDesktopLauncher(
            key: ValueKey(profile),
            profiles: PrivateConnectionProfileStore('${root.path}/$profile'),
          ),
        );
        await settle();
        await t.enterText(field('服务器地址'), 'https://127.0.0.1:${server.port}');
        await t.enterText(field('Token'), token);
        await t.tap(find.text('证书设置（可选）'));
        await settle();
        await t.enterText(field('服务器 CA 证书'), certificate);
        await t.runAsync(() => t.tap(find.text('连接')));
        await settle();
        expect(
          find.byTooltip('添加资料'),
          findsWidgets,
          reason: find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .whereType<String>()
              .join(' | '),
        );
      }

      try {
        await connect('profile-one');
        await t.runAsync(() => t.tap(find.text('项目').first));
        await settle();
        await t.runAsync(() => t.tap(find.byTooltip('添加资料').first));
        await settle();
        expect(
          find.text('通用资料'),
          findsWidgets,
          reason: find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .whereType<String>()
              .join(' | '),
        );
        await t.runAsync(() => t.tap(find.text('通用资料').last));
        await settle();
        await t.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('library-edit-name')),
            matching: find.byType(TextField),
          ),
          '远程合成资料',
        );
        await t.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('library-edit-body')),
            matching: find.byType(TextField),
          ),
          '正文来自真实界面',
        );
        await t.runAsync(
          () => t.tap(find.byKey(const ValueKey('library-edit-save'))),
        );
        await settle();
        expect(service.owner.information, hasLength(1));
        expect(service.owner.information.single.name, '远程合成资料');
        expect(
          service.owner.information.single.fields.single.value,
          '正文来自真实界面',
        );
        expect(service.owner.information.single.layout!.typeId, 'generic');
        expect(service.owner.information.single.directoryId, directoryId);
        await t.runAsync(() => t.tap(find.text('编辑信息').first));
        await settle();
        await t.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('library-edit-body')),
            matching: find.byType(TextField),
          ),
          '修改后的服务器正文',
        );
        await t.runAsync(
          () => t.tap(find.byKey(const ValueKey('library-edit-save'))),
        );
        await settle();
        expect(service.owner.information.single.version, 2);
        expect(
          service.owner.information.single.fields.single.value,
          '修改后的服务器正文',
        );
        await t.enterText(
          find.byKey(const ValueKey('library-search')),
          '不存在的名称',
        );
        await settle();
        expect(find.text('远程合成资料'), findsNothing);
        await t.enterText(find.byKey(const ValueKey('library-search')), '远程');
        await settle();
        expect(find.text('远程合成资料'), findsWidgets);
        await t.pumpWidget(const SizedBox.shrink());
        await settle();
        await connect('profile-two');
        expect(find.text('远程合成资料'), findsWidgets);
        expect(service.owner.information, hasLength(1));
        await t.runAsync(() async {
          final dart =
              '${File(Platform.resolvedExecutable).parent.parent.parent.parent.path}/dart-sdk/bin/dart';
          final result = await Process.run(dart, [
            'run',
            'test/support/fetch_profile.dart',
            '${root.path}/profile-two',
          ], workingDirectory: '../../packages/info_remote');
          expect(result.exitCode, 0, reason: result.stderr as String);
          final output =
              jsonDecode((result.stdout as String).trim().split('\n').last)
                  as Map;
          final item = service.owner.information.single;
          expect(
            (output['items'] as List).single['digest'],
            sha256
                .convert(utf8.encode(jsonEncode(core.informationToJson(item))))
                .toString(),
          );
        });
        await t.pumpWidget(const SizedBox.shrink());
        await settle();
        await t.runAsync(
          () => t.pumpWidget(
            OnlineDesktopLauncher(
              key: const ValueKey('restored-profile-two'),
              profiles: PrivateConnectionProfileStore(
                '${root.path}/profile-two',
              ),
            ),
          ),
        );
        await settle();
        expect(find.text('远程合成资料'), findsWidgets);
        await t.runAsync(() => t.tap(find.byTooltip('连接设置')));
        await settle();
        await t.runAsync(() async {
          final port = server.port;
          await server.close();
          token = base64Url.encode(List.filled(32, 72)).replaceAll('=', '');
          server = await OnlineServer.start(
            devices: AgentDeviceRegistry(repo),
            service: service,
            tls: serverTls,
            ownerToken: token,
            serverId: 'online-ui-synthetic-0001',
            port: port,
          );
        });
        await t.runAsync(() => t.tap(find.text('连接')));
        await settle();
        expect(find.text('Token 不正确，请重新填写。'), findsOneWidget);
        await t.enterText(field('Token'), token);
        await t.runAsync(() => t.tap(find.text('连接')));
        await settle();
        expect(find.text('远程合成资料'), findsWidgets);
        await t.runAsync(() async {
          final saved = await PrivateConnectionProfileStore(
            '${root.path}/profile-two',
          ).read();
          expect(saved!.token, token);
        });
        await t.runAsync(() => t.tap(find.byTooltip('连接设置')));
        await settle();
        await t.runAsync(() async {
          final port = server.port;
          await server.close();
          server = await OnlineServer.start(
            devices: AgentDeviceRegistry(repo),
            service: service,
            tls: serverTls,
            ownerToken: token,
            serverId: 'online-ui-replacement-0002',
            port: port,
          );
        });
        await t.runAsync(() => t.tap(find.text('连接')));
        await settle();
        expect(find.text('服务器身份已变化，请核对服务器地址。'), findsOneWidget);
        await t.runAsync(() => t.tap(find.text('确认连接新服务器')));
        await settle();
        expect(find.text('远程合成资料'), findsWidgets);
        await t.runAsync(() async {
          expect(
            (await PrivateConnectionProfileStore(
              '${root.path}/profile-two',
            ).read())!.serverId,
            'online-ui-replacement-0002',
          );
        });
        final disconnectedPort = server.port;
        await t.runAsync(() => server.close());
        await settle();
        expect(
          find.byKey(const ValueKey('online-offline-blocker')),
          findsOneWidget,
        );
        await t.runAsync(() async {
          server = await OnlineServer.start(
            devices: AgentDeviceRegistry(repo),
            service: service,
            tls: serverTls,
            ownerToken: token,
            serverId: 'online-ui-replacement-0002',
            port: disconnectedPort,
          );
        });
        await t.runAsync(() => t.tap(find.text('重新连接')));
        await settle();
        expect(
          find.byKey(const ValueKey('online-offline-blocker')),
          findsNothing,
        );
        expect(find.text('远程合成资料'), findsWidgets);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        await settle();
        await t.runAsync(() async {
          await server.close();
          await service.close();
          await repo.close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
