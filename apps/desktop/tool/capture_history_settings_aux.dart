import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/main.dart';
import 'package:info_desktop/backups.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

class _Files extends BackupFilePicker {
  _Files(this.root);
  final String root;
  @override
  Future<String?> recoveryKeyOutput() async => '$root/recovery.txt';
  @override
  Future<String?> backupOutput() async => '$root/export.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
  @override
  Future<String?> recoveryKeyInput() async => '$root/recovery.txt';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'ProductSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
    await (FontLoader(
      'AppSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Regular.otf'))).load();
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
  });
  for (final size in [const Size(1440, 900), const Size(1280, 800)]) {
    testWidgets('reviewed settings auxiliary surfaces ${size.width.toInt()}', (
      tester,
    ) async {
      debugDisableShadows = false;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(() => debugDisableShadows = true);
      final boundary = GlobalKey();
      late Directory root;
      late EncryptedInformationRepository source, recipient;
      late InformationService sourceService, target;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('aim-settings-visual-');
        source = await EncryptedInformationRepository.open(
          '${root.path}/source',
          _Keys(),
        );
        recipient = await EncryptedInformationRepository.open(
          '${root.path}/recipient',
          _Keys(),
        );
        sourceService = InformationService(repository: source);
        target = InformationService(repository: recipient);
        for (var i = 0; i < 12; i++) {
          await sourceService.owner.createInformation(
            i == 0 ? '文档服务' : '项目资料 $i',
            '',
            const [FieldInput('访问地址', '', 'fictional.invalid')],
          );
        }
        await sourceService.owner.createTemplate('服务器', '', const [
          TemplateFieldInput('地址', ''),
          TemplateFieldInput('用户名', ''),
          TemplateFieldInput('端口', ''),
          TemplateFieldInput('部署备注', ''),
        ]);
        await sourceService.owner.createTemplate('网站账号', '', const [
          TemplateFieldInput('网站地址', ''),
          TemplateFieldInput('用户名', ''),
        ]);
        final item = sourceService.owner.information.first;
        final ref = FieldRef(item.id, item.fields.single.id);
        final session = sourceService.agent.openSession('Codex');
        final request = sourceService.agent.request(session, '核对文档部署', [ref]);
        sourceService.owner.approve(request.id, [ref]);
        await sourceService.agent.read(
          sourceService.agent.claim(session, request.id).token,
          ref,
        );
      });
      Future<void> io([Finder? targetFinder]) async {
        for (var i = 0; i < 120; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 50));
          if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              (targetFinder == null || targetFinder.evaluate().isNotEmpty)) {
            return;
          }
        }
        if (targetFinder != null) expect(targetFinder, findsWidgets);
      }

      Future<void> mount(
        InformationService service, {
        InformationBackups? backups,
        String mode = 'default',
      }) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: InformationApp(
              key: ValueKey(mode),
              service: service,
              port: 0,
              backups: backups,
              backupFiles: _Files(root.path),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> capture(String name) async {
        await io();
        await tester.pumpAndSettle();
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final picture = await render.toImage(pixelRatio: 1),
              bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../docs/development/evidence/26-history-settings/${const String.fromEnvironment('AUX_EVIDENCE_DIRECTORY', defaultValue: 'aux-r2')}/$name-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
        expect(tester.takeException(), isNull, reason: name);
      }

      Future<void> settings(String section) async {
        await tester.ensureVisible(find.byKey(const ValueKey('nav-4')));
        await tester.tap(find.byKey(const ValueKey('nav-4')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(ValueKey('settings-section-$section')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('settings-section-$section')));
        await io();
      }

      await mount(sourceService, backups: source.backups);
      await settings('templates');
      await capture('settings-templates');
      await tester.tap(find.text('修改模板'));
      await capture('settings-template-dialog');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存模板'));
      await capture('settings-template-error');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await settings('notifications');
      await capture('settings-notifications');
      await settings('records');
      await capture('settings-records');
      await tester.tap(find.byKey(const ValueKey('retention-90')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 天').last);
      await capture('settings-retention');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await settings('backups');
      await capture('settings-backups');
      await tester.tap(find.text('导出加密备份'));
      await capture('settings-backup-flow');
      await tester.tap(find.text('检查备份与恢复密钥'));
      await capture('settings-backup-error');
      await tester.tap(find.text('创建恢复密钥'));
      await io(find.text('保存恢复密钥文件'));
      await tester.tap(find.text('保存恢复密钥文件'));
      await io(find.text('恢复密钥已另存，请与备份分开保管。'));
      await tester.tap(
        find.descendant(
          of: find.byType(BackupFlowDialog),
          matching: find.text('导出加密备份'),
        ),
      );
      await io(find.text('加密备份已导出。'));
      await tester.runAsync(() async {
        await recipient.backups.enable();
        await recipient.backups.saveRecoveryKeyTo(
          '${root.path}/recipient/recovery.txt',
        );
      });
      await mount(target, backups: recipient.backups, mode: 'recipient');
      await settings('backups');
      await capture('settings-backups-empty');
      await tester.tap(find.text('查看恢复步骤'));
      await io(find.text('恢复密钥已另存'));
      await tester.tap(find.byKey(const ValueKey('backup-select-file')));
      await io(find.text('export.aimbackup'));
      await tester.tap(find.byKey(const ValueKey('backup-select-key')));
      await io(find.text('recovery.txt'));
      await tester.tap(find.text('检查备份与恢复密钥'));
      await io(find.text('恢复预览'));
      await capture('settings-restore-preview');
      await tester.ensureVisible(find.text('确认恢复到空库'));
      await tester.pumpAndSettle();
      await capture('settings-restore-preview-bottom');
      await tester.tap(find.text('确认恢复到空库'));
      await io(find.text('资料已恢复，请到“信息库”查看。Agent 需要重新申请访问。'));
      await capture('settings-restore-complete');
      await tester.tap(find.text('×'));
      await tester.pumpAndSettle();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await settings('records');
      await capture('settings-records-200');
      await tester.tap(find.byKey(const ValueKey('timeout-30')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 小时').last);
      await io();
      expect(target.owner.requestLifetime, const Duration(hours: 1));
      await capture('settings-records-200-changed');
      await settings('templates');
      await tester.tap(find.text('新建模板'));
      await capture('settings-template-200');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await mount(target, backups: recipient.backups, mode: 'backup-200');
      await settings('backups');
      await tester.ensureVisible(find.text('查看恢复步骤'));
      await tester.tap(find.text('查看恢复步骤'));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await capture('settings-backup-flow-200');
      await tester.ensureVisible(find.text('检查备份与恢复密钥'));
      await capture('settings-backup-flow-bottom-200');
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final closing = Future.wait([
        target.close(),
        sourceService.close(),
      ]).whenComplete(() => closed = true);
      for (var i = 0; i < 200 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await closing;
      await tester.runAsync(() async {
        await source.close();
        await recipient.close();
        await root.delete(recursive: true);
      });
      debugDisableShadows = true;
    });
  }
}
