import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';
import 'capture_credential_use.dart' show loadCredentialUseFonts;

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = key;
}

class _Files extends BackupFilePicker {
  const _Files(this.root);
  final String root;
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
  @override
  Future<String?> recoveryKeyInput() async => '$root/recovery.txt';
  @override
  Future<String?> recoveryKeyOutput() async => null;
  @override
  Future<String?> backupOutput() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadCredentialUseFonts);
  for (final theme in DesktopColorTheme.values) {
    for (final width in [1440, 1280]) {
      testWidgets('credential backup and migration ${theme.name} $width', (
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
          final root = await Directory.systemTemp.createTemp(
            'synthetic-backup-capture-',
          );
          var repo = await EncryptedInformationRepository.open(
            '${root.path}/source',
            _Keys(),
          );
          var service = InformationService(repository: repo);
          final boundary = GlobalKey(), files = _Files(root.path);
          Future<void> mount() async {
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: InformationApp(
                  key: UniqueKey(),
                  service: service,
                  port: 0,
                  backups: repo.backups,
                  backupFiles: files,
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          Future<void> capture(String name) async {
            expect(tester.takeException(), isNull);
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final bitmap = await render.toImage(pixelRatio: 1),
                data = await bitmap.toByteData(format: ui.ImageByteFormat.png);
            final output = Directory(
              '../../docs/development/evidence/31-backup-migration/r2',
            );
            await output.create(recursive: true);
            await File(
              '${output.path}/${theme.name}-$width-$name.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            bitmap.dispose();
          }

          Future<void> bottom() async {
            final scroll = tester
                .stateList<ScrollableState>(find.byType(Scrollable))
                .last;
            scroll.position.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
          }

          Future<void> openBackup() async {
            await tester.tap(find.byKey(const ValueKey('nav-4')));
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('settings-section-backups')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('查看恢复步骤'));
            await tester.pumpAndSettle();
          }

          try {
            await service.owner.setColorTheme(theme);
            final item = await service.owner
                .createInformation('文档服务', '北辰项目文档站与部署入口。', [
                  const FieldInput('访问地址', '', 'https://docs.beichen.example'),
                  const FieldInput('访问令牌', '', 'synthetic-capture-token-v1'),
                ]);
            final ref = FieldRef(item.id, item.fields.last.id);
            await service.owner.correctValue(ref, 'synthetic-capture-token-v2');
            final session = service.agent.openSession('部署北辰文档站'),
                request = service.agent.request(session, '检查部署入口', [ref]);
            service.owner.approve(request.id, [ref]);
            await service.owner.createStringCredential(
              name: '文档站发布 Token',
              publicPurpose: '用于文档站部署',
              secret: 'synthetic-only',
            );
            await service.owner.createFileCredential(
              name: '北辰测试 SSH 私钥',
              publicPurpose: '仅合成数据',
              fileName: 'synthetic.key',
              bytes: [0, 128, 255, 10],
            );
            await repo.backups.enable();
            await repo.backups.saveRecoveryKeyTo('${root.path}/recovery.txt');
            await service.owner.exportLibrary(
              () => repo.backups.exportTo('${root.path}/export.aimbackup'),
            );
            await mount();
            await tester.tap(find.byKey(const ValueKey('nav-1')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('文档服务').first);
            await tester.pumpAndSettle();
            await tester.tap(find.text('转换旧秘密字段'));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('migration-field')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('访问令牌').last);
            await tester.pumpAndSettle();
            await capture('migration');
            if (width == 1280) {
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              await tester.pumpAndSettle();
              await capture('migration-200-first');
              await bottom();
              await capture('migration-200-bottom');
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            await openBackup();
            await capture('backup-ready');
            if (width == 1280) {
              tester.platformDispatcher.textScaleFactorTestValue = 2;
              await tester.pumpAndSettle();
              await capture('backup-200-first');
              await bottom();
              await capture('backup-200-bottom');
              tester.platformDispatcher.clearTextScaleFactorTestValue();
              await tester.pumpAndSettle();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await service.close();
            await repo.close();
            repo = await EncryptedInformationRepository.open(
              '${root.path}/target',
              _Keys(),
            );
            service = InformationService(repository: repo);
            await service.owner.setColorTheme(theme);
            await mount();
            await openBackup();
            await tester.tap(find.byKey(const ValueKey('backup-select-file')));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('backup-select-key')));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('检查备份与恢复密钥'));
            await tester.tap(find.text('检查备份与恢复密钥'));
            for (
              var i = 0;
              i < 100 && find.text('恢复预览').evaluate().isEmpty;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
            await tester.pumpAndSettle();
            expect(find.text('恢复预览'), findsOneWidget);
            await tester.ensureVisible(find.text('恢复预览'));
            await tester.pumpAndSettle();
            await capture('restore-preview');
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await service.close();
            await repo.close();
            await root.delete(recursive: true);
            debugDisableShadows = true;
          }
        });
      });
    }
  }
}
