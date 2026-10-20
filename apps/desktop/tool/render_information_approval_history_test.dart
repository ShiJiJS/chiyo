// Targeted Flutter visual inspection. The delivery adapter is synthetic.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/history.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';
import '../test/support/information_attachment_fixture.dart';

void main() {
  const directory = String.fromEnvironment(
    'ATTACHMENT_APPROVAL_RENDER_DIRECTORY',
  );
  if (directory.isEmpty) return;
  const width = int.fromEnvironment(
    'ATTACHMENT_RENDER_WIDTH',
    defaultValue: 1280,
  );
  const height = int.fromEnvironment(
    'ATTACHMENT_RENDER_HEIGHT',
    defaultValue: 800,
  );
  const themeName = String.fromEnvironment(
    'ATTACHMENT_RENDER_THEME',
    defaultValue: 'purple',
  );
  final theme = DesktopColorTheme.values.firstWhere((v) => v.name == themeName);
  testWidgets('inspect actual file approval and delivery history layout', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final family in ['ProductSans', 'AppSans']) {
        await (FontLoader(family)
              ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf')))
            .load();
      }
      for (final font in {
        'SimSun': 'simsun.ttc',
        'Georgia': 'georgia.ttf',
        'Consolas': 'consola.ttf',
      }.entries) {
        final bytes = await File(
          'C:/Windows/Fonts/${font.value}',
        ).readAsBytes();
        await (FontLoader(
          font.key,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await Directory(directory).create(recursive: true);
      tester.view.physicalSize = Size(width.toDouble(), height.toDouble());
      tester.view.devicePixelRatio = 1;
      debugDisableShadows = false;
      final f = await AttachmentUiFixture.create();
      final boundary = GlobalKey();
      final refresh = ValueNotifier(0);
      Future<void> mount(Widget body, int index) => tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: informationTheme(theme),
            home: Scaffold(
              body: DesktopShell(
                service: f.service,
                port: 0,
                index: index,
                onSelected: (_) {},
                hasBackups: false,
                colorTheme: theme,
                onThemeChanged: (_) {},
                child: body,
              ),
            ),
          ),
        ),
      );
      Future<void> capture(String state) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$directory/$state.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }

      try {
        final session = f.service.agent.openSession('填写求职网站个人资料');
        final request = f.service.agent.request(
          session,
          '阅读简历，填写个人资料并上传简历文件。',
          f.item.fields.map((field) => FieldRef(f.item.id, field.id)).toList(),
        );
        await mount(Approvals(service: f.service, port: 0), 0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('field-${f.item.fields[1].id}')));
        await capture('approval-pending');
        await tester.tap(find.byKey(const ValueKey('approve-selection')));
        await tester.pumpAndSettle();
        await f.fetch(session, request.id, 'COPY-01');
        await f.replace([1, 2, 3, 4]);
        await f.fetch(session, request.id, 'COPY-02');
        final history = await f.owner.history();
        await mount(
          AuthorizationHistory(
            owner: f.owner,
            initialRecordId: history.grants.single.id,
            refresh: refresh,
          ),
          3,
        );
        await capture('history-scope');
        await tester.tap(find.textContaining('访问与交付'));
        await capture('history-deliveries');
        f.driver.blocked = true;
        f.owner.revoke(request.id);
        await f.service.agent.drainInformationFileDeliveries();
        refresh.value++;
        await capture('history-cleanup-pending');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        refresh.dispose();
        await f.close();
        debugDisableShadows = true;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  });
}
