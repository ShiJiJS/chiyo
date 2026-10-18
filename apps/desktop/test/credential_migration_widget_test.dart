import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart';
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/library.dart';
import 'package:info_desktop/ui.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = key;
}

void main() {
  testWidgets(
    'owner must explicitly choose and confirm a field, sees grant and backup effects, and gets the linked credential',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'synthetic-migration-ui-',
        );
        final repo = await EncryptedInformationRepository.open(
          root.path,
          _Keys(),
        );
        final service = InformationService(repository: repo);
        try {
          final item = await service.owner
              .createInformation('Synthetic server', '', [
                const FieldInput('Selected token', '', 'synthetic-only'),
                const FieldInput('Host', '', 'synthetic.invalid'),
              ]);
          await tester.pumpWidget(
            MaterialApp(
              theme: informationTheme(),
              home: Scaffold(
                body: InformationLibrary(
                  owner: service.owner,
                  initialItemId: item.id,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('转换旧秘密字段'));
          await tester.pumpAndSettle();
          expect(find.textContaining('不会扫描或自动猜测秘密'), findsOneWidget);
          final button = find.byKey(const ValueKey('migration-confirm'));
          expect(tester.widget<TextButton>(button).onPressed, isNull);
          await tester.tap(find.byKey(const ValueKey('migration-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Selected token').last);
          await tester.pumpAndSettle();
          expect(find.textContaining('0 项读取授权'), findsOneWidget);
          expect(find.textContaining('离线备份不会同步擦除'), findsOneWidget);
          await tester.tap(button);
          for (var i = 0; i < 100 && service.owner.credentials.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(service.owner.credentials.single.linkedItemIds, [item.id]);
          expect(service.owner.information.single.fields.single.name, 'Host');
          expect(find.text('将旧字段转为托管凭据'), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await service.close();
          await repo.close();
          await root.delete(recursive: true);
        }
      });
    },
  );
}
