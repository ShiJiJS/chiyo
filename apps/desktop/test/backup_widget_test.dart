import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_storage/info_storage.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

class _Files implements BackupFilePicker {
  _Files(this.root);
  final String root;
  @override
  Future<String?> recoveryKeyOutput() async => '$root/recovery.txt';
  @override
  Future<String?> backupOutput() async => '$root/export.aimbackup';
  @override
  Future<String?> backupInput() async => '$root/export.aimbackup';
}

Future<void> _settleIO(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (target.evaluate().isNotEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      break;
    }
    if (target.evaluate().isNotEmpty &&
        find.byType(AlertDialog).evaluate().isNotEmpty) {
      break;
    }
  }
  expect(target, findsWidgets);
}

void main() {
  testWidgets(
    'owner enables backup and separately saves key before exporting',
    (tester) async {
      late final Directory root;
      EncryptedInformationRepository? repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('backup-widget-');
        repository = await EncryptedInformationRepository.open(
          '${root.path}/library',
          _Keys(),
        );
      });
      final files = _Files(root.path);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackupLibrary(backups: repository!.backups, files: files),
          ),
        ),
      );
      await _settleIO(tester, find.text('启用手动备份'));
      await tester.tap(find.text('启用手动备份'));
      await _settleIO(tester, find.text('请另行保存恢复密钥'));
      await tester.tap(find.text('保存恢复密钥文件'));
      await _settleIO(tester, find.text('恢复密钥已另存，请与备份分开保管。'));
      expect(File('${root.path}/recovery.txt').existsSync(), isTrue);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出加密备份'));
      await _settleIO(tester, find.text('加密备份已导出。'));
      expect(File('${root.path}/export.aimbackup').existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repository!.close();
        await root.delete(recursive: true);
      });
    },
  );
}
