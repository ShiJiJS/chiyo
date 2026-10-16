import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credentials.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final name in ['ProductSans', 'AppSans']) {
      await (FontLoader(name)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final font in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(font.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${font.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    testWidgets('credential representative capture ${size.width.toInt()}', (
      tester,
    ) async {
      debugDisableShadows = false;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => DateTime(2026, 10, 17, 14, 40),
      );
      final owner = service.owner;
      final work = await owner.createDirectory('工作');
      final dir = await owner.createDirectory('测试环境', parentId: work.id);
      final server = await owner.createInformation('测试服务器', '用于测试环境的部署与连接排查。', [
        const FieldInput('地址', '', 'test.beichen.example'),
      ], directoryId: dir.id);
      var ssh = await owner.createFileCredential(
        name: '测试服务器部署密钥',
        publicPurpose: 'SSH 私钥',
        privateNote: '用于测试环境的部署与连接排查。',
        suggestedBinding: 'ssh_key',
        fileName: 'deploy_ed25519',
        bytes: List.filled(464, 42),
      );
      ssh = await owner.rotateFileCredential(
        ssh.id,
        ssh.revision,
        bytes: List.filled(464, 43),
        fileName: 'deploy_ed25519',
      );
      ssh = await owner.setCredentialLinks(ssh.id, ssh.revision, [server.id]);
      for (final data in [
        ('GitHub · 技能仓库 Token', 'API Token', 'GH_TOKEN'),
        ('文档服务访问 Token', 'API Token', 'DOCS_TOKEN'),
        ('归档服务旧 Token', 'API Token', 'ARCHIVE_TOKEN'),
      ]) {
        await owner.createStringCredential(
          name: data.$1,
          publicPurpose: data.$2,
          suggestedBinding: data.$3,
          secret: 'fictional-capture',
          privateNote: '用于技能仓库的日常维护。',
          expiresAt: data.$3 == 'ARCHIVE_TOKEN'
              ? DateTime(2026, 10, 1)
              : DateTime(2026, 12, 31),
        );
      }
      await owner.createFileCredential(
        name: '测试账号访问配置',
        publicPurpose: 'AWS 凭据文件',
        fileName: 'credentials',
        bytes: [1, 2, 3],
      );
      for (var i = 0; i < 8; i++) {
        final session = service.agent.openSession('合成待办$i');
        service.agent.request(session, '合成请求', [
          FieldRef(server.id, server.fields.first.id),
        ]);
      }
      const key = ValueKey('credential-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: informationTheme(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: DesktopShell(
                service: service,
                port: 0,
                index: 1,
                onSelected: (_) {},
                hasBackups: true,
                onThemeChanged: (_) {},
                child: CredentialLibrary(
                  owner: owner,
                  initialCredentialId: ssh.id,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String suffix) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(
            '../../docs/development/evidence/27-credentials/r2',
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}/purple-${size.width.toInt()}$suffix.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('-file');
      await tester.tap(find.byKey(const ValueKey('new-credential')));
      await tester.pumpAndSettle();
      await capture('-add-string');
      await tester.tap(find.byKey(const ValueKey('credential-form-file')));
      await tester.pumpAndSettle();
      await capture('-add-file');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}
