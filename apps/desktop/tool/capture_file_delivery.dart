import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/settings.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/credential_files.dart';
import 'package:info_desktop/desktop_shell.dart';
import 'package:info_desktop/ui.dart';
import '../test/support/file_approval_fixture.dart';
import 'capture_credential_use.dart' show loadCredentialUseFonts;

class _KnownHostsPicker implements CredentialFilePicker {
  @override
  Future<SelectedCredentialFile?> choose() async =>
      SelectedCredentialFile('北辰测试主机 known_hosts', knownHostBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  for (final theme in DesktopColorTheme.values) {
    for (final width in [1440, 1280]) {
      testWidgets('file delivery ${theme.name} $width', (tester) async {
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
        final boundary = GlobalKey();
        Future<void> capture(String name) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1),
                data = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory(
              '../../docs/development/evidence/29-files/r3',
            );
            await directory.create(recursive: true);
            await File(
              '${directory.path}/${theme.name}-$width-$name.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        Future<void> tap(String label) async {
          final finder = find.text(label);
          await tester.ensureVisible(finder);
          await tester.runAsync(() async {
            await tester.tap(finder);
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pumpAndSettle();
        }

        for (final receiver in ['ssh_identity', 'aws_shared_credentials']) {
          final ssh = receiver == 'ssh_identity';
          final fixture = (await tester.runAsync(
            () => fileApprovalFixture(
              receiver,
              executable: ssh
                  ? r'C:\Windows\System32\OpenSSH\ssh.exe'
                  : r'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
            ),
          ))!;
          final service = fixture.$1;
          await tester.runAsync(() => service.owner.setColorTheme(theme));
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: InformationApp(
                key: UniqueKey(),
                service: service,
                port: 0,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final name = ssh ? 'ssh' : 'aws';
          await capture('$name-pending');
          if (theme == DesktopColorTheme.purple) {
            await tester.tap(find.byKey(const ValueKey('use-tip-injection')));
            await tester.pumpAndSettle();
            await capture('$name-tip');
            await tester.tap(find.byKey(const ValueKey('use-tip-injection')));
            await tester.pumpAndSettle();
            await tap('程序位置与固定计划');
            await capture('$name-plan');
            await tap('程序位置与固定计划');
            await tap('查看申请明细 ↗');
            await capture('$name-request');
            await tap('返回审批');
            await tester.ensureVisible(
              find.byKey(const ValueKey('credential-use-approve')),
            );
            await tester.tap(
              find.byKey(const ValueKey('credential-use-approve')),
            );
            await tester.pumpAndSettle();
            await capture('$name-confirm');
            await tap('返回核对');
          }
          if (theme == DesktopColorTheme.mono ||
              theme == DesktopColorTheme.purple) {
            tester.platformDispatcher.textScaleFactorTestValue = 2;
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: InformationApp(
                  key: UniqueKey(),
                  service: service,
                  port: 0,
                ),
              ),
            );
            await tester.pumpAndSettle();
            await capture('$name-200-top');
            await tester.ensureVisible(find.text('由 CLI 启动什么命令'));
            await tester.pumpAndSettle();
            await capture('$name-200-launch');
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          }
          if (ssh) {
            Future<void> settings() async {
              await tester.pumpWidget(
                RepaintBoundary(
                  key: boundary,
                  child: MaterialApp(
                    theme: informationTheme(theme),
                    debugShowCheckedModeBanner: false,
                    home: Scaffold(
                      body: DesktopShell(
                        service: service,
                        colorTheme: theme,
                        port: 0,
                        index: 4,
                        onSelected: (_) {},
                        hasBackups: true,
                        onThemeChanged: (_) {},
                        child: SettingsPage(
                          owner: service.owner,
                          files: const NativeBackupFilePicker(),
                          sshHostFiles: _KnownHostsPicker(),
                          initialSection: SettingsSection.sshHosts,
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
            }

            await settings();
            await capture('host-settings');
            if (theme == DesktopColorTheme.purple) {
              await tap('替换主机记录');
              await capture('host-confirm');
              await tap('返回核对');
            }
            if (theme == DesktopColorTheme.mono) {
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              await settings();
              await capture('host-settings-200');
              tester.platformDispatcher.clearTextScaleFactorTestValue();
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(service.close);
        }
        debugDisableShadows = true;
      });
    }
  }
}
