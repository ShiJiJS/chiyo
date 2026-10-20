import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import '../test/credential_use_widget_test.dart' show fixture;
import '../test/support/file_approval_fixture.dart' show fileApprovalFixture;
import 'capture_credential_use.dart' show loadCredentialUseFonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  for (final theme in DesktopColorTheme.values) {
    for (final width in [1440, 1280]) {
      for (final receiver in [
        'token',
        'ssh_identity',
        'aws_shared_credentials',
      ]) {
        if (receiver != 'token' &&
            (theme != DesktopColorTheme.purple || width != 1440)) {
          continue;
        }
        testWidgets('credential history ${theme.name} $width $receiver', (
          tester,
        ) async {
          debugDisableShadows = false;
          addTearDown(() => debugDisableShadows = true);
          tester.view.physicalSize = Size(
            width.toDouble(),
            width == 1440 ? 900 : 800,
          );
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.runAsync(() async {
            final (service, session, request) = receiver == 'token'
                ? await fixture()
                : await fileApprovalFixture(
                    receiver,
                    executable: receiver == 'ssh_identity'
                        ? r'C:\Windows\System32\OpenSSH\ssh.exe'
                        : r'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
                  );
            final boundary = GlobalKey();
            try {
              await service.owner.setColorTheme(theme);
              await service.owner.decideCredentialUse(
                request.id,
                approveCredential: true,
                fields: request.fields,
              );
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: InformationApp(service: service, port: 0),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const ValueKey('nav-3')));
              await tester.pumpAndSettle();
              Future<void> capture(String name) async {
                expect(tester.takeException(), isNull);
                final render =
                    boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary;
                final bitmap = await render.toImage(pixelRatio: 1),
                    data = await bitmap.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                final folder = Directory(
                    '../../docs/development/evidence/30-integration/history-r4',
                );
                await folder.create(recursive: true);
                await File(
                  '${folder.path}/${theme.name}-$width${receiver == 'token' ? '' : '-$receiver'}-$name.png',
                ).writeAsBytes(data!.buffer.asUint8List());
                bitmap.dispose();
              }

              await capture('approved');
              if (theme == DesktopColorTheme.purple) {
                await tester.tap(
                  find.byKey(const ValueKey('history-injection-tip')),
                );
                await tester.pumpAndSettle();
                await capture('tip');
                await tester.tap(
                  find.byKey(const ValueKey('history-injection-tip')),
                );
                await tester.pumpAndSettle();
              }
              final material = await service.agent.consumeCredentialUse(
                session,
                request.id,
              );
              await service.agent.reportCredentialExecution(
                CredentialExecutionReport(
                  executionId: material.executionId,
                  executionCapability: material.executionCapability,
                  state: 'start_failed',
                  errorCode: 'process_start_failed',
                  finishedAt: DateTime.now().toUtc(),
                ),
              );
              await Future<void>.delayed(const Duration(milliseconds: 1050));
              await tester.pump();
              await tester.pumpAndSettle();
              await capture('start-failed');
              if (width == 1280) {
                tester.platformDispatcher.textScaleFactorTestValue = 2;
                await tester.pumpAndSettle();
                await capture('200-first');
                final card = find.byKey(
                  ValueKey('history-document-${request.id}'),
                );
                final scroll = find.descendant(
                  of: card,
                  matching: find.byType(SingleChildScrollView),
                );
                await tester.drag(scroll, const Offset(0, -2000));
                await tester.pumpAndSettle();
                await capture('200-bottom');
              }
            } finally {
              await tester.pumpWidget(const SizedBox());
              await service.owner.reconcileCredentialMaterialCleanup();
              await service.close();
              debugDisableShadows = true;
            }
          });
        });
      }
    }
  }
}
