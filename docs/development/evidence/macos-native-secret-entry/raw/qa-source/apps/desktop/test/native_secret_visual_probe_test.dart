import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/credential_dialogs.dart';
import 'package:info_desktop/mac_secret_input.dart';
import 'package:info_desktop/ui.dart';

void main() {
  setUpAll(() async {
    final data = await rootBundle.load('assets/fonts/NotoSansSC-Regular.otf');
    for (final family in ['ProductSans', 'AppSans']) {
      await (FontLoader(family)..addFont(Future.value(data))).load();
    }
  });
  testWidgets('native secret form color and size matrix', (tester) async {
    final phase = Platform.environment['QA_VISUAL_PHASE']!;
    final output = Directory(Platform.environment['QA_VISUAL_OUTPUT']!)..createSync(recursive: true);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('agent_info_manage/secret_editor'),
      (call) async => call.method == 'edit' ? 'SyntheticVisualSecret42' : null,
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('agent_info_manage/secret_editor'), null));
    for (final theme in DesktopColorTheme.values) {
      for (final scale in [1.0, 2.0]) {
        tester.view.physicalSize = scale == 1 ? const Size(1440, 900) : const Size(1280, 800);
        final service = InformationService(repository: MemoryInformationRepository());
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
          theme: informationTheme(theme),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Builder(builder: (context) => Scaffold(body: TextButton(
            onPressed: () => showDialog<void>(context: context, builder: (_) => CredentialEditor(owner: service.owner)),
            child: const Text('open')))),
        )));
        await tester.tap(find.text('open')); await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('credential-name')), '原生安全输入验收');
        final field = find.byKey(const ValueKey('credential-secret'));
        await tester.ensureVisible(field); await tester.pumpAndSettle();
        if (find.byType(MacSecretInput).evaluate().isNotEmpty) {
          await tester.tap(find.descendant(of: field, matching: find.byType(TextButton)));
        } else { await tester.enterText(field, 'SyntheticVisualSecret42'); }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final save = find.byKey(const ValueKey('save-credential'));
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${output.path}/$phase-${theme.name}-${(scale * 100).toInt()}.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox()); await tester.runAsync(service.close);
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
