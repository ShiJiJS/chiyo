// Opt-in screenshots of production widgets, with Memory storage and fake bytes.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/approvals.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/history.dart';
import 'package:info_desktop/ui.dart';
import '../test/support/information_attachment_fixture.dart';

void main() {
  const directory = String.fromEnvironment('REMOVED_FIELD_RENDER_DIRECTORY');
  const focused200 = bool.fromEnvironment('REMOVED_FIELD_RENDER_FOCUSED_200');
  if (directory.isEmpty) return;
  testWidgets(
    'inspect recorded names and current history scope in the existing shell',
    (tester) async {
      await tester.runAsync(() async {
        for (final family in ['ProductSans', 'AppSans']) {
          await (FontLoader(family)..addFont(
                rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'),
              ))
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
        tester.view.devicePixelRatio = 1;
        debugDisableShadows = false;
        try {
          for (final theme in DesktopColorTheme.values) {
            if (focused200 && theme != DesktopColorTheme.purple) {
              continue;
            }
            final f = await AttachmentUiFixture.create();
            try {
              final session = f.service.agent.openSession('处理虚构求职资料');
              final ref = FieldRef(f.item.id, f.item.fields.last.id);
              final request = f.service.agent.request(
                session,
                '读取简历文件，核对删除与恢复后的授权范围',
                [ref],
              );
              f.owner.approve(request.id, [ref]);
              final grant = (await f.owner.history()).grants.single;
              final entry = await f.owner.deleteInformation(
                f.item.id,
                f.item.version,
                fieldId: ref.fieldId,
              );
              await f.owner.restoreRecycled(entry.id);
              final boundary = GlobalKey();
              Future<void> capture(
                String state,
                Widget body,
                int index, {
                int width = 1280,
                double scale = 1,
              }) async {
                if (focused200 &&
                    (scale != 2 || !state.startsWith('history-'))) {
                  return;
                }
                tester.view.physicalSize = Size(
                  width.toDouble(),
                  width == 1280 ? 800 : 900,
                );
                tester.platformDispatcher.textScaleFactorTestValue = scale;
                await tester.pumpWidget(
                  RepaintBoundary(
                    key: boundary,
                    child: MaterialApp(
                      key: UniqueKey(),
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
                await tester.pumpAndSettle();
                if (scale == 2 && state.startsWith('history-')) {
                  final label = switch (state) {
                    'history-removed' => '原字段已移除',
                    'history-archived' => '历史归档 · 未授权',
                    'history-partial' => '部分字段已移除',
                    _ => throw StateError('Unknown focused history state'),
                  };
                  await tester.ensureVisible(find.text(label));
                  await tester.pumpAndSettle();
                }
                expect(tester.takeException(), isNull);
                final image =
                    await (boundary.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage(pixelRatio: 1);
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await File(
                    '$directory/${theme.name}-$state-$width-${(scale * 100).round()}.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              }

              Widget approval() => Approvals(
                service: f.service,
                port: 0,
                focusRequestId: request.id,
              );
              Widget history(String id) =>
                  AuthorizationHistory(owner: f.owner, initialRecordId: id);
              await capture('approval-removed', approval(), 0);
              await capture('history-removed', history(grant.id), 3);
              if (theme == DesktopColorTheme.purple) {
                await capture('approval-removed', approval(), 0, scale: 2);
                await capture(
                  'history-removed',
                  history(grant.id),
                  3,
                  scale: 2,
                );
                await capture('approval-removed', approval(), 0, width: 1440);
                await capture(
                  'history-removed',
                  history(grant.id),
                  3,
                  width: 1440,
                );
                await f.repository.saveGrantHistory(
                  grant.asRestored(DateTime.utc(2026, 10, 20)),
                );
                await capture('history-archived', history(grant.id), 3);
                await capture(
                  'history-archived',
                  history(grant.id),
                  3,
                  scale: 2,
                );
                final current = f.owner.information.single;
                final mixed = [
                  FieldRef(current.id, current.fields.first.id),
                  FieldRef(current.id, current.fields.last.id),
                ];
                final mixedRequest = f.service.agent.request(
                  session,
                  '姓名仍可读取，原简历字段已移除',
                  mixed,
                );
                f.owner.approve(mixedRequest.id, mixed);
                await f.owner.deleteInformation(
                  current.id,
                  current.version,
                  fieldId: mixed.last.fieldId,
                );
                final mixedGrant = (await f.owner.history()).grants.singleWhere(
                  (g) => g.requestId == mixedRequest.id,
                );
                await capture('history-partial', history(mixedGrant.id), 3);
                await capture(
                  'history-partial',
                  history(mixedGrant.id),
                  3,
                  scale: 2,
                );
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              await f.close();
            }
          }
        } finally {
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDisableShadows = true;
        }
      });
    },
  );
}
