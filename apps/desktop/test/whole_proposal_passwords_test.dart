import 'dart:convert';
import 'dart:io';
import 'package:info_storage/info_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_proposal_password_input.dart';
import 'package:info_desktop/workspace/owner_workspace_proposals.dart';
import 'package:info_desktop/workspace/owner_workspace_source.dart';
import 'package:info_desktop/workspace/proposals_controller.dart';
import 'package:info_desktop/workspace/proposals_page.dart';
import 'package:info_desktop/workspace/workspace_source.dart';
import 'package:info_desktop/workspace/zhiyu_theme.dart';

class _FailOnce implements WorkspaceProposalSource {
  _FailOnce(this.inner);
  final WorkspaceProposalSource inner;
  bool fail = true;
  final counts = <int>[];
  @override
  Future<WorkspaceProposalReceipt> change(WorkspaceProposalChange c) {
    counts.add(c.reviewed.length);
    if (fail) {
      fail = false;
      throw const WorkspaceFailure('disk_full', '存储空间不足，输入仍保留');
    }
    return inner.change(c);
  }

  @override
  Future<WorkspaceProposalResults> query(
    WorkspaceProposalQuery q, {
    String? keepSelection,
  }) => inner.query(q, keepSelection: keepSelection);
  @override
  Future<WorkspaceProposalDetail> read(String id) => inner.read(id);
  @override
  Future<WorkspaceProposalReceipt?> receipt(String id) => inner.receipt(id);
  @override
  Future<WorkspaceCatalog> catalog() => inner.catalog();
  @override
  WorkspaceRelationSource relations(String id, String item, int version) =>
      inner.relations(id, item, version);
  @override
  Future<WorkspaceArchive> snapshot(String id, WorkspaceRecordRef ref) =>
      inner.snapshot(id, ref);
  @override
  Future<WorkspaceDetail> currentTarget(String id) => inner.currentTarget(id);
}

class _Keys implements DatabaseKeyStore {
  List<int>? value;
  @override
  Future<List<int>?> read() async => value;
  @override
  Future<void> create(List<int> key) async {
    value = List.of(key);
  }
}

void main() {
  testWidgets(
    'all passwords stay private across tabs and failure, then one save admits the whole proposal',
    (t) async {
      t.view.physicalSize = const Size(1440, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('whole-passwords-'),
      ))!;
      final repo = (await t.runAsync(
        () => EncryptedInformationRepository.open(root.path, _Keys()),
      ))!;
      final service = (await t.runAsync(
        () async => core.InformationService(repository: repo),
      ))!;
      final templates = currentAgentTemplates(service.owner);
      service.owner.configureInformationTemplates(() => templates);
      final session = service.agent.openSession('合成整份保存');
      core.ImportItemInput password(String key) {
        final template = templates.templates.singleWhere(
          (t) => t.id == 'credential.accountPassword',
        );
        return core.ImportItemInput(
          key,
          '合成测试服务',
          [],
          key: key,
          templateId: template.id,
          templateVersion: template.version,
          templateDigest: template.digest,
          credential: core.CredentialImportInput.owner(),
        );
      }

      final id = (await t.runAsync(
        () => service.agent.submitImport(session, [
          password('first'),
          password('second'),
          core.ImportItemInput('说明', '', [
            const core.FieldInput('正文', '', '合成说明'),
          ], key: 'note'),
        ]),
      ))!;
      late OwnerWorkspaceSource library;
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
      final port = _FailOnce(source);
      final model = ProposalsController(port, library.changes);
      final passwords = OwnerProposalPasswords(service.owner);
      await t.runAsync(() => model.open(id));
      Future<void> settle() async {
        for (var i = 0; i < 200; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await t.pump(const Duration(milliseconds: 10));
          if (!model.busy && !model.loading && !model.reading) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('Whole proposal did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Scaffold(
            body: ProposalsPage(
              controller: model,
              passwords: passwords,
              onRecord: (_) => fail('Preview must stay in the proposal'),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final first = model.detail!.items[0].id,
          second = model.detail!.items[1].id;
      Finder input(String item) =>
          find.byKey(ValueKey('proposal-owner-password-$item'));
      Future<void> tab(String item) async {
        final f = find.byKey(ValueKey('proposal-tab-$item'));
        await t.ensureVisible(f);
        await t.tap(f);
        await t.pumpAndSettle();
      }

      await t.ensureVisible(input(first));
      await t.enterText(input(first), 'SYNTHETIC-FIRST');
      await t.pumpAndSettle();
      expect(model.canConfirm, false);
      await tab(second);
      expect(input(first), findsNothing);
      await t.ensureVisible(input(second));
      await t.enterText(input(second), 'SYNTHETIC-SECOND');
      await t.pumpAndSettle();
      expect(model.canConfirm, true);
      expect(model.canQueueConfirm, false);
      expect(model.queueForBatch(WorkspaceProposalAction.confirm), false);
      expect(repo.managedCredentials, isEmpty);
      expect(repo.items, isEmpty);
      await tab(first);
      final field = t.widget<TextField>(
        find.descendant(of: input(first), matching: find.byType(TextField)),
      );
      expect(field.controller!.text, 'SYNTHETIC-FIRST');
      expect(field.obscureText, true);
      final save = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(save);
      await t.tap(save);
      await settle();
      expect(model.writeFailure?.code, 'disk_full');
      expect(repo.managedCredentials, isEmpty);
      expect(repo.items, isEmpty);
      await tab(second);
      expect(
        t
            .widget<TextField>(
              find.descendant(
                of: input(second),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'SYNTHETIC-SECOND',
      );
      expect(
        jsonEncode(service.agent.importStatus(session, id)),
        isNot(contains('SYNTHETIC-')),
      );
      expect(
        jsonEncode(model.draft!.items.values.map((i) => i.toJson()).toList()),
        isNot(contains('SYNTHETIC-')),
      );
      await t.ensureVisible(save);
      await t.tap(save);
      await settle();
      expect(
        model.writeFailure,
        isNull,
        reason: '${model.writeFailure?.code}: ${model.writeFailure?.message}',
      );
      expect(port.counts, [3, 3]);
      expect(repo.managedCredentials, hasLength(2));
      expect(repo.items, hasLength(1));
      expect(model.detail!.summary.status, WorkspaceProposalStatus.completed);
      expect(service.owner.credentialUseRequests, isEmpty);
      expect(
        passwords.ready(
          id,
          service.owner.importProposals.single.version,
          first,
        ),
        false,
      );
      await t.pumpWidget(const SizedBox());
      model.dispose();
      passwords.dispose();
      await t.runAsync(() async {
        await library.dispose();
        await service.close();
        await repo.close();
        await root.delete(recursive: true);
      });
    },
  );
}
