import 'dart:convert';
import 'dart:io';
import 'package:info_storage/info_storage.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:info_core/info_core.dart' as core;
import 'package:info_desktop/workspace/owner_agent_templates.dart';
import 'package:info_desktop/workspace/owner_proposal_file_preview.dart';
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
    'file approval shows source versions and independent extras, previews real pending original, and preserves files through owner metadata edits',
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
      late String id;
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('ordinary-owner-ui-');
        repo = await EncryptedInformationRepository.open(root.path, _Keys());
        service = core.InformationService(repository: repo);
        service.owner.configureInformationTemplates(
          () => currentAgentTemplates(service.owner),
        );
        final session = service.agent.openSession('合成原文核对');
        final template =
            service.agent.readInformationTemplate('file')['template'] as Map;
        final example = template['submissionExample'] as Map;
        final submittedItem = Map<String, dynamic>.from(
          (example['items'] as List).single as Map,
        );
        final original = await service.agent.uploadImportFile(
          session,
          operationId: 'current',
          originalName: '简历当前.txt',
          mediaType: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('PRIVATE-CURRENT-ORIGINAL')),
        );
        final revision = await service.agent.uploadImportFile(
          session,
          operationId: 'historical',
          originalName: '简历旧稿.txt',
          mediaType: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('PRIVATE-OLDER-ORIGINAL')),
        );
        submittedItem['key'] = 'resume';
        submittedItem['attachments'] = [
          {
            'key': 'primary',
            'name': '简历原文',
            'templateField': 'file',
            'currentVersion': 1,
            'versions': [
              {
                'uploadId': original.id,
                'label': '确认稿',
                'sourceNote': '文件说明明确标为投递稿。',
              },
              {
                'uploadId': revision.id,
                'label': '早期草稿',
                'sourceNote': '文件中明确注明草稿日期。',
              },
            ],
          },
          {
            'key': 'proof',
            'name': '相关证明',
            'currentVersion': 1,
            'versions': [
              {'uploadId': revision.id},
            ],
          },
        ];
        id = await service.agent.submitImport(session, [
          core.ImportItemInput.fromJson(submittedItem),
        ]);
        final proposals = OwnerWorkspaceProposals(
          owner: service.owner,
          library: () => library,
          changed: () => library.notifyExternalChange(),
        );
        library = OwnerWorkspaceSource(
          owner: service.owner,
          proposals: proposals,
          refreshInterval: Duration.zero,
        );
        model = ProposalsController(proposals, library.changes);
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
        for (var n = 0; n < 200; n++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await t.pump(const Duration(milliseconds: 10));
          if (!model.busy && !model.loading && !model.reading) {
            await t.pumpAndSettle();
            return;
          }
        }
        fail('File review did not settle');
      }

      await t.pumpWidget(
        MaterialApp(
          theme: zhiyuTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: ProposalsPage(
                controller: model,
                onRecord: (_) {},
                onFile: (p, pv, item, a, v) => showOwnerProposalFilePreview(
                  context,
                  service.owner,
                  p,
                  pv,
                  item,
                  a,
                  v,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('确认稿 · 保存为当前版本'), findsOneWidget);
      expect(find.textContaining('早期草稿 · 保留为历史版本'), findsOneWidget);
      expect(find.text('来源依据：文件中明确注明草稿日期。'), findsOneWidget);
      expect(find.text('相关证明'), findsOneWidget);
      expect(find.text('PRIVATE-CURRENT-ORIGINAL'), findsNothing);
      expect(repo.items, isEmpty);
      final preview = find.text('查看这份原文').first;
      await t.ensureVisible(preview);
      await t.tap(preview);
      for (
        var n = 0;
        n < 100 && find.text('PRIVATE-CURRENT-ORIGINAL').evaluate().isEmpty;
        n++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await t.pump(const Duration(milliseconds: 10));
      }
      await t.pumpAndSettle();
      expect(find.text('核对待录入原文'), findsOneWidget);
      expect(find.text('PRIVATE-CURRENT-ORIGINAL'), findsOneWidget);
      expect(repo.items, isEmpty);
      await t.tap(find.text('关闭').last);
      await t.pumpAndSettle();
      final detail = model.detail!, item = detail.items.single;
      expect(item.attachments.length, 2);
      expect(
        model.editItem(
          id,
          detail.summary.version,
          WorkspaceProposalItemReview(
            itemId: item.id,
            name: '主人确认后的简历',
            description: item.proposed.record.description,
            values: item.proposed.values,
            directoryId: item.proposed.record.directoryId,
            tagIds: item.proposed.record.tags.map((t) => t.id),
            relations: item.proposed.relations,
          ),
        ),
        true,
      );
      await t.pumpAndSettle();
      final approve = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(approve);
      await t.tap(approve);
      await settle();
      expect(
        model.writeFailure,
        isNull,
        reason: '${model.writeFailure?.code}: ${model.writeFailure?.message}',
      );
      expect(model.uncertain, false);
      expect(repo.items.single.name, '主人确认后的简历');
      expect(repo.items.single.fields.length, 2);
      expect(repo.items.single.fields.first.attachment!.attachmentVersion, 1);
      expect(
        (await t.runAsync(
          () => service.owner.readInformationAttachment(
            repo.items.single.fields.first.attachment!,
          ),
        ))!.bytes,
        utf8.encode('PRIVATE-CURRENT-ORIGINAL'),
      );
      expect((await t.runAsync(repo.informationFileStagingUsage))!.files, 0);
      expect(find.text('PRIVATE-CURRENT-ORIGINAL'), findsNothing);
      late String updateId;
      await t.runAsync(() async {
        final session = service.agent.openSession('补交简历修订');
        final original = await service.agent.uploadImportFile(
          session,
          operationId: 'next',
          originalName: '补交确认稿.txt',
          mediaType: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('PRIVATE-NEXT-ORIGINAL')),
        );
        final supplement = await service.agent.uploadImportFile(
          session,
          operationId: 'supplement',
          originalName: '补充证明.txt',
          mediaType: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('PRIVATE-SUPPLEMENT')),
        );
        final current = repo.items.single;
        updateId = await service.agent.submitUpdate(
          session,
          core.UpdateInput(
            current.id,
            current.version,
            [],
            attachments: [
              core.ImportAttachmentInput(
                key: 'revision',
                name: '简历原文',
                fieldId: current.fields.first.id,
                currentVersion: 1,
                versions: [
                  core.ImportAttachmentVersionInput(
                    original.id,
                    label: '补交确认稿',
                    sourceNote: '源文件明确的确认稿。',
                  ),
                ],
              ),
              core.ImportAttachmentInput(
                key: 'supplement',
                name: '补充证明',
                currentVersion: 1,
                versions: [
                  core.ImportAttachmentVersionInput(
                    supplement.id,
                    label: '证明原文',
                  ),
                ],
              ),
            ],
          ),
        );
        await model.open(updateId);
      });
      await settle();
      expect(find.text('补充到已有附件：简历原文'), findsOneWidget);
      expect(find.textContaining('补交确认稿 · 保存为当前版本'), findsOneWidget);
      expect(repo.items.single.version, 1);
      final oldPreview = find.text('查看原当前文件');
      await t.ensureVisible(oldPreview);
      await t.tap(oldPreview);
      for (
        var n = 0;
        n < 100 && find.text('PRIVATE-CURRENT-ORIGINAL').evaluate().isEmpty;
        n++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await t.pump(const Duration(milliseconds: 10));
      }
      await t.pumpAndSettle();
      expect(find.text('PRIVATE-CURRENT-ORIGINAL'), findsOneWidget);
      await t.tap(find.text('关闭').last);
      await t.pumpAndSettle();
      final nextPreview = find.text('查看这份原文').first;
      await t.ensureVisible(nextPreview);
      await t.tap(nextPreview);
      for (
        var n = 0;
        n < 100 && find.text('PRIVATE-NEXT-ORIGINAL').evaluate().isEmpty;
        n++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await t.pump(const Duration(milliseconds: 10));
      }
      await t.pumpAndSettle();
      expect(find.text('PRIVATE-NEXT-ORIGINAL'), findsOneWidget);
      await t.tap(find.text('关闭').last);
      await t.pumpAndSettle();
      final modification = model.detail!.items.single;
      final reviewed = WorkspaceProposalItemReview.fromItem(modification);
      expect(
        model.editItem(
          updateId,
          model.detail!.summary.version,
          WorkspaceProposalItemReview(
            itemId: modification.id,
            name: '主人确认后的第二稿',
            description: reviewed.description,
            values: reviewed.values,
            directoryId: reviewed.directoryId,
            tagIds: reviewed.tagIds,
            relations: reviewed.relations,
          ),
        ),
        true,
      );
      final confirmUpdate = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(confirmUpdate);
      await t.tap(confirmUpdate);
      await settle();
      expect(
        model.writeFailure,
        isNull,
        reason: '${model.writeFailure?.code}: ${model.writeFailure?.message}',
      );
      expect(repo.items.single.version, 2);
      expect(repo.items.single.fields.length, 3);
      expect(repo.items.single.name, '主人确认后的第二稿');
      expect(repo.items.single.fields.first.attachment!.attachmentVersion, 3);
      expect(
        (await t.runAsync(
          () => service.owner.readInformationAttachment(
            repo.items.single.fields.first.attachment!,
          ),
        ))!.bytes,
        utf8.encode('PRIVATE-NEXT-ORIGINAL'),
      );
      await t.runAsync(() async {
        final record = WorkspaceRecordRef(
          WorkspaceRecordKind.information,
          repo.items.single.id,
        );
        final detail = await library.readDetail(record);
        final key = detail.fieldIds.entries
            .singleWhere((e) => e.value == repo.items.single.fields.first.id)
            .key;
        final history = await library.loadFileHistory(record, key);
        expect(history.current.label, '补交确认稿');
        expect(history.current.sourceNote, '源文件明确的确认稿。');
        expect(history.versions.length, 3);
        expect(
          (await library.readFilePreview(record, key, version: 1)).text,
          'PRIVATE-CURRENT-ORIGINAL',
        );
        final template = currentAgentTemplates(
          service.owner,
        ).templates.singleWhere((t) => t.id == 'file');
        final session = service.agent.openSession('仅修改资料说明');
        final current = repo.items.single;
        final id = await service.agent.submitUpdate(
          session,
          core.UpdateInput(
            current.id,
            current.version,
            [],
            name: '保留文件后的名称',
            templateId: template.id,
            templateVersion: template.version,
            templateDigest: template.digest,
            values: {
              'file': {'retain': true},
            },
          ),
        );
        await model.open(id);
      });
      await settle();
      final confirmRetain = find.byKey(const ValueKey('proposal-confirm'));
      await t.ensureVisible(confirmRetain);
      await t.tap(confirmRetain);
      await settle();
      expect(
        model.writeFailure,
        isNull,
        reason: '${model.writeFailure?.code}: ${model.writeFailure?.message}',
      );
      expect(repo.items.single.version, 3);
      expect(repo.items.single.name, '保留文件后的名称');
      expect(repo.items.single.fields.length, 3);
      expect(repo.items.single.fields.first.attachment!.attachmentVersion, 3);
      await t.pumpWidget(const SizedBox());
    },
  );
}
