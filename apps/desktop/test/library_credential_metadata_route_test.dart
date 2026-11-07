import 'dart:io';
import 'package:info_storage/info_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/zhiyu_theme.dart';
import 'package:info_desktop/workspace/library_controller.dart';
import 'package:info_desktop/workspace/library_page.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/workspace_source.dart';

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
    'library Edit information saves credential metadata without replacing material',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('credential-route-'),
      ))!;
      final repo = (await t.runAsync(
        () => EncryptedInformationRepository.open(root.path, _Keys()),
      ))!;
      final service = core.InformationService(repository: repo);
      final credential = (await t.runAsync(
        () => service.owner.createStringCredential(
          name: '合成登录凭据',
          publicPurpose: '待填写',
          secret: 'SYNTHETIC-MATERIAL-ONLY',
          suggestedBinding: 'ACCOUNT_PASSWORD',
        ),
      ))!;
      final source = OwnerWorkspaceSource(
        owner: service.owner,
        refreshInterval: Duration.zero,
      );
      final model = LibraryController(source);
      await t.runAsync(
        () => model.load(
          const WorkspaceQuery(),
          keepSelection: WorkspaceRecordRef(
            WorkspaceRecordKind.credential,
            credential.id,
          ),
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: LibraryPage(controller: model, onNavigate: (_, _) {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('编辑信息').first);
      await t.pumpAndSettle();
      for (var n = 0; n < 100 && find.text('编辑凭据').evaluate().isEmpty; n++) {
        await t.pump(const Duration(milliseconds: 10));
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(
        find.text('编辑凭据'),
        findsOneWidget,
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' / '),
      );
      await t.enterText(
        find.byKey(const ValueKey('credential-edit-purpose')),
        '网页登录。',
      );
      await t.pump();
      final save = find.byKey(const ValueKey('credential-edit-save'));
      await t.ensureVisible(save);
      await t.tap(save);
      for (
        var n = 0;
        n < 100 && service.owner.credentials.single.publicPurpose != '网页登录。';
        n++
      ) {
        await t.pump(const Duration(milliseconds: 10));
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      await t.pumpAndSettle();
      final current = service.owner.credentials.single;
      expect(current.id, credential.id);
      expect(current.version, credential.version);
      expect(current.useGeneration, credential.useGeneration);
      expect(
        current.publicPurpose,
        '网页登录。',
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' / '),
      );
      expect(find.text('请通过凭据管理入口操作。'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      model.dispose();
      await t.runAsync(source.dispose);
      await t.runAsync(service.close);
      await t.runAsync(repo.close);
      await t.runAsync(() => root.delete(recursive: true));
    },
  );
}
