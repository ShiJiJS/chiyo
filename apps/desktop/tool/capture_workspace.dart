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
    if (Platform.isWindows) {
      await (FontLoader('Consolas')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/consola.ttf',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('AppSans')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Medium.otf')))
        .load();
  });
  for (final scenario in [
    (
      name: 'inbox-1280',
      size: const Size(1280, 800),
      scale: 1.0,
      theme: DesktopColorTheme.purple,
    ),
    (
      name: 'inbox-1440',
      size: const Size(1440, 900),
      scale: 1.0,
      theme: DesktopColorTheme.green,
    ),
    (
      name: 'inbox-200',
      size: const Size(1440, 900),
      scale: 2.0,
      theme: DesktopColorTheme.blue,
    ),
    (
      name: 'inbox-mono',
      size: const Size(1440, 900),
      scale: 1.0,
      theme: DesktopColorTheme.mono,
    ),
    (
      name: 'inbox-blue',
      size: const Size(1440, 900),
      scale: 1.0,
      theme: DesktopColorTheme.blue,
    ),
  ]) {
    testWidgets('capture ${scenario.name}', (tester) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scenario.scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      var now = DateTime.utc(2026, 10, 17, 7, 30);
      final service = InformationService(
        repository: MemoryInformationRepository(),
        clock: () => now,
      );
      final item = await service.owner.createInformation(
        '北辰项目测试环境与部署说明',
        '测试环境的连接信息与内部说明',
        [
          for (var i = 0; i < 24; i++)
            FieldInput(
              i == 0
                  ? '服务器地址'
                  : i == 23
                  ? '部署连接字段 23：北辰项目多区域部署与测试环境说明、长名称换行核查、独立滚动与最终授权范围核对'
                  : '部署连接字段 $i',
              '仅供本次部署核查',
              i == 23
                  ? '${'long-configuration-value/'.padRight(250, 'x')}测试环境完整说明'
                  : 'test-$i.example.invalid',
            ),
        ],
      );
      for (var i = 0; i < 241; i++) {
        final session = service.agent.openSession(
          i == 240 ? '北辰项目部署讨论与测试服务器核查' : '项目核查聊天 $i',
        );
        service.agent.request(
          session,
          '核对测试服务器连接信息，检查部署前的环境配置。',
          item.fields.map((f) => FieldRef(item.id, f.id)).toList(),
        );
        now = now.add(const Duration(seconds: 1));
      }
      await service.owner.setColorTheme(scenario.theme);
      const boundaryKey = ValueKey('capture-boundary');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: InformationApp(service: service, port: 47125),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('approve-selection')).hitTestable(),
        findsOneWidget,
      );
      if (scenario.scale == 2) {
        final first = find.byKey(ValueKey('field-${item.fields.first.id}'));
        final decision = find.byKey(
          ValueKey('decision-${service.owner.requests.last.id}'),
        );
        expect(
          tester.getBottomLeft(first).dy,
          lessThanOrEqualTo(tester.getTopLeft(decision).dy),
          reason:
              'First complete field must be visible before the decision at 200%',
        );
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      Future<void> capture(String suffix) async {
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../docs/development/evidence/23-workspace',
          );
          await output.create(recursive: true);
          await File(
            '${output.path}/${scenario.name}$suffix.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('');
      final decisionBefore = tester.getTopLeft(
        find.byKey(const ValueKey('approve-selection')),
      );
      final document = find.byKey(
        PageStorageKey('detail-${service.owner.requests.last.id}'),
      );
      final last = find.byKey(ValueKey('field-${item.fields.last.id}'));
      await tester.scrollUntilVisible(
        last,
        300,
        scrollable: find
            .descendant(of: document, matching: find.byType(Scrollable))
            .first,
      );
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('approve-selection'))),
        decisionBefore,
      );
      expect(tester.takeException(), isNull);
      await capture('-last-field');
      await tester.tap(find.text('查看完整值'));
      await tester.pumpAndSettle();
      expect(find.text(item.fields.last.value), findsWidgets);
      await tester.tap(find.text('返回审批'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
    });
  }
}
