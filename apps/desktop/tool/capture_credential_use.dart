import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';

Future<void> loadCredentialUseFonts() async {
  for (final name in ['ProductSans', 'AppSans']) {
    await (FontLoader(
      name,
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  testWidgets('credential use representative capture', (tester) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = InformationService(
      repository: MemoryInformationRepository(),
      clock: () => DateTime(2026, 10, 17, 14, 40),
      credentialExecutableInspector: (path, receiver) async =>
          ExecutableIdentity(path, 1, 1, 'sha256:capture'),
    );
    var token = await service.owner.createStringCredential(
      name: 'GitHub · 技能仓库 Token',
      publicPurpose: 'API Token',
      secret: 'synthetic-capture',
    );
    token = await service.owner.updateCredentialMetadata(
      token.id,
      token.revision,
      name: token.name,
      publicPurpose: token.publicPurpose,
      privateNote: '',
      suggestedBinding: 'GH_TOKEN',
      discoverable: true,
    );
    final session = service.agent.openSession('检查技能仓库状态');
    final request = (await tester.runAsync(
      () => service.agent.requestCredentialUse(
        session,
        CredentialUseInput.fromJson({
          'command': 'request-use',
          'purpose': '核对仓库信息，为同步技能库做准备。',
          'credentials': [
            {'alias': 'github_token', 'credentialId': token.id, 'version': 1},
          ],
          'launch': {
            'receiver': 'gh_token',
            'executable': r'C:\Program Files\GitHub CLI\gh.exe',
            'argv': ['repo', 'view', 'northstar/agent-skills'],
            'cwd': Directory.current.path,
            'env': {
              'GH_TOKEN': {'secret': 'github_token'},
            },
          },
        }),
      ),
    ))!;
    const key = ValueKey('runtime-capture');
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
              index: 0,
              onSelected: (_) {},
              hasBackups: true,
              onThemeChanged: (_) {},
              child: Approvals(
                service: service,
                port: 0,
                focusRequestId: request.id,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      final picture = await boundary.toImage(pixelRatio: 1);
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('../../docs/development/evidence/28-runtime/r1');
      await output.create(recursive: true);
      await File(
        '${output.path}/purple-1440-pending.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      picture.dispose();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(service.close);
    debugDisableShadows = true;
  });
}
