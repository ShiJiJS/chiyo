import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/information_workspace.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';

class CaptureCredentialRepository extends MemoryInformationRepository {
  bool fail = false;
  @override
  Future<void> commitCredentials(
    List<ManagedCredential> credentials,
    List<CredentialMaterial> materials,
  ) async {
    if (fail) throw StateError('synthetic failure');
    await super.commitCredentials(credentials, materials);
  }
}

void main() {
  const linksOnly = bool.fromEnvironment('CAPTURE_LINKS_ONLY');
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
    for (final f in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(f.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${f.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final scenario in [
    (
      name: 'purple-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'purple-1280',
      size: const Size(1280, 800),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'green-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.green,
      scale: 1.0,
    ),
    (
      name: 'blue-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.blue,
      scale: 1.0,
    ),
    (
      name: 'mono-1440',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.mono,
      scale: 1.0,
    ),
    if (linksOnly)
      (
        name: 'mono-1280',
        size: const Size(1280, 800),
        theme: DesktopColorTheme.mono,
        scale: 1.0,
      ),
    (
      name: 'purple-long',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 1.0,
    ),
    (
      name: 'purple-200',
      size: const Size(1440, 900),
      theme: DesktopColorTheme.purple,
      scale: 2.0,
    ),
  ]) {
    if (linksOnly &&
        !{
          'purple-1440',
          'purple-1280',
          'mono-1440',
          'mono-1280',
        }.contains(scenario.name))
      continue;
    testWidgets('credential states ${scenario.name}', (tester) async {
      debugDisableShadows = false;
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repository = CaptureCredentialRepository();
      final service = InformationService(
        repository: repository,
        clock: () => DateTime(2026, 10, 17, 14, 40),
      );
      final owner = service.owner;
      final work = await owner.createDirectory('工作');
      final dir = await owner.createDirectory('测试环境', parentId: work.id);
      final server = await owner
          .createInformation('测试服务器', '用于测试环境的部署与连接排查。', const [
            FieldInput('访问地址', '', 'test.beichen.example'),
            FieldInput('SSH 端口', '', '2222'),
            FieldInput('登录用户', '', 'developer'),
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
      final token = await owner.createStringCredential(
        name: 'GitHub · 技能仓库 Token',
        publicPurpose: 'API Token',
        suggestedBinding: 'GH_TOKEN',
        secret: 'fictional-capture',
        privateNote: '用于技能仓库的日常维护。',
        expiresAt: DateTime(2026, 12, 31),
      );
      await owner.createStringCredential(
        name: '文档服务访问 Token',
        publicPurpose: 'API Token',
        suggestedBinding: 'DOCS_TOKEN',
        secret: 'fictional-docs',
      );
      final expired = await owner.createStringCredential(
        name: '归档服务旧 Token',
        publicPurpose: 'API Token',
        suggestedBinding: 'ARCHIVE_TOKEN',
        secret: 'fictional-expired',
        expiresAt: DateTime(2026, 10, 1),
      );
      await owner.createFileCredential(
        name: '测试账号访问配置',
        publicPurpose: 'AWS 凭据文件',
        fileName: 'credentials',
        bytes: [1, 2, 3],
      );
      for (var i = 0; i < 8; i++) {
        final s = service.agent.openSession('合成待办$i');
        service.agent.request(s, '合成请求', [
          FieldRef(server.id, server.fields.first.id),
        ]);
      }
      if (scenario.name == 'purple-long') {
        ssh = await owner.updateCredentialMetadata(
          ssh.id,
          ssh.revision,
          name: '长名称凭据的测试条目用于确认中间列表以及右侧标题换行后的完整显示',
          publicPurpose: '长公开用途与兼容形式说明。' * 60,
          privateNote: '这是用户私有备注，包含中文和 English token 字符，用于检验独立滚动、换行和末屏。' * 50,
          suggestedBinding: 'ssh_key',
          discoverable: false,
        );
        for (var i = 0; i < 120; i++) {
          await owner.createStringCredential(
            name: 'Synthetic ${i.toString().padLeft(3, '0')}',
            publicPurpose: 'Synthetic',
            secret: 'fictional',
          );
        }
      }
      const key = ValueKey('credential-state-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: informationTheme(scenario.theme),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: DesktopShell(
                service: service,
                port: 0,
                index: 1,
                onSelected: (_) {},
                hasBackups: true,
                colorTheme: scenario.theme,
                onThemeChanged: (_) {},
                child: InformationWorkspace(
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
        if (linksOnly && suffix != '-links') return;
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(key),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          const round = String.fromEnvironment(
            'CAPTURE_ROUND',
            defaultValue: 'r4',
          );
          final dir = Directory(
            '../../docs/development/evidence/27-credentials/$round',
          );
          await dir.create(recursive: true);
          await File(
            '${dir.path}/${scenario.name}$suffix.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await capture('-file');
      if (linksOnly) {
        await tap(find.text('测试服务器').last);
        await tap(find.text('管理关联'));
        await capture('-links');
        await tap(find.text('取消').last);
      } else if (scenario.name == 'purple-long' || scenario.scale > 1) {
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('credential-detail-scroll')),
            )
            .controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        await capture('-bottom');
        if (scenario.scale > 1) {
          await tester.drag(
            find.byKey(const ValueKey('credential-toolbar-scroll')),
            const Offset(-1100, 0),
          );
          await tester.pumpAndSettle();
          await capture('-toolbar-end');
          await tap(find.text('删除'));
          await capture('-delete-action');
          await tap(find.text('取消').last);
          await tap(find.text('更换版本'));
          await capture('-rotate-action');
          await tap(find.text('取消').last);
        }
      } else {
        await tap(find.byKey(const ValueKey('credential-metadata')));
        await capture('-discovery');
        await tap(find.text('取消').last);
        await tap(find.text('更换版本'));
        await capture('-rotate');
        await tap(find.text('取消').last);
        await tap(find.byKey(ValueKey('credential-row-${token.id}')));
        await capture('-string');
        await tap(find.byKey(ValueKey('credential-row-${expired.id}')));
        await capture('-expired');
        await tap(find.byKey(const ValueKey('new-credential')));
        await capture('-add-string');
        await tap(find.byKey(const ValueKey('credential-form-file')));
        await capture('-add-file');
        await tap(find.text('取消').last);
        if (scenario.name.startsWith('purple-')) {
          await tap(find.byKey(const ValueKey('new-credential')));
          await tester.enterText(
            find.byKey(const ValueKey('credential-name')),
            '失败时保留的合成草稿',
          );
          await tester.enterText(
            find.byKey(const ValueKey('credential-secret')),
            'synthetic-draft-only',
          );
          final before = owner.credentials.length;
          repository.fail = true;
          await tap(find.byKey(const ValueKey('save-credential')));
          expect(owner.credentials.length, before);
          expect(find.text('凭据未保存。原有内容未改变，请检查名称、内容和别名后重试。'), findsOneWidget);
          await capture('-save-failure');
          repository.fail = false;
          await tap(find.text('取消').last);
          await capture('-unsaved');
          await tap(find.text('放弃更改'));
        }
        await tester.enterText(
          find.byKey(const ValueKey('credential-search')),
          'no-such-credential',
        );
        await tester.pumpAndSettle();
        await capture('-empty');
        await tap(find.text('清除筛选'));
        await tap(find.byKey(ValueKey('credential-row-${ssh.id}')));
        await tap(find.text('测试服务器').last);
        expect(
          find.byKey(ValueKey('information-${server.id}')),
          findsOneWidget,
        );
        await capture('-server');
        await tap(find.text('管理关联'));
        await capture('-links');
        await tap(find.text('取消').last);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}
