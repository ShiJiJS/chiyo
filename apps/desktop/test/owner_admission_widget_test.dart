import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_storage/info_storage.dart';
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _Keys implements DatabaseKeyStore {
  List<int>? key;
  @override
  Future<List<int>?> read() async => key;
  @override
  Future<void> create(List<int> value) async => key = List.of(value);
}

void main() {
  testWidgets(
    'real owner page distinguishes approved waiting from saved and shows a rejected dependency',
    (t) async {
      t.view.physicalSize = const Size(1440, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      late Directory root;
      late EncryptedInformationRepository repo;
      late core.InformationService service;
      late OwnerWorkspaceSource library;
      late OwnerWorkspaceProposals source;
      late ProposalsController model;
      late String target, dependent;
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('owner-admission-ui-');
        repo = await EncryptedInformationRepository.open(root.path, _Keys());
        service = core.InformationService(repository: repo);
        service.owner.configureInformationTemplates(
          () => currentAgentTemplates(service.owner),
        );
        source = OwnerWorkspaceProposals(
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
        final template =
            (service.agent.readInformationTemplate('document')['template']
                as Map);
        core.ImportItemInput input(String key, {String? targetProposal}) =>
            core.ImportItemInput(
              key == 'target' ? '维护说明乙' : '维护说明甲',
              '',
              [],
              key: key,
              templateId: 'document',
              templateVersion: template['version'] as String,
              templateDigest: template['digest'] as String,
              values: {'bodyFormat': 'plain', 'body': '合成维护内容。'},
              pendingRelations: {
                if (targetProposal != null)
                  'related': [
                    core.ImportPendingReference(
                      'information',
                      'target',
                      proposalId: targetProposal,
                    ),
                  ],
              },
            );
        final session = service.agent.openSession('合成界面测试');
        target = await service.agent.submitImport(session, [input('target')]);
        dependent = await service.agent.submitImport(session, [
          input('dependent', targetProposal: target),
        ]);
        await model.open(dependent);
      });
      Future<void> settle() async {
        for (var i = 0; i < 100; i++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump(const Duration(milliseconds: 10));
          if (!model.busy && !model.loading && !model.reading) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('Owner admission page did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ProposalsPage(controller: model, onRecord: (_) {}),
          ),
        ),
      );
      await settle();
      expect(find.text('维护说明乙（待入库）'), findsOneWidget);
      final approve = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(approve);
      await t.tap(approve);
      await settle();
      expect(model.writeFailure, isNull);
      expect(model.uncertain, false);
      expect(service.owner.information, isEmpty);
      expect(model.detail!.summary.status, WorkspaceProposalStatus.awaiting);
      expect(find.text('已批准待入库'), findsWidgets);
      expect(find.textContaining('已批准，等待'), findsWidgets);
      await t.runAsync(() async {
        await service.owner.rejectImport(target, 1);
        await model.open(dependent);
      });
      await settle();
      expect(
        model.detail!.summary.status,
        WorkspaceProposalStatus.needsAttention,
      );
      expect(find.text('需要处理'), findsWidgets);
      expect(find.textContaining('已被拒绝'), findsWidgets);
      expect(
        service.owner.importProposals
            .singleWhere((p) => p.id == dependent)
            .approvedKeys,
        {'dependent'},
      );
      late String modification, material, originalId;
      await t.runAsync(() async {
        final session = service.agent.openSession('修改界面验收');
        final template =
            service.agent.readInformationTemplate('document')['template']
                as Map;
        core.ImportItemInput document(String key) => core.ImportItemInput(
          key,
          '',
          [],
          key: key,
          templateId: 'document',
          templateVersion: template['version'] as String,
          templateDigest: template['digest'] as String,
          values: {'bodyFormat': 'plain', 'body': '原合成正文'},
        );
        final initial = await service.agent.submitImport(session, [
          document('existing'),
        ]);
        originalId = (await service.owner.confirmImport(
          initial,
          1,
          service.owner.importProposals
              .singleWhere((p) => p.id == initial)
              .items,
        )).single.id;
        material = await service.agent.submitImport(session, [
          document('material'),
        ]);
        modification = await service.agent.submitUpdate(
          session,
          core.UpdateInput(
            originalId,
            1,
            [],
            templateId: 'document',
            templateVersion: template['version'] as String,
            templateDigest: template['digest'] as String,
            values: {'bodyFormat': 'plain', 'body': '新合成正文'},
            pendingRelations: {
              'related': [
                core.ImportPendingReference(
                  'information',
                  'material',
                  proposalId: material,
                ),
              ],
            },
          ),
        );
        await model.open(modification);
      });
      await settle();
      expect(model.detail!.summary.kind, WorkspaceProposalKind.modification);
      expect(find.text('material（待入库）'), findsWidgets);
      final approveModification = find.byKey(
        const ValueKey('proposal-confirm'),
      );
      await t.ensureVisible(approveModification);
      await t.tap(approveModification);
      await settle();
      expect(model.uncertain, false);
      expect(model.writeFailure, isNull);
      expect(model.detail!.summary.status, WorkspaceProposalStatus.awaiting);
      expect(find.textContaining('原内容尚未改变'), findsWidgets);
      expect(
        service.owner.information
            .singleWhere((i) => i.id == originalId)
            .version,
        1,
      );
      await t.runAsync(() async {
        final pending = service.owner.importProposals.singleWhere(
          (p) => p.id == material,
        );
        await service.owner.confirmImport(
          material,
          pending.version,
          pending.items,
        );
        await model.open(modification);
      });
      await settle();
      expect(model.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(
        service.owner.information
            .singleWhere((i) => i.id == originalId)
            .fields
            .singleWhere((f) => f.name == '正文')
            .value,
        '新合成正文',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      model.dispose();
      await t.runAsync(() async {
        await library.dispose();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
    },
  );
}
