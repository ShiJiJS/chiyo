import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'ProductSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
    await (FontLoader(
      'AppSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
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
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    testWidgets('history and settings ${size.width.toInt()}', (tester) async {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime(2026, 10, 17, 13, 0);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      final docs = await service.owner.createInformation('文档服务', '', const [
        FieldInput('访问地址', '', 'https://docs.beichen.example'),
        FieldInput('部署目录', '', '/srv/beichen/docs'),
      ]);
      final info = await service.owner.createInformation('项目约定', '', const [
        FieldInput('项目代号', '', 'BEICHEN'),
      ]);
      final refs = [
        ...docs.fields.map((f) => FieldRef(docs.id, f.id)),
        FieldRef(info.id, info.fields.single.id),
      ];
      await service.owner.createTemplate('服务器', '连接与部署信息', const [
        TemplateFieldInput('地址', '服务器访问地址'),
        TemplateFieldInput('用户名', '登录用户名'),
        TemplateFieldInput('部署说明', '部署路径或约定', kind: FieldKind.textNote),
      ]);
      await service.owner.createTemplate('网站账号', '账号与联系人', const [
        TemplateFieldInput('网站地址', '访问入口'),
        TemplateFieldInput('用户名', '登录名'),
      ]);
      for (final title in [
        '核对家庭网络配置',
        '测试环境部署',
        '测试环境连接检查',
        '更新项目访问入口',
        '整理项目服务资料',
        '准备发布说明',
        '检查备份路径',
      ]) {
        final s = service.agent.openSession('Codex');
        final r = service.agent.request(s, title, refs);
        service.owner.approve(
          r.id,
          refs,
          lifetime: const Duration(minutes: 30),
        );
        service.owner.revoke(r.id);
        now = now.add(const Duration(minutes: 10));
      }
      now = DateTime(2026, 10, 17, 14, 32);
      final s = service.agent.openSession('Codex');
      final r = service.agent.request(s, '部署北辰文档站', refs);
      service.owner.approve(r.id, refs, lifetime: const Duration(minutes: 30));
      final grant = service.agent.claim(s, r.id);
      now = DateTime(2026, 10, 17, 14, 33, 8);
      await service.agent.read(grant.token, refs.first);
      now = DateTime(2026, 10, 17, 14, 35, 12);
      await service.agent.read(grant.token, refs.last);
      for (var i = 0; i < 8; i++) {
        final pendingSession = service.agent.openSession('待处理会话 $i');
        service.agent.request(pendingSession, '核对部署资料 $i', refs);
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: InformationApp(service: service, port: 0),
        ),
      );
      Future<void> capture(String name) async {
        await tester.pumpAndSettle();
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final picture = await render.toImage(pixelRatio: 1);
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            '../../docs/development/evidence/26-history-settings/r3/$name-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
      }

      await tester.tap(find.byKey(const ValueKey('nav-3')));
      await capture('history-scope');
      await tester.tap(find.text('实际访问 2'));
      await capture('history-access');
      await tester.tap(find.byKey(const ValueKey('nav-4')));
      await capture('settings-appearance');
      for (final section in [
        'notifications',
        'records',
        'templates',
        'backups',
        'application',
      ]) {
        await tester.tap(find.byKey(ValueKey('settings-section-$section')));
        await capture('settings-$section');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}

