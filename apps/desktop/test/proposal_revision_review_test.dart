import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async => value = List.of(key);
}

void main() {
  testWidgets(
    'real Agent revision can be reviewed again in the App without another proposal or stale Owner edits',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.InformationService service;
      late OwnerWorkspaceSource library;
      late ProposalsController model;
      late String session, id;
      core.ImportItemInput input(String name, String body) =>
          core.ImportItemInput(name, '资料的来源说明', [
            core.FieldInput('内容', '', body, kind: core.FieldKind.textNote),
          ], key: 'note');
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('revised-owner-review-');
        repo = await EncryptedInformationRepository.open(root.path, _Keys());
        service = core.InformationService(repository: repo);
        session = service.agent.openSession('合成修订聊天');
        id = await service.agent.submitImport(session, [input('初稿', '旧正文')]);
        final source = OwnerWorkspaceProposals(
          owner: service.owner,
          library: () => library,
          changed: () => library.notifyExternalChange(),
        );
        library = OwnerWorkspaceSource(
          owner: service.owner,
          proposals: source,
          refreshInterval: Duration.zero,
        );
        model = ProposalsController(source, library.changes);
        await model.open(id);
      });
      addTearDown(() async {
        model.dispose();
        await t.runAsync(() async {
          await library.dispose();
          await service.close();
          await repo.close();
          await root.delete(recursive: true);
        });
      });
      Future<void> settle() async {
        for (var i = 0; i < 200; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await t.pump(const Duration(milliseconds: 10));
          if (!model.busy && !model.loading && !model.reading) {
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
            return;
          }
        }
        fail('Revised proposal did not settle');
      }

      Future<void> tap(String key) async {
        final f = find.byKey(ValueKey(key));
        await t.ensureVisible(f);
        await t.tap(f);
        await settle();
      }

      final old = model.draft!.items.values.single;
      model.editItem(
        id,
        1,
        WorkspaceProposalItemReview(
          itemId: old.itemId,
          name: '主人尚未保存的旧编辑',
          description: old.description,
          values: old.values,
        ),
      );
      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ProposalsPage(controller: model, onRecord: (_) {}),
          ),
        ),
      );
      await settle();
      await t.runAsync(() async {
        await service.agent.reviseImport(session, id, 1, [input('修订稿', '新正文')]);
        await model.load();
      });
      await settle();
      expect(model.needsNewReview, true);
      expect(model.canConfirm, false);
      expect(repo.items, isEmpty);
      await tap('proposal-restart-review');
      await t.tap(find.text('保留旧审阅'));
      await settle();
      expect(model.draft!.items.values.single.name, '主人尚未保存的旧编辑');
      expect(model.needsNewReview, true);
      await tap('proposal-restart-review');
      await tap('proposal-restart-review-confirm');
      expect(model.needsNewReview, false);
      expect(model.draft!.version, 2);
      expect(model.draft!.items.values.single.name, '修订稿');
      expect(model.canConfirm, true);
      expect(repo.importProposals, hasLength(1));
      expect(repo.items, isEmpty);
      await tap('proposal-confirm');
      expect(model.writeFailure, isNull);
      expect(repo.items.single.name, '修订稿');
      expect(repo.items.single.fields.single.value, '新正文');
      expect(service.agent.importStatus(session, id)['status'], 'confirmed');
    },
  );
}
