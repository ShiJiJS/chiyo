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
    for (final family in ['ProductSans', 'AppSans']) {
      await (FontLoader(family)
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
          .load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    for (final entry in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(entry.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${entry.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    testWidgets('capture active approval auxiliary dialogs ${size.width}', (
      tester,
    ) async {
      debugDisableShadows = false;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => debugDisableShadows = true);
      final service = InformationService(
        repository: MemoryInformationRepository(),
      );
      final item = await service.owner.createInformation('连接说明', '公开连接说明', [
        FieldInput('长说明', '', '测试长内容与代码 value\n' * 40),
      ]);
      final session = service.agent.openSession('部署北辰文档站');
      final request = service.agent.request(session, '核对连接说明。', [
        FieldRef(item.id, item.fields.single.id),
      ]);
      const boundaryKey = ValueKey('approval-aux-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: InformationApp(service: service, port: 0),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory(
            '../../docs/development/evidence/26-history-settings/approval-aux',
          );
          await output.create(recursive: true);
          await File(
            '${output.path}/$name-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.tap(find.byKey(ValueKey('grant-lifetime-${request.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义…').last);
      await tester.pumpAndSettle();
      await capture('custom-lifetime');
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看完整值').last);
      await tester.pumpAndSettle();
      await capture('complete-field');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(service.close);
      debugDisableShadows = true;
    });
  }
}
