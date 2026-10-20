import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/desktop_runtime.dart';
import 'package:info_desktop/main.dart';
import '../test/support/desktop_platform_fixture.dart';
import '../test/support/credential_maintenance_fixture.dart';

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
    for (final item in {
      'SimSun': 'simsun.ttc',
      'Georgia': 'georgia.ttf',
      'Consolas': 'consola.ttf',
    }.entries) {
      await (FontLoader(item.key)..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  '${Platform.environment['WINDIR']}/Fonts/${item.value}',
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
    }
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    testWidgets('credential maintenance failure ${size.width.toInt()}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      debugDisableShadows = false;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var now = DateTime.utc(2026, 10, 1);
      final repository = MaintenanceRepository();
      final service = InformationService(
        repository: repository,
        clock: () => now,
      );
      final credential = await service.owner.createStringCredential(
        name: '文档服务访问 Token',
        publicPurpose: 'API Token',
        secret: 'fictional-old',
      );
      await service.owner.rotateStringCredential(
        credential.id,
        credential.revision,
        'fictional-current',
      );
      final runtime = DesktopRuntime(
        service: service,
        platform: NativeDesktopFixture(),
        closeServer: () async {},
        closeRepository: () async {},
      );
      await runtime.start();
      const key = ValueKey('maintenance-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: InformationApp(service: service, port: 0, runtime: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-credentials-mode')));
      await tester.pumpAndSettle();
      repository.fail = true;
      now = now.add(const Duration(days: 30));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(runtime.credentialCleanupFailed, isTrue);
      expect(repository.credentialMaterials.length, 2);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final pixels = await boundary.toImage(pixelRatio: 1);
        final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory(
          '../../docs/development/evidence/27-credentials/r9',
        );
        await folder.create(recursive: true);
        await File(
          '${folder.path}/purple-${size.width.toInt()}-maintenance-failure.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        pixels.dispose();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(runtime.quit);
      debugDisableShadows = true;
    });
  }
}
