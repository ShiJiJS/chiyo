import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/backups.dart';
import 'package:info_desktop/ui.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async {
    key = List.of(value);
  }
}

void main() {
  testWidgets(
    'backup flow keeps real first enable and both restore file controls together',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('backup-flow-');
        repo = await EncryptedInformationRepository.open(root.path, _Keys());
      });
      final service = InformationService(repository: repo);

      await tester.pumpWidget(
        MaterialApp(
          theme: informationTheme(),
          home: Scaffold(
            body: BackupLibrary(backups: repo.backups, owner: service.owner),
          ),
        ),
      );
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.tap(find.text('导出加密备份'));
      await tester.pumpAndSettle();
      expect(find.text('首次启用备份'), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-select-file')), findsOneWidget);
      expect(find.byKey(const ValueKey('backup-select-key')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await tester.runAsync(() async {
        await repo.close();
        await root.delete(recursive: true);
      });
    },
  );
}
