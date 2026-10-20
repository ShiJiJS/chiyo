import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import '../test/credential_reuse_widget_test.dart' show operation;
import '../test/credential_use_widget_test.dart' show fixture;
import 'capture_credential_use.dart' show loadCredentialUseFonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  for (final theme in DesktopColorTheme.values) {
    for (final width in [1440, 1280]) {
      testWidgets('reusable credential ${theme.name} $width', (tester) async {
        debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = true);
        tester.view.physicalSize = Size(
          width.toDouble(),
          width == 1440 ? 900 : 800,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          var now = DateTime(2026, 10, 19, 14, 32);
          final (service, session, request) = await fixture(
            protocolVersion: 2,
            clock: () => now,
            executable: r'C:\Program Files\GitHub CLI\gh.exe',
          );
          final boundary = GlobalKey();
          try {
            await service.owner.setColorTheme(theme);
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: InformationApp(service: service, port: 0),
              ),
            );
            await tester.pumpAndSettle();
            Future<void> capture(String state) async {
              expect(tester.takeException(), isNull);
              final render =
                  boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final bitmap = await render.toImage(pixelRatio: 1),
                  data = await bitmap.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
              final output = Directory('../../build/qa-issue33/flutter-reuse');
              await output.create(recursive: true);
              await File(
                '${output.path}/${theme.name}-$width-$state.png',
              ).writeAsBytes(data!.buffer.asUint8List());
              bitmap.dispose();
            }

            await capture('approval');
            await service.owner.decideCredentialUse(
              request.id,
              approveCredential: true,
              fields: request.fields,
            );
            now = DateTime(2026, 10, 19, 14, 35);
            final first = await service.agent.beginCredentialUseOperation(
              session,
              operation(request, 'OP-01', 'northstar/docs'),
            );
            await service.agent.reportCredentialExecution(
              CredentialExecutionReport(
                executionId: first.execution.id,
                executionCapability: first.material!.executionCapability,
                state: 'start_failed',
                errorCode: 'process_start_failed',
                finishedAt: now.toUtc(),
              ),
            );
            now = DateTime(2026, 10, 19, 14, 37);
            await service.agent.beginCredentialUseOperation(
              session,
              operation(request, 'OP-02', 'northstar/agent-skills'),
            );
            await tester.tap(find.byKey(const ValueKey('nav-3')));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(ValueKey('history-entry-${request.id}')),
            );
            await tester.pumpAndSettle();
            await capture('history');
            if (theme == DesktopColorTheme.purple) {
              await tester.ensureVisible(
                find.byKey(ValueKey('use-operation-${first.execution.id}')),
              );
              await tester.tap(
                find.byKey(ValueKey('use-operation-${first.execution.id}')),
              );
              await tester.pumpAndSettle();
              await tester.ensureVisible(find.text('本次操作未成功'));
              await tester.pumpAndSettle();
              await capture('failed');
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            await service.close();
            debugDisableShadows = true;
          }
        });
      });
    }
  }
}
